#!/bin/bash
# release-scan.sh 自身的失败路径自测（R1-02）：扫描工具出错时必须退出非零，绝不能当成「未命中」放行，
# 也不能在 --self-test 里当成「命中」。
#
# 用法：tools/ci/release-scan-selftest.sh <工作目录>
#   工作目录放合成的输入与假工具（verify.sh 传构建镜像下的目录，不用 /tmp）。
#
# 用例（scan 与 --self-test 两种模式都跑）：
#   1. 非 ZIP 输入                                   → 必须退出 2
#   2. PATH 里注入返回 127 的假 unzip                → 必须退出 2
#   3. PATH 里注入返回 127 的假 python3              → 必须退出 2
#   4. PATH 里注入「什么都不打、退出 0」的假 python3 → 必须退出 2（没有完成标记）
#   5. ZIP 里没有 module.json / ets/modules.abc      → 必须退出 2
#   6. 不存在的输入                                  → 必须退出 2
# 另有正向用例证明合成输入本身是好的：干净的合成包 scan 退出 0；含 COULI_DEBUG_PANEL 的合成包 scan 退出 1；
# 含组件目录页标记（DS-01，UTF-16LE 编码）的合成包 scan 退出 1；module.json 声明测试深链 scheme couli-debug 的合成包 scan 退出 1（APP-02a）；
# 含只许在测试源码集的向量探针类名 / 硬编码帧片段的合成包 scan 退出 1（APP-10b R1-04 反向自测）。
# 用例 2–4 用的是「干净的合成包」：如果扫描吞掉了工具失败，就会错误地得到 0。
set -euo pipefail

WORK="${1:-}"
[ -n "$WORK" ] || { echo "用法：release-scan-selftest.sh <工作目录>" >&2; exit 2; }
SCAN="$(cd "$(dirname "$0")" && pwd)/release-scan.sh"
[ -x "$SCAN" ] || { echo "找不到可执行的 $SCAN" >&2; exit 2; }
PY="$(command -v python3)" || { echo "没有 python3" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/fakebin-unzip" "$WORK/fakebin-py127" "$WORK/fakebin-py0" "$WORK/scan-tmp"
export COULI_SCAN_WORK_DIR="$WORK/scan-tmp"

# 合成输入
printf 'this is not a zip\n' >"$WORK/not-a-zip.hap"
"$PY" - "$WORK" <<'PY'
import json, os, sys, zipfile
work = sys.argv[1]
module = json.dumps({"app": {"bundleName": "com.couli.hm", "debug": False, "buildMode": "release"}})
def make(name, files):
    with zipfile.ZipFile(os.path.join(work, name), "w") as z:
        for path, data in files.items():
            z.writestr(path, data)
make("clean.hap", {"module.json": module, "ets/modules.abc": b"prod.couli.invalid"})
make("dirty.hap", {"module.json": module, "ets/modules.abc": b"COULI_DEBUG_PANEL"})
make("catalog.hap", {"module.json": module, "ets/modules.abc": "COULI_COMPONENT_CATALOG_DS01_7f3a9c51e2".encode("utf-16-le")})
scheme_module = json.dumps({"app": {"bundleName": "com.couli.hm", "debug": False, "buildMode": "release"},
    "module": {"abilities": [{"name": "EntryAbility", "skills": [{"uris": [{"scheme": "couli" + "-debug", "host": "r"}]}]}]}})
make("debug-scheme.hap", {"module.json": scheme_module, "ets/modules.abc": b"prod.couli.invalid"})
make("no-module.hap", {"ets/modules.abc": b"prod.couli.invalid"})
# APP-10b R1-04：向量接线的探针类名与硬编码 done 帧片段（只许在测试源码集）。
make("agent-probe.hap", {"module.json": module, "ets/modules.abc": b"prod.couli.invalid AgentVectorProbe"})
make("agent-frame.hap", {"module.json": module, "ets/modules.abc":
    'data: {"finish_reason":"stop","quota_left":1}'.encode("utf-16-le")})
PY
printf '#!/bin/sh\nexit 127\n' >"$WORK/fakebin-unzip/unzip"
printf '#!/bin/sh\nexit 127\n' >"$WORK/fakebin-py127/python3"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' >"$WORK/fakebin-py0/python3"
chmod +x "$WORK/fakebin-unzip/unzip" "$WORK/fakebin-py127/python3" "$WORK/fakebin-py0/python3"

FAILURES=0
expect() {
    # $1 期望退出码 $2 说明 $3 额外 PATH 前缀（可空） 其余：release-scan.sh 参数
    local want="$1" label="$2" prefix="$3" code=0
    shift 3
    if [ -n "$prefix" ]; then
        PATH="$prefix:$PATH" "$SCAN" "$@" >"$WORK/last.log" 2>&1 || code=$?
    else
        "$SCAN" "$@" >"$WORK/last.log" 2>&1 || code=$?
    fi
    if [ "$code" -eq "$want" ]; then
        echo "  ok   ${label}：exit ${code}"
    else
        echo "  FAIL ${label}：期望 exit ${want}，实际 ${code}" >&2
        sed 's/^/       /' "$WORK/last.log" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

expect 0 "干净的合成包（scan）" "" "$WORK/clean.hap"
expect 1 "含 COULI_DEBUG_PANEL 的合成包（scan）" "" "$WORK/dirty.hap"
expect 1 "含组件目录页标记（UTF-16LE）的合成包（scan，DS-01）" "" "$WORK/catalog.hap"
expect 1 "module.json 声明测试深链 scheme 的合成包（scan，APP-02a）" "" "$WORK/debug-scheme.hap"
expect 1 "含向量探针类名的合成包（scan，APP-10b R1-04）" "" "$WORK/agent-probe.hap"
expect 1 "含硬编码 done 帧片段（UTF-16LE）的合成包（scan，APP-10b R1-04）" "" "$WORK/agent-frame.hap"
for mode in scan self-test; do
    if [ "$mode" = "scan" ]; then flag=""; else flag="--self-test"; fi
    expect 2 "非 ZIP 输入（${mode}）" "" ${flag:+"$flag"} "$WORK/not-a-zip.hap"
    expect 2 "假 unzip exit 127（${mode}）" "$WORK/fakebin-unzip" ${flag:+"$flag"} "$WORK/clean.hap"
    expect 2 "假 python3 exit 127（${mode}）" "$WORK/fakebin-py127" ${flag:+"$flag"} "$WORK/clean.hap"
    expect 2 "假 python3 静默 exit 0（${mode}）" "$WORK/fakebin-py0" ${flag:+"$flag"} "$WORK/clean.hap"
    expect 2 "缺 module.json（${mode}）" "" ${flag:+"$flag"} "$WORK/no-module.hap"
    expect 2 "输入不存在（${mode}）" "" ${flag:+"$flag"} "$WORK/missing.hap"
done

if [ "$FAILURES" -ne 0 ]; then
    echo "release-scan 自测：${FAILURES} 个用例失败" >&2
    exit 1
fi
echo "release-scan 自测：全部用例通过"
