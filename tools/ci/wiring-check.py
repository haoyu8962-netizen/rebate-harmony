#!/usr/bin/env python3
"""产品接线检查（FU-HM-0724 测试评审 T-04 裁定）：AppOrders / AppWallet / AppHome / OrderListView 必须真正调用 Core 的新协调器
（OrderTabCoordinator、WalletSessionReconciler、OrderListScrollSync.restoreStep / align、HomeLkgReconciler.syncWith）并传身份快照，
旧调度路径不得再被调用。规则与说明见 wiring-check.js。

用法：
  python3 tools/ci/wiring-check.py [--root <仓库根>]   检查仓库（默认本仓库）；0 = 满足，1 = 有违反，4 = 文件缺失 / 解析不完整
  python3 tools/ci/wiring-check.py --self-test         跑 tools/ci/wiring-fixtures/*：每个样例目录的 expect.txt 第一行是期望退出码，
                                                       其余行是输出里必须出现的规则号；全部符合退出 0，否则 1
node 与 typescript 包的推导与 lint.py（HM-LINT-10）同一套（hm10_toolchain）。
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lint  # noqa: E402  复用 hm10_toolchain

SCRIPT = os.path.join(HERE, "wiring-check.js")
FIXTURES = os.path.join(HERE, "wiring-fixtures")


def run(root):
    tool = lint.hm10_toolchain()
    proc = subprocess.run([tool["node"], SCRIPT, tool["typescript"], root], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
    out = proc.stdout.decode("utf-8", "replace") + proc.stderr.decode("utf-8", "replace")
    return proc.returncode, out


def self_test():
    cases = sorted(d for d in os.listdir(FIXTURES) if os.path.isdir(os.path.join(FIXTURES, d)))
    if not cases:
        print("wiring-check 自测：没有样例")
        return 1
    bad = 0
    for name in cases:
        case = os.path.join(FIXTURES, name)
        with open(os.path.join(case, "expect.txt"), encoding="utf-8") as f:
            lines = [l.strip() for l in f.read().splitlines() if l.strip()]
        want = int(lines[0])
        rules = lines[1:]
        code, out = run(case)
        missing = [r for r in rules if r not in out]
        ok = code == want and not missing
        print("  %s %s（exit %d，期望 %d%s）" % ("OK  " if ok else "FAIL", name, code, want,
                                           "" if not missing else "，缺规则 " + ",".join(missing)))
        if not ok:
            bad += 1
            print(out)
    print("wiring-check 自测：%d 个样例，%d 个不符" % (len(cases), bad))
    return 0 if bad == 0 else 1


def main():
    args = sys.argv[1:]
    if args == ["--self-test"]:
        sys.exit(self_test())
    root = os.path.dirname(os.path.dirname(HERE))
    if len(args) == 2 and args[0] == "--root":
        root = args[1]
    elif args:
        print(__doc__)
        sys.exit(2)
    try:
        code, out = run(root)
    except lint.HM10ToolchainError as e:
        print("wiring-check：%s" % e)
        sys.exit(4)
    sys.stdout.write(out)
    print("wiring-check：%s" % ("接线满足" if code == 0 else "exit %d" % code))
    sys.exit(code)


if __name__ == "__main__":
    main()
