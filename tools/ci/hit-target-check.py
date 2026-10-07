#!/usr/bin/env python3
"""真机 / 模拟器布局导出的命中区检查（APP-05a harmony-review-r1 R1-06 / R1-13；adaptation-a11y-spec A11yHitLogin）。只用标准库。

读 `hdc shell uitest dumpLayout` 导出的 JSON，按组件 id 找节点，断言：
- 每个 id 都在布局里（找不到算失败）；
- 每个节点的命中区宽、高都不低于下限（缺省 48vp；px ÷ (density ÷ 160)）；
- 这些节点两两不重叠（各自独立的命中区，例如两个协议链接与勾选单元）。

用法：
    python3 tools/ci/hit-target-check.py <layout.json> --density 560 --ids a,b,c [--min 48]
退出 0 = 全部满足；1 = 有不满足；2 = 输入出错。
"""

import json
import re
import sys


def find_bounds(node, wanted, out):
    attrs = node.get("attributes", {})
    nid = attrs.get("id")
    if nid in wanted and nid not in out:
        m = re.fullmatch(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", attrs.get("bounds", ""))
        if m:
            out[nid] = tuple(int(v) for v in m.groups())
    for child in node.get("children", []):
        find_bounds(child, wanted, out)


def check(layout, ids, density, minimum):
    scale = density / 160.0
    found = {}
    find_bounds(layout, set(ids), found)
    problems = []
    for nid in ids:
        if nid not in found:
            problems.append("%s：布局里没有这个节点" % nid)
            continue
        x1, y1, x2, y2 = found[nid]
        w, h = (x2 - x1) / scale, (y2 - y1) / scale
        print("  %s：%.1f × %.1f vp" % (nid, w, h))
        if w + 0.5 < minimum or h + 0.5 < minimum:
            problems.append("%s：命中区 %.1f × %.1f vp，低于 %d vp" % (nid, w, h, minimum))
    present = [n for n in ids if n in found]
    for i, a in enumerate(present):
        for b in present[i + 1:]:
            ax1, ay1, ax2, ay2 = found[a]
            bx1, by1, bx2, by2 = found[b]
            if ax1 < bx2 and bx1 < ax2 and ay1 < by2 and by1 < ay2:
                problems.append("%s 与 %s 的命中区重叠" % (a, b))
    return problems


def main(argv):
    args = argv[1:]
    if not args or args[0].startswith("--"):
        print(__doc__, file=sys.stderr)
        return 2
    path, opts = args[0], dict(zip(args[1::2], args[2::2]))
    try:
        density = float(opts["--density"])
        ids = [s for s in opts["--ids"].split(",") if s]
        minimum = int(opts.get("--min", "48"))
        with open(path, encoding="utf-8") as f:
            layout = json.load(f)
    except (KeyError, ValueError, OSError) as e:
        print("hit-target-check：输入出错：%s" % e, file=sys.stderr)
        return 2
    problems = check(layout, ids, density, minimum)
    for p in problems:
        print("  不满足 " + p)
    print("hit-target-check：%d 个节点，%d 处不满足" % (len(ids), len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
