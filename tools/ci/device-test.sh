#!/bin/bash
# 设备测试（ohosTest）执行器：签名 → 装到鸿蒙模拟器 / 真机 → aa test → 解析结果（FU-HM-0718 第 1 轮修复 R1-01）。
#
# 用法：tools/ci/device-test.sh <ohosTest.hap> <模块名> <工作目录> [被测应用.hap]
#   DS-02 的 UiTest 需要真实 EntryAbility：可选应用包与测试包使用同一临时签名，先装应用再装测试模块。
#   <ohosTest.hap>  HAP 用 assembleHap，HAR 用 genOnDeviceTestHap；均指定 module=<m>@ohosTest / isOhosTest=true
#   <模块名>        ohosTest 的 module.name（如 core_test）
#   <工作目录>      放签名材料与结果（ASCII 路径；脚本结束时删掉签名材料）
#
# 设备：环境变量 COULI_HM_DEVICE（hdc 目标，如 127.0.0.1:5557 或真机序列号）；没设时先试 hdc tconn 127.0.0.1:5557（DevEco 模拟器
# 默认端口），再取 hdc list targets 里第一个已连接的目标。**找不到设备就失败（exit 1），不跳过**。
# 签名：用 SDK 自带的 OpenHarmony 调试证书在工作目录里现签（设备 UDID 写进调试 profile；不改 SDK 文件、不改工程签名配置）。
# 安装前先卸掉设备上同包名（AppScope bundleName，com.couli.hm）的应用：ohosTest 包与应用同包名、签名不同装不上；跑完再卸掉测试包。
# 结果：aa test 输出里必须有 Hypium 汇总「Tests run: N, Failure: 0, Error: 0, Pass: N」（N ≥ 1）、OHOS_REPORT_CODE: 0 与
# TestFinished-ResultCode: 0（aa test 自身的退出码在拉不起测试时也是 0，不可信）。
# 退出码：0 通过；1 失败（没有设备、签名 / 安装失败、有用例失败或没有汇总）；2 用法错误。
# HM-07v-a（编排 D10-405 D4 / 测试 v2 T0）：同一测试包可按 Hypium 套件分步跑——
#   COULI_HM_TEST_FILTER  class=<套件名> 或 notClass=<套件名>（逗号分隔多个；空 = 全部套件），原样传给 aa test 的 -s class / -s notClass；
#   COULI_HM_DEVICE_SET   entry_test 结果按哪份必跑名单核对（main / hm07va / hm07vb / hm05r / me12v / me12wa / me12wb / me12wc / all，缺省 all），见 ds02/check_device_result.py。
# 每一步都先卸载再装（应用数据清空、首启前状态），所以分出去的步从「未同意隐私、冷启动」开始，不受前一步留下的状态影响。
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "用法：device-test.sh <ohosTest.hap> <模块名> <工作目录> [被测应用.hap]" >&2
    exit 2
fi
HAP="$1"
MODULE="$2"
WORK="$3"
APPLICATION_HAP="${4:-}"
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
TOOLCHAINS="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}/default/openharmony/toolchains"
HDC="$TOOLCHAINS/hdc"
LIB="$TOOLCHAINS/lib"
JAVA_BIN="${JAVA_HOME:-$DEVECO_HOME/jbr/Contents/Home}/bin"

die() {
    echo "device-test：$1" >&2
    exit 1
}

# 带超时执行（hdc 在模拟器挂起时会一直等）：$1 秒数，其余为命令。
with_timeout() {
    local seconds="$1"
    shift
    perl -e 'alarm shift; exec @ARGV or die "exec failed: $!"' "$seconds" "$@"
}

[ -f "$HAP" ] || die "找不到测试包 $HAP"
TEST_FILTER="${COULI_HM_TEST_FILTER:-}"
DEVICE_SET="${COULI_HM_DEVICE_SET:-all}"
FILTER_ARGS=()
if [ -n "$TEST_FILTER" ]; then
    case "$TEST_FILTER" in
        class=*|notClass=*) ;;
        *) die "COULI_HM_TEST_FILTER 只认 class=<套件> / notClass=<套件>：$TEST_FILTER" ;;
    esac
    filter_value="${TEST_FILTER#*=}"
    [[ "$filter_value" =~ ^[A-Za-z][A-Za-z0-9_]*(,[A-Za-z][A-Za-z0-9_]*)*$ ]] || die "套件名不合法：$filter_value"
    FILTER_ARGS=(-s "${TEST_FILTER%%=*}" "$filter_value")
fi
case "$DEVICE_SET" in main|hm07va|hm07vb|hm05r|me12v|me12wa|me12wb|me12wc|all) ;; *) die "COULI_HM_DEVICE_SET 只认 main / hm07va / hm07vb / hm05r / me12v / me12wa / me12wb / me12wc / all：$DEVICE_SET" ;; esac
for tool in "$HDC" "$JAVA_BIN/java" "$JAVA_BIN/keytool" "$LIB/hap-sign-tool.jar" "$LIB/OpenHarmony.p12" \
    "$LIB/UnsgnedDebugProfileTemplate.json" "$LIB/OpenHarmonyProfileDebug.pem"; do
    [ -e "$tool" ] || die "找不到 ${tool}（设 DEVECO_HOME）"
done
BUNDLE="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["app"]["bundleName"])' < <(unzip -p "$HAP" module.json))" \
    || die "从 $HAP 读 bundleName 失败"
HAP_MODULE="$(unzip -p "$HAP" module.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["module"]["name"])')" \
    || die "从 $HAP 读模块名失败"
[ "$HAP_MODULE" = "$MODULE" ] || die "测试包的模块名是 ${HAP_MODULE}，不是 ${MODULE}"
if [ -n "$APPLICATION_HAP" ]; then
    [ -f "$APPLICATION_HAP" ] || die "找不到被测应用包 $APPLICATION_HAP"
    APPLICATION_BUNDLE="$(unzip -p "$APPLICATION_HAP" module.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["app"]["bundleName"])')" \
        || die "读取被测应用包元信息失败"
    [ "$APPLICATION_BUNDLE" = "$BUNDLE" ] || die "被测应用与测试包 bundleName 不同"
fi

# ---------------------------------------------------------------- 设备
DEVICE="${COULI_HM_DEVICE:-}"
if [ -z "$DEVICE" ]; then
    with_timeout 20 "$HDC" tconn 127.0.0.1:5557 >/dev/null 2>&1 || true
    TARGETS="$(with_timeout 20 "$HDC" list targets -v 2>/dev/null | tr -d '\r' || true)"
    DEVICE="$(printf '%s\n' "$TARGETS" | awk '$3 == "Connected" { print $1; exit }')"
fi
[ -n "$DEVICE" ] || die "没有已连接的鸿蒙设备 / 模拟器（hdc list targets 无 Connected 目标；先启动模拟器或设 COULI_HM_DEVICE）。设备测试不跳过。"
hs() {
    with_timeout 60 "$HDC" -t "$DEVICE" shell "$@"
}
MODEL="$(hs param get const.product.model | tr -d '\r' | head -1 | sed 's/ *$//' || true)"
SOFTWARE="$(hs param get const.product.software.version | tr -d '\r' | head -1 | sed 's/ *$//' || true)"
API="$(hs param get const.ohos.apiversion | tr -d '\r' | head -1 | sed 's/ *$//' || true)"
# FU-HM-DEVICE-FLAKE（环境）：hdc 失联时 shell 也会「成功」返回一行 [Fail][E001005] Device not found…（dev6 实测），只认纯数字 API 级别。
[[ "$API" =~ ^[0-9]+$ ]] || die "设备 $DEVICE 不响应（hdc shell 失败：${API:-空}）"
echo "设备：${DEVICE}（型号 ${MODEL:-未知}，系统 ${SOFTWARE:-未知}，API ${API}）"
# FU-HM-DEVICE-FLAKE（环境就绪）：hdc 显示 Connected ≠ 系统就绪（APP-12w-c verify-2 / 2c 冷启动后 DS 目录 beforeAll 全挂）。
# 开跑前等开机完成（bootevent.boot.completed=true，最多 COULI_HM_BOOT_WAIT 秒，缺省 300）；冷启动刚完成（开机不足 90 秒）再多留 30 秒
# 让桌面与系统服务起稳。超时即失败（不跳过、不带病开跑）。打印开机时长，失败时可区分「冷启动后首步」与「长跑后」。
boot_wait="${COULI_HM_BOOT_WAIT:-300}"
boot_end=$((SECONDS + boot_wait))
while :; do
    boot_state="$(hs param get bootevent.boot.completed 2>&1 | tr -d '\r\n' || true)"
    [ "$(printf '%s' "$boot_state" | tr -d ' ')" = "true" ] && break
    # 评审 r1 S2-7：等待中 hdc 失联（返回 [Fail]… / Device not found）立即按「失联」失败，不白等满、不误报「开机未完成」。
    case "$boot_state" in
        *"[Fail]"*|*"not found"*|*"Not found"*) die "设备 $DEVICE 失联：不响应（hdc shell 失败：${boot_state}）" ;;
    esac
    [ "$SECONDS" -lt "$boot_end" ] || die "设备 $DEVICE 在 ${boot_wait} 秒内没有开机完成（bootevent.boot.completed≠true）"
    sleep 5
done
# 只认「数字 + 小数」开头的输出（读不到 / 无权限时为空，不额外等待；开机完成已由上面保证）。
UPTIME="$(hs cat /proc/uptime 2>/dev/null | tr -d '\r' | sed -nE 's/^([0-9]+)\.[0-9]+ .*/\1/p' | head -1 || true)"
if [ -n "$UPTIME" ] && [ "$UPTIME" -lt 90 ]; then
    echo "设备刚开机 ${UPTIME} 秒，等 30 秒再开跑"
    sleep 30
fi
echo "设备就绪：bootevent.boot.completed=true，开机 ${UPTIME:-?} 秒"

# ---------------------------------------------------------------- 签名
mkdir -p "$WORK"
SIGN="$WORK/sign"
rm -rf "$SIGN"
mkdir -p "$SIGN"
trap 'rm -rf "$SIGN"' EXIT
UDID="$(hs bm get --udid | tr -d '\r' | grep -Eo '[0-9A-Fa-f]{64}' | head -1 || true)"
[ -n "$UDID" ] || die "取不到设备 UDID"
cp "$LIB/OpenHarmony.p12" "$SIGN/ks.p12"
"$JAVA_BIN/keytool" -exportcert -rfc -alias "openharmony application ca" -keystore "$SIGN/ks.p12" -storepass 123456 \
    -storetype PKCS12 >"$SIGN/ca.cer" 2>/dev/null || die "导出 CA 证书失败"
"$JAVA_BIN/keytool" -exportcert -rfc -alias "openharmony application root ca" -keystore "$SIGN/ks.p12" -storepass 123456 \
    -storetype PKCS12 >"$SIGN/root.cer" 2>/dev/null || die "导出根证书失败"
"$JAVA_BIN/java" -jar "$LIB/hap-sign-tool.jar" generate-app-cert -keyAlias "openharmony application release" \
    -signAlg SHA256withECDSA -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
    -issuerKeyAlias "openharmony application ca" \
    -subject "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application Release" -keystoreFile "$SIGN/ks.p12" \
    -keystorePwd 123456 -keyPwd 123456 -issuerKeyPwd 123456 -outForm certChain -rootCaCertFile "$SIGN/root.cer" \
    -subCaCertFile "$SIGN/ca.cer" -outFile "$SIGN/app-chain.pem" >/dev/null || die "生成应用证书失败"
python3 - "$LIB/UnsgnedDebugProfileTemplate.json" "$SIGN/profile.json" "$UDID" "$SIGN/app-chain.pem" "$BUNDLE" <<'PY' \
    || die "生成调试 profile 失败"
import json, sys, time
p = json.load(open(sys.argv[1]))
chain = open(sys.argv[4]).read()
end = "-----END CERTIFICATE-----"
p["bundle-info"]["development-certificate"] = chain[:chain.index(end) + len(end)] + "\n"
p["bundle-info"]["bundle-name"] = sys.argv[5]
now = int(time.time())
p["validity"] = {"not-before": now - 86400, "not-after": now + 30 * 86400}
p["debug-info"]["device-ids"] = [sys.argv[3]]
json.dump(p, open(sys.argv[2], "w"))
PY
"$JAVA_BIN/java" -jar "$LIB/hap-sign-tool.jar" sign-profile -mode localSign -keyAlias "openharmony application profile debug" \
    -keyPwd 123456 -profileCertFile "$LIB/OpenHarmonyProfileDebug.pem" -inFile "$SIGN/profile.json" -signAlg SHA256withECDSA \
    -keystoreFile "$SIGN/ks.p12" -keystorePwd 123456 -outFile "$SIGN/profile.p7b" >/dev/null || die "签 profile 失败"
"$JAVA_BIN/java" -jar "$LIB/hap-sign-tool.jar" sign-app -mode localSign -keyAlias "openharmony application release" \
    -keyPwd 123456 -appCertFile "$SIGN/app-chain.pem" -profileFile "$SIGN/profile.p7b" -inFile "$HAP" \
    -signAlg SHA256withECDSA -keystoreFile "$SIGN/ks.p12" -keystorePwd 123456 -outFile "$SIGN/signed.hap" >/dev/null \
    || die "签测试包失败"
if [ -n "$APPLICATION_HAP" ]; then
    "$JAVA_BIN/java" -jar "$LIB/hap-sign-tool.jar" sign-app -mode localSign -keyAlias "openharmony application release" \
        -keyPwd 123456 -appCertFile "$SIGN/app-chain.pem" -profileFile "$SIGN/profile.p7b" -inFile "$APPLICATION_HAP" \
        -signAlg SHA256withECDSA -keystoreFile "$SIGN/ks.p12" -keystorePwd 123456 -outFile "$SIGN/application.hap" >/dev/null \
        || die "签被测应用包失败"
fi

# ---------------------------------------------------------------- 安装、执行
with_timeout 60 "$HDC" -t "$DEVICE" uninstall "$BUNDLE" >/dev/null 2>&1 || true
if [ -n "$APPLICATION_HAP" ]; then
    APPLICATION_INSTALL="$(with_timeout 120 "$HDC" -t "$DEVICE" install -r "$SIGN/application.hap" 2>&1 | tr -d '\r' || true)"
    printf '%s\n' "$APPLICATION_INSTALL"
    printf '%s' "$APPLICATION_INSTALL" | grep -q "install bundle successfully" || die "安装被测应用失败"
fi
INSTALL="$(with_timeout 120 "$HDC" -t "$DEVICE" install -r "$SIGN/signed.hap" 2>&1 | tr -d '\r' || true)"
printf '%s\n' "$INSTALL"
printf '%s' "$INSTALL" | grep -q "install bundle successfully" || die "安装测试包失败"
# 点亮并解锁（开发者模式下 aa test 不会自动解锁，锁屏时报 10106102）：唤醒 → 上滑 → 常亮。
hs power-shell wakeup >/dev/null 2>&1 || true
hs uitest uiInput swipe 640 2400 640 800 300 >/dev/null 2>&1 || true
hs power-shell setmode 602 >/dev/null 2>&1 || true
RESULT="$WORK/aa-test-$MODULE.log"
rc=0
started_seconds=$SECONDS
# FU-HM-DEVICE-FLAKE（环境）：宿主负载与交换区用量（只打印，不判定）。宿主交换区将满时模拟器整体变慢 / 应用被判冻结（APP_INPUT_BLOCK →
# App died，dev4 主步实测同时 swap 用 20.0/21.5 GB），偶发红时先看这两行。
host_stats() {
    printf 'load=%s swap_used=%s/%s' "$(sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 "," $3 "," $4 }')" \
        "$(sysctl -n vm.swapusage 2>/dev/null | awk '{ print $6 }')" "$(sysctl -n vm.swapusage 2>/dev/null | awk '{ print $3 }')"
}
echo "HOST_AT_START $(host_stats || true)"
# FU-HM-DEVICE-FLAKE（评审 r2 S2-A）：清空设备 hilog，跑完后抓本步的设施留痕（补登录 HM07VA_SELF_HEAL、截屏重拍 FLKRIG、v5 起 DS02_BEFOREALL_TRAIL）进步骤日志。只打印、不判定。
hs hilog -r >/dev/null 2>&1 || true
# Hypium 1.0.24 只支持统一单例上限；entry 的大组件及每个 ProductCard 变体给足 600s。
# 也覆盖直接调用此脚本的路径；整轮 1800s 验收门槛（D10-232，原 900s，提速后改回）仍在下方独立检查。
case_timeout="${COULI_HM_TEST_CASE_TIMEOUT:-60000}"
if [ "$MODULE" = entry_test ]; then case_timeout=600000; fi
with_timeout "${COULI_HM_TEST_TOTAL_TIMEOUT:-600}" "$HDC" -t "$DEVICE" shell aa test -b "$BUNDLE" -m "$MODULE" -s unittest OpenHarmonyTestRunner \
    -s timeout "$case_timeout" ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"} >"$RESULT" 2>&1 || rc=$?
elapsed_seconds=$((SECONDS - started_seconds))
echo "HOST_AT_END $(host_stats || true)"
# 设施留痕（只打印、不判定）：hilog 环形缓冲在长步里可能已翻转，计数是下限；FLAKE_CAPTURE_INVALID 另从 aa test 输出里数。
TRACE="$WORK/flake-trace.log"
hs "hilog -x" 2>/dev/null | tr -d '\r' | { grep -E 'HM07VA_SELF_HEAL|FLKRIG|DS02_BEFOREALL_TRAIL' || true; } >"$TRACE" || true
self_heal="$(grep -c 'HM07VA_SELF_HEAL' "$TRACE" 2>/dev/null || true)"
retake="$(grep -c 'FLKRIG capture retake' "$TRACE" 2>/dev/null || true)"
invalid="$(grep -c 'FLAKE_CAPTURE_INVALID' "$RESULT" 2>/dev/null || true)"
# v5（评审 r4 S2-1）：Ds02Ui beforeAll 吸收的首页容器消失次数（DS02_BEFOREALL_TRAIL 行求和；绿跑也有）。
ds02_gone="$({ grep -o 'DS02_BEFOREALL_TRAIL container_gone=[0-9]*' "$TRACE" 2>/dev/null || true; } | awk -F= '{ s += $2 } END { print s + 0 }')"
tail -50 "$TRACE" | sed 's/^/  trace: /' || true
echo "FLAKE_TRACE self_heal=${self_heal:-0} capture_retake=${retake:-0} capture_invalid=${invalid:-0} ds02_container_gone=${ds02_gone:-0}（只打印，不参与判定；hilog 计数为下限）"
with_timeout 60 "$HDC" -t "$DEVICE" uninstall "$BUNDLE" >/dev/null 2>&1 || true
tr -d '\r' <"$RESULT" >"$RESULT.txt"
mv "$RESULT.txt" "$RESULT"
# 逐用例结果（Hypium：OHOS_REPORT_STATUS: test=<名> … OHOS_REPORT_STATUS_CODE: 0 通过 / -1 出错 / -2 断言失败）。
python3 - "$RESULT" <<'PY' || true
import re, sys
name = None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.match(r"OHOS_REPORT_STATUS: test=(.*)", line.strip())
    if m:
        name = m.group(1)
        continue
    m = re.match(r"OHOS_REPORT_STATUS_CODE: (-?\d+)", line.strip())
    if m and name is not None and m.group(1) != "1":
        print("  %s %s" % ({"0": "PASS", "-1": "ERROR", "-2": "FAIL"}.get(m.group(1), m.group(1)), name))
        name = None
PY
{ grep -E "OHOS_REPORT_STATUS: (stack=|stream=Error)" "$RESULT" || true; } | head -20
SUMMARY="$({ grep -Eo 'Tests run: [0-9]+, Failure: [0-9]+, Error: [0-9]+, Pass: [0-9]+.*' "$RESULT" || true; } | tail -1)"
echo "  ${SUMMARY:-无汇总}（aa test exit ${rc}，输出见 ${RESULT}）"
[ "$rc" -eq 0 ] || die "aa test 退出码 ${rc}"
python3 -c 'import re,sys
m = re.match(r"Tests run: (\d+), Failure: (\d+), Error: (\d+), Pass: (\d+)", sys.argv[1])
sys.exit(0 if m and int(m.group(1)) > 0 and m.group(2) == "0" and m.group(3) == "0" and m.group(4) == m.group(1) else 1)' \
    "$SUMMARY" || die "有用例失败或没有汇总：${SUMMARY:-无汇总}"
grep -q "OHOS_REPORT_CODE: 0" "$RESULT" || die "aa test 没有报告 OHOS_REPORT_CODE: 0"
grep -q "TestFinished-ResultCode: 0" "$RESULT" || die "aa test 没有报告 TestFinished-ResultCode: 0"
if [ "$MODULE" = entry_test ]; then
    # 1800 秒门槛（D10-232）对每一步各自适用（D10-405 D4：拆步不放宽）。
    [ "$elapsed_seconds" -le 1800 ] || die "entry 设备步（${DEVICE_SET}）超过 1800 秒：${elapsed_seconds}"
    python3 "$(dirname "$0")/ds02/check_device_result.py" "$RESULT" --set "$DEVICE_SET" \
        || die "entry 设备步（${DEVICE_SET}）必跑用例未全部通过"
fi
echo "DEVICE_TEST_PASS set=${DEVICE_SET} filter=${TEST_FILTER:-none} elapsed_seconds=${elapsed_seconds} device=${DEVICE} model=${MODEL:-unknown} api=${API} ${SUMMARY}"
