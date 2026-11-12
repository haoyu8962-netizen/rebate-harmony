#!/usr/bin/env python3
"""HM-L2-SKELETON-harmony（测试作者 v1 / v2，新鲜独立 Claude，先红；v2 照评审 r1 S2-1、S3-6 只收紧）：骨架件挪出 ProductCard.ets、微光与减弱动态、SkeletonGate / SkeletonHost
防闪（300 / 300）、订单 / 钱包形状的宿主守卫。

依据：NATIVE/HM-L2-BATCH1/brief-SKELETON.md §2、§3（S1–S6）、§4、§5；README「编排裁定 D10-1177」（① CARD→SKELETON→PRODUCT-CELL；
⑧ SkeletonGate〔纯逻辑，logic/〕+ SkeletonHost〔包装件〕进 Index，现有 SkeletonBlock / SkeletonProductCard 不带门控，3 处页面不动；
⑨ 清单各单只加行；⑩ 设备用例进 Ds02L2Ui）；sprint-plan-harmony.md :78、:93；D10-1163 ①、D10-838。
照 tools/ci/l2card/check_l2_card.py：.ets 一律经 l2skeleton_ast.cjs 用 SDK ohos-typescript 解析（AST，注释与字符串里的字不算）。

  K1 挪件（S1）：components/Skeleton.ets 有 @ComponentV2 export struct SkeletonBlock / SkeletonProductCard / SkeletonOrderCard /
     SkeletonWalletCard / SkeletonHost，无 V1 装饰器；SkeletonBlock 参数 blockWidth: Length = '100%' / blockHeight: Length = 16 不变；
     ProductCard.ets 不再声明、引用骨架（不留两份）
  K2 Index.ets 导出名集合 = 03570b8 基线（fixtures/exports-03570b8.json）+ SkeletonOrderCard / SkeletonWalletCard / SkeletonHost /
     SkeletonGate（可另带 SkeletonPhase / SkeletonClock / shimmerEnabled）；骨架件从 components/Skeleton、门控从 logic/SkeletonGate 导出（S2）
  K3 纯逻辑（S3、逻辑 7）：Logic.ets 导出 SkeletonGate / SkeletonPhase / SkeletonClock / shimmerEnabled（基线导出不少）；SkeletonGate.ets
     只引同目录纯逻辑、无 @kit / $r / 组件 / 装饰器；enum SkeletonPhase { HIDDEN, SHOWING, CONTENT }、interface SkeletonClock { now() }、
     function shimmerEnabled(reduced)；class SkeletonGate(clock: SkeletonClock) 有 loadingChanged / tick / nextDueInMs、
     static readonly SHOW_DELAY_MS = 300 / MIN_VISIBLE_MS = 300 且被用；类里不直接取时间 / 定时、不读减弱动态
  K4 微光（S4）：SkeletonBlock 有 .linearGradient、无限循环动画（iterations: -1）且 curve 是系统曲线；该动画在 CouliMotion.reduced() 为真时
     不可达、为假时可达（AST 三值求值：CouliMotion.reduced()、shimmerEnabled(x)、! && ||、局部 const、this 字段的全部赋值；跨到
     this.<方法>() 的全部调用处）；aboutToDisappear 非空；底色 .backgroundColor(CouliColors.backgroundMuted)；不读 motion 令牌
     v2：aboutToDisappear（含它经 this.<方法>() 走到的方法与闭包）不写 @Local / @Param 等状态变量（K4-disappear-state，
     SDK common.d.ts:30395；Host 同查记 K6-disappear-state）；循环动画改的字段被窄带的 translate / offset / position / markAnchor
     （或渐变本身）读到，且起止两态常量求值不同（K4-sweep；求不出值时只要求读到）；在播状态下窄带不被 visibility / opacity / if 藏住
     （K4-band-visible）；窄带颜色不全是块底色、不只一种色（K4-band-color）
  K5 读屏跳过（S5）：SkeletonBlock .accessibilityLevel('no-hide-descendants')；三种形状卡 build() 唯一根是
     CouliCard({ kind: STATIC（或不传）, a11yLevel: 'no-hide-descendants' }) 且卡内 ≥ 2 个 SkeletonBlock、不传 onTap / press / disabled / inset；
     Skeleton.ets 无颜色字面量 / 具名色 / $r
  K6 SkeletonHost（书 §2.4）：@Param loading: boolean = false、@BuilderParam skeleton / content；内部 new SkeletonGate 并调 loadingChanged /
     tick / nextDueInMs；@Monitor('loading') 方法走到 loadingChanged；有 setTimeout，aboutToDisappear 走到 clearTimeout；build() 不读
     this.loading；this.skeleton() 只在 SkeletonPhase.SHOWING 分支、与 this.content() 不同分支
     v2：setTimeout 延时取 nextDueInMs()（或其局部 const），剩余 0 / 正数时排、负数时不排（K6-schedule）；回调走到 tick（K6-tick）；
     排之前先 clearTimeout（K6-clear-first）；句柄存进 this.<字段> 且有 clearTimeout(this.<字段>)（K6-handle）
     v3（HM-BATCH1-DEVFIX 测试作者，只收紧、300 / 300 不动；NATIVE/HM-BATCH1-DEVFIX/tests-harmony-v4-handback.md §3.4：设备在屏
     315 / 293 / 274 ms，最短停留从判定 SHOWING 起算而非骨架上屏起算）：SkeletonPhase.SHOWING 分支内组件的上屏回调（SDK common.d.ts
     CommonMethod：onAppear / onAttach / onAreaChange / onVisibleAreaChange）走到 this.<门控字段>.markOnScreen()（K6-on-screen）；
     K3 门控类须有 markOnScreen()（K3-gate-api）；run-logic 变异加「markOnScreen 空实现（从判定时刻起算）」等
     v4（HM-BATCH1-DEVFIX 评审 Codex S2-1，只收紧）：K6-on-screen / K6-monitor / K6-timer / K6-tick / K6-clear-first / K6-gate 这些
     钉调用的规则只认会执行的调用（照 a11yhome_ast.cjs reachableCalls）：常量为假的 if / 三元 / && 、退出语句之后、从不调用的闭包与
     局部函数里的调用都不算；判不了按会执行。自测另加「合法写法仍绿」的正例（GOOD_VARIANTS）
  K7 目录（书 §2.3、README ⑨）：Skeleton 矩阵 = product / order / wallet × loading + host × gated，ProductCardSkeleton = list × loading；
     样例画 SkeletonProductCard / SkeletonOrderCard / SkeletonWalletCard / SkeletonHost、不再用 SkeletonBlock 现拼；设备 id 约定齐；
     画 order / wallet 的样例无 padding / 底色；inventory.tsv 的 Skeleton 行与矩阵一致（#24 只加行）
  K8 登记：designsystem List.test.ets 顶层恰调用一次 skeletonGateTest；verify.sh 跑本检查（自测 + 本体）、run-logic.cjs、check-arkts.cjs；
     Ds02L2Ui 的 describe 仍只有 Ds02L2Ui，L2SKEL_DEVICE_CASES = device-cases.txt，每个下标恰注册一次，注册函数在 describe 里恰调用一次
  K9 页面不动（书 §2.5、§4）：features/*/src/main、entry/src/main 不用 SkeletonHost / SkeletonGate / SkeletonOrderCard / SkeletonWalletCard /
     SkeletonPhase / shimmerEnabled；现有骨架调用原样（AuthManagePage SkeletonBlock 2、ProductDetailView SkeletonBlock 4、
     SearchView SkeletonProductCard 1）

用法：
  python3 tools/ci/l2skeleton/check_l2_skeleton.py [--root <目录>]    检查（默认仓库根）
  python3 tools/ci/l2skeleton/check_l2_skeleton.py --self-test        参照件 0 违反 + 每个错误实现被打红（REFERENCE_ONLY，不算产品通过）
退出码：0 通过；1 有违反（自测：有变异没被杀或正例不过）；2 参数不对；3 解析工具链不可用；4 无法保证判定完整（语法错误、必需文件缺失）。
Skeleton.ets / SkeletonGate.ets 不存在按 K1 / K3 违反（红在断言），不按 4。
"""

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
AST_TOOL = os.path.join(HERE, "l2skeleton_ast.cjs")
RUN_LOGIC = os.path.join(HERE, "run-logic.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")
BASELINE = os.path.join(HERE, "fixtures", "exports-03570b8.json")

SKEL = "common/designsystem/src/main/ets/components/Skeleton.ets"
GATE = "common/designsystem/src/main/ets/logic/SkeletonGate.ets"
PRODUCT = "common/designsystem/src/main/ets/components/ProductCard.ets"
INDEX = "common/designsystem/Index.ets"
LOGIC = "common/designsystem/Logic.ets"
MANIFEST = "entry/src/staging/ets/catalog/CatalogManifest.ets"
SAMPLES = "entry/src/staging/ets/catalog/CatalogSampleViews.ets"
DS_LIST = "common/designsystem/src/test/List.test.ets"
DEVICE_SUITE = "entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets"
DEVICE_CASES = "tools/ci/l2skeleton/device-cases.txt"
INVENTORY = "tools/ci/ds02/fixtures/inventory.tsv"
VERIFY = "tools/ci/verify.sh"
FILES = (SKEL, GATE, PRODUCT, INDEX, LOGIC, MANIFEST, SAMPLES, DS_LIST, DEVICE_SUITE)
PAGE_DIRS = ("entry/src/main",)
SKIP_DIRS = {"build", "oh_modules", "node_modules", ".hvigor", ".test", ".preview"}
EXPECTED_INVENTORY = {"Skeleton": sorted(["product/loading", "order/loading", "wallet/loading", "host/gated"]),
                      "ProductCardSkeleton": ["list/loading"]}
VERIFY_STEPS = ("tools/ci/l2skeleton/check_l2_skeleton.py --self-test", "tools/ci/l2skeleton/check_l2_skeleton.py",
                "tools/ci/l2skeleton/run-logic.cjs", "tools/ci/l2skeleton/check-arkts.cjs")
RULE_TITLES = {
    "K1": "挪件（Skeleton.ets 五个 V2 件、SkeletonBlock 参数不变、ProductCard.ets 无残留）",
    "K2": "Index.ets 导出名集合不变（新增 4 个）",
    "K3": "SkeletonGate 纯逻辑（进 Logic.ets、无 @kit / $r、300 / 300、时钟注入、不读减弱动态）",
    "K4": "微光（linearGradient、无限循环、系统曲线、减弱动态不可达、离开收尾且不写状态、真在动、窄带可见且有色差、muted 底色、无 motion 令牌）",
    "K5": "读屏跳过与外壳（SkeletonBlock / 三种形状卡 no-hide-descendants、静态 CouliCard、无颜色字面量）",
    "K6": "SkeletonHost（参数、内部 SkeletonGate、@Monitor、定时器调度与回调、离开不写状态、不绕过门控、骨架上屏调 markOnScreen）",
    "K7": "目录（矩阵 + host × gated、真实骨架件样例、id 约定、inventory）",
    "K8": "登记（designsystem List、verify 四步、设备用例名单）",
    "K9": "页面不动（不用新件、7 处调用原样）",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_l2skeleton", os.path.join(HERE, "..", "lint.py"))
lint = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lint)


class Incomplete(Exception):
    pass


def read(root, rel):
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as e:
        raise Incomplete("%s: 读不出（%s）" % (rel, e))


def page_candidates(root):
    """features/*/src/main 与 entry/src/main 下含 Skeleton / shimmerEnabled 子串的 .ets / .ts（再由 AST 判是否真是标识符 / 调用）。"""
    out = {}
    dirs = list(PAGE_DIRS)
    features = os.path.join(root, "features")
    if os.path.isdir(features):
        dirs += ["features/%s/src/main" % d for d in sorted(os.listdir(features))]
    for rel_dir in dirs:
        base = os.path.join(root, rel_dir)
        for cur, sub, names in os.walk(base):
            sub[:] = [d for d in sub if d not in SKIP_DIRS]
            for name in names:
                if not name.endswith((".ets", ".ts")) or name.endswith(".d.ts"):
                    continue
                path = os.path.join(cur, name)
                rel = os.path.relpath(path, root).replace(os.sep, "/")
                try:
                    with open(path, encoding="utf-8") as f:
                        text = f.read()
                except (OSError, UnicodeDecodeError) as e:
                    raise Incomplete("%s: 读不出（%s），页面扫描无法保证完整" % (rel, e))
                if "Skeleton" in text or "shimmerEnabled" in text:
                    out[rel] = text
    return out


def check_inventory(root, manifest_cases):
    text = read(root, INVENTORY)
    if text is None:
        raise Incomplete("%s: 文件不存在，无法判定" % INVENTORY)
    out = []
    for comp, want in EXPECTED_INVENTORY.items():
        rows = [line.split("\t") for line in text.splitlines() if line.startswith(comp + "\t")]
        cases = []
        for row in rows:
            if len(row) < 5:
                out.append({"rule": "K7-inventory", "file": INVENTORY, "line": 0, "msg": "%s 行缺列：%s" % (comp, "\t".join(row))})
                continue
            if row[1] != "§3.6" or row[2] != "L2 业务组件":
                out.append({"rule": "K7-inventory", "file": INVENTORY, "line": 0,
                            "msg": "%s 行应为 §3.6 / L2 业务组件，实际 %s / %s" % (comp, row[1], row[2])})
            cases += [v + "/" + s for v in row[3].split(",") for s in row[4].split(",")]
        got = (manifest_cases or {}).get(comp)
        if sorted(cases) != want or (got is not None and sorted(cases) != sorted(got)):
            out.append({"rule": "K7-inventory", "file": INVENTORY, "line": 0,
                        "msg": "inventory 的 %s 变体 × 状态应为 %s（与目录矩阵一致；README ⑨ 只加行，#24 落、gen.py 重出两份 Ds02Expected），实际 %s"
                               % (comp, " ".join(want), " ".join(sorted(cases)) or "无")})
    return out


def check_verify(root):
    text = read(root, VERIFY)
    if text is None:
        raise Incomplete("%s: 文件不存在，无法判定" % VERIFY)
    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    out = []
    for step in VERIFY_STEPS:
        script, _, flag = step.partition(" ")
        pattern = re.compile(re.escape(script) + r'"?(?P<rest>.*)$')
        hit = False
        for line in lines:
            m = pattern.search(line)
            if not m:
                continue
            rest = m.group("rest").split()
            if (flag and flag in rest) or (not flag and "--self-test" not in rest):
                hit = True
        if not hit:
            out.append({"rule": "K8-verify", "file": VERIFY, "line": 0, "msg": "verify.sh 没有（非注释）跑 %s（书 §4：verify 一步，只加）" % step})
    return out


def check_device_cases(root, facts):
    out = []
    text = read(root, DEVICE_CASES)
    listed = None if text is None else [l.strip() for l in text.splitlines() if l.strip() and not l.startswith("#")]
    const = facts.get("deviceConst")
    idx = facts.get("deviceIndices") or []
    if listed is None or const is None:
        return [{"rule": "K8-cases", "file": DEVICE_CASES, "line": 0, "msg": "缺 device-cases.txt 或 Ds02L2Ui.test.ets 的 L2SKEL_DEVICE_CASES"}]
    if facts.get("deviceDescribes") != ["Ds02L2Ui"]:
        out.append({"rule": "K8-cases", "file": DEVICE_SUITE, "line": 0,
                    "msg": "Ds02L2Ui.test.ets 应恰有一个 describe('Ds02L2Ui')（L2 批 1 共用套件，README ⑩），实际 %s" % facts.get("deviceDescribes")})
    if listed != const or len(set(listed)) != len(listed) or not all(re.fullmatch(r"l2skel_\d\d_[a-z0-9_]+", n) for n in listed):
        out.append({"rule": "K8-cases", "file": DEVICE_CASES, "line": 0,
                    "msg": "device-cases.txt 与 L2SKEL_DEVICE_CASES 应逐行一致、不重复、都是 l2skel_NN_…：%s | %s" % (listed, const)})
    if sorted(idx) != list(range(len(const))):
        out.append({"rule": "K8-cases", "file": DEVICE_SUITE, "line": 0,
                    "msg": "it(L2SKEL_DEVICE_CASES[i], …) 应对每个下标恰注册一次，实际下标 %s / 名单 %d 条" % (sorted(idx), len(const))})
    if not facts.get("deviceRegistered"):
        out.append({"rule": "K8-cases", "file": DEVICE_SUITE, "line": 0,
                    "msg": "L2SKEL 段的 it 应在同一个函数里，且该函数在 describe('Ds02L2Ui', …) 回调里恰调用一次"})
    return out


def check(root):
    """返回违反列表；语法错误 / 必需文件缺失抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
    tool = lint.hm10_toolchain()
    scan = page_candidates(root)
    files = dict(scan)
    for rel in FILES:
        files[rel] = read(root, rel)
    with open(BASELINE, encoding="utf-8") as f:
        baseline = json.load(f)
    payload = json.dumps({"files": files, "scan": sorted(scan), "baseline": baseline}, ensure_ascii=False).encode("utf-8")
    try:
        proc = subprocess.run([tool["node"], AST_TOOL, tool["typescript"]], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise lint.HM10ToolchainError("运行 node 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("l2skeleton_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("l2skeleton_ast.cjs 输出无法解析：%s" % e)
    if out["incomplete"]:
        raise Incomplete("；".join(out["incomplete"]))
    facts = out["facts"]
    return (out["violations"] + check_inventory(root, facts.get("manifestCases")) + check_verify(root)
            + check_device_cases(root, facts))


def render(violations):
    groups = {}
    for v in violations:
        groups.setdefault(v["rule"].split("-")[0], []).append(v)
    for key in sorted(RULE_TITLES):
        state = "红" if key in groups else "绿"
        print("%s %s：%s（%d 处）" % (key, state, RULE_TITLES[key], len(groups.get(key, []))))
    for v in sorted(violations, key=lambda x: (x["rule"], x["file"], x["line"])):
        print("  [%s] %s:%d %s" % (v["rule"], v["file"], v["line"], v["msg"]))


# ---------------------------------------------------------------- 自测：参照件 + 错误实现，全部要杀

SK, GT, PC, IX, LG, MF, SV, DL, DS, VF, IV, DC = (SKEL, GATE, PRODUCT, INDEX, LOGIC, MANIFEST, SAMPLES, DS_LIST, DEVICE_SUITE, VERIFY,
                                                  INVENTORY, DEVICE_CASES)
PAGE_AUTH = "entry/src/main/ets/trade/AuthManagePage.ets"
PAGE_SEARCH = "features/search/src/main/ets/SearchView.ets"
PAGE_DEMO = "features/demo/src/main/ets/DemoPage.ets"
GUARD = "    if (!shimmerEnabled(CouliMotion.reduced())) {\n      return;\n    }\n"
LOOP = "{ duration: SHIMMER_MS, curve: CouliMotion.curve, iterations: -1, playMode: PlayMode.Normal }"
PRODUCT_SHELL = ("@ComponentV2\nexport struct SkeletonProductCard {\n  build() {\n"
                 "    CouliCard({ kind: CouliCardKind.STATIC, a11yLevel: 'no-hide-descendants' }) {\n")
ORDER_SHELL = ("export struct SkeletonOrderCard {\n  build() {\n"
               "    CouliCard({ kind: CouliCardKind.STATIC, a11yLevel: 'no-hide-descendants' }) {\n")
OLD_BLOCK = ("\n/** 骨架色块。 */\n@ComponentV2\nexport struct SkeletonBlock {\n  @Param blockWidth: Length = '100%';\n"
             "  @Param blockHeight: Length = 16;\n\n  build() {\n    Row()\n      .width(this.blockWidth)\n      .height(this.blockHeight)\n"
             "      .backgroundColor(CouliColors.backgroundMuted)\n  }\n}\n")
LEAVE = ("  aboutToDisappear(): void {\n    // 只置非状态字段：不写 @Local / @Param、不调 animateTo；节点销毁时它身上的循环动画随之结束。\n"
         "    this.leaving = true;\n  }\n")
TRANSLATE = "          .translate({ x: (this.sweep * 350 - 100) + '%' })\n"
HOST_UPDATE = "  private update(): void {\n    this.cancel();\n"
HOST_TIMER = "      this.timer = setTimeout(() => {\n        this.timer = -1;\n        this.update();\n      }, due);\n"
HOST_ON_SCREEN = ("        .onAppear(() => {\n          // 骨架真正上屏：最短显示从这里起算（判定到挂载的延迟不吃进 300ms），再按新的剩余时长重排定时器。\n"
                  "          this.gate.markOnScreen();\n          this.update();\n        })\n")
HOST_BUILD = ("      if (this.phase === SkeletonPhase.SHOWING) {\n        Column() {\n          this.skeleton()\n        }\n        .width('100%')\n"
              + HOST_ON_SCREEN + "      } else if (this.phase === SkeletonPhase.CONTENT) {\n        this.content()\n      }\n")
HOST_BUILD_TAIL = ("      } else if (this.phase === SkeletonPhase.CONTENT) {\n        this.content()\n      }\n    }\n    .width('100%')\n")
OUTER_ON_SCREEN = "    .onAppear(() => {\n      this.gate.markOnScreen();\n      this.update();\n    })\n"
with open(os.path.join(GOOD, SKEL), encoding="utf-8") as _f:
    _GOOD_SKEL = _f.read()
# update() 的 tick 起到 build() 的 if/else 止（一段连续原文，供「判定时刻就 mark + 去上屏回调」这种两处一起改的变异用）。
HOST_SPAN = _GOOD_SKEL[_GOOD_SKEL.index("    this.phase = this.gate.tick();\n"):_GOOD_SKEL.index(HOST_BUILD) + len(HOST_BUILD)]
# v4（Codex S2-1）：update() 方法头起到 build() 的 if/else 止（加私有方法 + 改上屏回调两处一起改的写法用）。
HOST_SPAN2 = _GOOD_SKEL[_GOOD_SKEL.index(HOST_UPDATE):_GOOD_SKEL.index(HOST_BUILD) + len(HOST_BUILD)]
MARK = "          this.gate.markOnScreen();\n"
ON_SCREEN_HEAD = "        .onAppear(() => {\n"
GATE_MARK = ("  markOnScreen(): void {\n    if (this.shownAt >= 0) {\n      this.shownAt = Math.max(this.shownAt, this.clock.now());\n    }\n  }\n")
# （名字，文件，原串，新串，应报的规则前缀）；原串在参照件里必须唯一。old=None 表示删文件；old='' 表示在文件末尾追加 new。
MUTATIONS = [
    # ---- 书 §3 S6 点名的五类
    ("去减弱判断（微光照播）", SK, GUARD, "", "K4-reduced"),
    ("延时改 0", GT, "static readonly SHOW_DELAY_MS: number = 300;", "static readonly SHOW_DELAY_MS: number = 0;", "K3-gate-const"),
    ("最短显示改 0", GT, "static readonly MIN_VISIBLE_MS: number = 300;", "static readonly MIN_VISIBLE_MS: number = 0;", "K3-gate-const"),
    ("Logic 加 @kit（SkeletonGate.ets）", GT, "export interface SkeletonClock {", "import { systemDateTime } from '@kit.BasicServicesKit';\n\nexport interface SkeletonClock {", "K3-gate-kit"),
    ("Logic 加 @kit（Logic.ets 直接引）", LG, "// HM-L2-SKELETON：", "export { curves } from '@kit.ArkUI';\n// HM-L2-SKELETON：", "K3-logic-export"),
    ("留旧文件（ProductCard.ets 仍声明 SkeletonBlock）", PC, "", OLD_BLOCK, "K1-leftover"),
    # ---- K1 挪件
    ("Skeleton.ets 不存在", SK, None, None, "K1-missing"),
    ("缺 SkeletonWalletCard", SK, "export struct SkeletonWalletCard {", "export struct SkeletonWalletCardX {", "K1-struct"),
    ("SkeletonHost 不导出", SK, "export struct SkeletonHost {", "struct SkeletonHost {", "K1-struct"),
    ("SkeletonBlock 用 V1 @Component", SK, "@ComponentV2\nexport struct SkeletonBlock {", "@Component\nexport struct SkeletonBlock {", "K1"),
    ("SkeletonBlock 用 V1 @State", SK, "  @Local shimmer: boolean = false;", "  @State shimmer: boolean = false;", "K1-v1"),
    ("blockHeight 默认改 12（页面调用观感变了）", SK, "  @Param blockHeight: Length = 16;", "  @Param blockHeight: Length = 12;", "K1-block-props"),
    ("blockWidth 改名 width", SK, "  @Param blockWidth: Length = '100%';", "  @Param width2: Length = '100%';", "K1-block-props"),
    ("ProductCard.ets 仍引用 SkeletonProductCard", PC, "", "\nexport const LEGACY_SKELETON: string = SkeletonProductCard.name;\n", "K1-leftover"),
    # ---- K2 Index
    ("Index 不导出 SkeletonHost", IX, "  SkeletonBlock, SkeletonProductCard, SkeletonOrderCard, SkeletonWalletCard, SkeletonHost\n",
     "  SkeletonBlock, SkeletonProductCard, SkeletonOrderCard, SkeletonWalletCard\n", "K2-index"),
    ("Index 不导出 SkeletonGate", IX, "export { SkeletonGate } from './src/main/ets/logic/SkeletonGate';\n", "", "K2-index"),
    ("Index 丢了 SkeletonBlock（页面 import 断）", IX, "  SkeletonBlock, SkeletonProductCard, SkeletonOrderCard,", "  SkeletonProductCard, SkeletonOrderCard,", "K2-index"),
    ("Index 仍从 ProductCard 导出 SkeletonBlock", IX, "ProductTag, ProductCardGrid,", "ProductTag, SkeletonBlock, ProductCardGrid,", "K2-index"),
    ("Index 多导出 SkeletonShimmer", IX, "export { SkeletonGate } from", "export { SkeletonGate, SkeletonShimmerX } from", "K2-index"),
    ("Index 丢了基线导出 ProductCardA11y", IX, "ProductCardGrid, ProductCardA11y,", "ProductCardGrid,", "K2-index"),
    # ---- K3 纯逻辑
    ("SkeletonGate.ets 不存在", GT, None, None, "K3-gate-missing"),
    ("Logic.ets 不导出 SkeletonGate", LG, "export { SkeletonClock, SkeletonGate, SkeletonPhase, shimmerEnabled }",
     "export { SkeletonClock, SkeletonPhase, shimmerEnabled }", "K3-logic-export"),
    ("Logic.ets 从组件文件导出", LG, "from './src/main/ets/logic/SkeletonGate';\n", "from './src/main/ets/components/Skeleton';\n", "K3-logic-export"),
    ("门控里直接 Date.now()（时钟不经注入）", GT, "    const now: number = this.clock.now();\n    if (this.shownAt >= 0) {\n      if (this.loading ||",
     "    const now: number = Date.now();\n    if (this.shownAt >= 0) {\n      if (this.loading ||", "K3-gate-clock"),
    ("门控里 setTimeout", GT, "    this.loading = loading;\n", "    this.loading = loading;\n    setTimeout(() => {}, 0);\n", "K3-gate-clock"),
    ("门控读减弱动态", GT, "  loadingChanged(loading: boolean): void {\n", "  reduced: boolean = false;\n\n  loadingChanged(loading: boolean): void {\n", "K3-gate-reduced"),
    ("门控常量写成非 static", GT, "static readonly MIN_VISIBLE_MS: number = 300;", "readonly MIN_VISIBLE_MS: number = 300;", "K3-gate-const"),
    ("SkeletonPhase 少 HIDDEN", GT, "  HIDDEN,\n  SHOWING,", "  SHOWING,", "K3-gate-api"),
    ("构造不注入时钟", GT, "constructor(clock: SkeletonClock) {\n    this.clock = clock;", "constructor() {\n    this.clock = new FallbackClock();", "K3-gate-api"),
    ("缺 nextDueInMs", GT, "  nextDueInMs(): number {", "  nextDue(): number {", "K3-gate-api"),
    ("缺 shimmerEnabled", GT, "export function shimmerEnabled(reduced: boolean): boolean {", "export function shimmerOn(reduced: boolean): boolean {", "K3-gate-api"),
    ("SkeletonGate.ets 引组件", GT, "export interface SkeletonClock {", "import { CouliMotion } from '../components/CouliMotion';\n\nexport interface SkeletonClock {", "K3-gate-kit"),
    # ---- K4 微光
    ("减弱判断写反", SK, GUARD, GUARD.replace("!shimmerEnabled", "shimmerEnabled"), "K4"),
    ("减弱判断换成恒假（永远照播）", SK, GUARD, GUARD.replace("!shimmerEnabled(CouliMotion.reduced())", "this.blockHeight === 0"), "K4-reduced"),
    ("判断只看 shimmerEnabled(false)", SK, GUARD, GUARD.replace("CouliMotion.reduced()", "false"), "K4-reduced"),
    ("onAppear 里另起一个不受判断的循环动画", SK, "    .onAppear(() => {\n      this.startShimmer();\n    })\n",
     "    .onAppear(() => {\n      this.startShimmer();\n      this.getUIContext().animateTo({ duration: 1, curve: Curve.Linear, iterations: -1 }, () => {\n"
     "        this.sweep = 1;\n      });\n    })\n", "K4-reduced"),
    ("启动微光的方法没人调（永远不播）", SK, "    .onAppear(() => {\n      this.startShimmer();\n    })\n", "", "K4-dead"),
    ("不循环（iterations 1）", SK, LOOP, LOOP.replace("iterations: -1", "iterations: 1"), "K4-loop"),
    ("曲线写死贝塞尔字面量", SK, LOOP, LOOP.replace("CouliMotion.curve", "'cubic-bezier(0.2, 0, 0, 1)'"), "K4-curve"),
    ("曲线缺省", SK, LOOP, LOOP.replace("curve: CouliMotion.curve, ", ""), "K4-curve"),
    ("没有 linearGradient", SK, "          .linearGradient({\n            angle: 90,\n            colors: [[CouliColors.backgroundMuted, 0], [CouliColors.backgroundSurface, 0.5], [CouliColors.backgroundMuted, 1]]\n          })\n",
     "          .backgroundColor(CouliColors.backgroundSurface)\n", "K4-gradient"),
    ("离开不收尾", SK, LEAVE, "  aboutToDisappear(): void {\n  }\n", "K4-stop"),
    ("底色换 placeholder", SK, "    .backgroundColor(CouliColors.backgroundMuted)\n    .borderRadius(CouliRadius.small)",
     "    .backgroundColor(CouliColors.backgroundPlaceholder)\n    .borderRadius(CouliRadius.small)", "K4-muted"),
    ("读 motion 令牌", SK, "const SHIMMER_MS: number = 1400;", "const SHIMMER_MS: number = 1400;\nconst SHIMMER_TOKEN: string = 'motion.duration.slow';", "K4-motion-token"),
    # ---- K5 读屏 / 外壳 / 颜色
    ("SkeletonBlock 不跳过读屏", SK, "    .clip(true)\n    .accessibilityLevel('no-hide-descendants')\n", "    .clip(true)\n", "K5-block-a11y"),
    ("SkeletonProductCard 外壳不跳过读屏", SK, PRODUCT_SHELL, PRODUCT_SHELL.replace(", a11yLevel: 'no-hide-descendants'", ""), "K5-shell"),
    ("SkeletonOrderCard 外壳是可点卡", SK, ORDER_SHELL, ORDER_SHELL.replace("CouliCardKind.STATIC", "CouliCardKind.TAPPABLE"), "K5-shell"),
    ("SkeletonOrderCard 不用 CouliCard（内联白卡）", SK, ORDER_SHELL, ORDER_SHELL.replace("CouliCard({ kind: CouliCardKind.STATIC, a11yLevel: 'no-hide-descendants' })", "Column()"), "K5-shell"),
    ("微光高光写死白色", SK, "[CouliColors.backgroundSurface, 0.5]", "['#FFFFFF', 0.5]", "K5-literal"),
    ("微光高光用 Color.White", SK, "[CouliColors.backgroundSurface, 0.5]", "[Color.White, 0.5]", "K5-literal"),
    ("底色直接 $r", SK, "    .backgroundColor(CouliColors.backgroundMuted)\n    .borderRadius(CouliRadius.small)",
     "    .backgroundColor($r('app.color.background_muted'))\n    .borderRadius(CouliRadius.small)", "K5-literal"),
    # ---- K6 SkeletonHost
    ("Host 绕过门控（build 直接看 loading）", SK, HOST_BUILD,
     "      if (this.loading) {\n        this.skeleton()\n      } else {\n        this.content()\n      }\n", "K6-bypass"),
    ("Host 不用 SkeletonGate", SK, "  private gate: SkeletonGate = new SkeletonGate(new SystemSkeletonClock());",
     "  private gate: SkeletonGate = SkeletonGate.prototype;", "K6-gate"),
    ("Host 不监听 loading", SK, "  @Monitor('loading')\n", "", "K6-monitor"),
    ("Host 监听别的字段", SK, "  @Monitor('loading')\n", "  @Monitor('phase')\n", "K6-monitor"),
    ("Host 离开不清定时器", SK, "  aboutToDisappear(): void {\n    this.cancel();\n  }\n", "  aboutToDisappear(): void {\n    this.timer = -1;\n  }\n", "K6-timer"),
    ("Host 没有定时器（到点不 tick）", SK, "      this.timer = setTimeout(() => {\n        this.timer = -1;\n        this.update();\n      }, due);\n",
     "      this.timer = due;\n", "K6-timer"),
    ("Host 骨架与内容同一分支", SK, HOST_BUILD, HOST_BUILD.replace("      } else if (this.phase === SkeletonPhase.CONTENT) {\n", ""), "K6-branches"),
    ("Host 骨架在 HIDDEN 也显示", SK, HOST_BUILD, HOST_BUILD.replace("this.phase === SkeletonPhase.SHOWING", "this.phase !== SkeletonPhase.CONTENT"), "K6-branches"),
    ("Host loading 默认 true", SK, "  @Param loading: boolean = false;", "  @Param loading: boolean = true;", "K6-props"),
    ("Host 缺 content 参数", SK, "  @BuilderParam content: () => void = emptySkeletonSlot;\n", "", "K6"),
    # ---- v2 S2-1：aboutToDisappear 不写状态变量（SDK common.d.ts:30395）
    ("v2 离开写 @Local + animateTo 改 @Local（实现 r1 / 参照 v1 写法）", SK, LEAVE,
     "  aboutToDisappear(): void {\n    this.shimmer = false;\n    this.getUIContext().animateTo({ duration: 0 }, () => {\n      this.sweep = 0;\n    });\n  }\n",
     "K4-disappear-state"),
    ("v2 离开只在 animateTo 闭包里改 @Local", SK, LEAVE,
     "  aboutToDisappear(): void {\n    this.getUIContext().animateTo({ duration: 0 }, () => {\n      this.sweep = 0;\n    });\n  }\n", "K4-disappear-state"),
    ("v2 离开经私有方法改 @Local", SK, LEAVE,
     "  aboutToDisappear(): void {\n    this.stopShimmer();\n  }\n\n  private stopShimmer(): void {\n    this.leaving = true;\n    this.shimmer = false;\n  }\n",
     "K4-disappear-state"),
    ("v2 离开自增 @Local", SK, LEAVE, "  aboutToDisappear(): void {\n    this.leaving = true;\n    this.sweep++;\n  }\n", "K4-disappear-state"),
    ("v2 离开写 this['shimmer']", SK, LEAVE, "  aboutToDisappear(): void {\n    this['shimmer'] = false;\n  }\n", "K4-disappear-state"),
    ("v2 Host 离开改 @Local phase", SK, "  aboutToDisappear(): void {\n    this.cancel();\n  }\n",
     "  aboutToDisappear(): void {\n    this.cancel();\n    this.phase = SkeletonPhase.CONTENT;\n  }\n", "K6-disappear-state"),
    # ---- v2 S3-6：微光真在动、在播时看得见、窄带有色差
    ("v2 位移起止相同（FROM == TO）", SK, TRANSLATE, TRANSLATE.replace("this.sweep * 350 - 100", "this.sweep * 0 - 100"), "K4-sweep"),
    ("v2 动画闭包把字段改回初值", SK, "        this.sweep = 1;\n", "        this.sweep = 0;\n", "K4-sweep"),
    ("v2 动画闭包为空", SK, "        this.sweep = 1;\n", "", "K4-sweep"),
    ("v2 窄带位移写死常量（不读动画字段）", SK, TRANSLATE, "          .translate({ x: '-100%' })\n", "K4-sweep"),
    ("v2 动画改的是窄带不读的字段", SK, "        this.sweep = 1;\n", "        this.shimmer = true;\n", "K4-sweep"),
    ("v2 窄带恒为 Hidden", SK, TRANSLATE, TRANSLATE + "          .visibility(Visibility.Hidden)\n", "K4-band-visible"),
    ("v2 窄带可见性与播放反着", SK, TRANSLATE, TRANSLATE + "          .visibility(this.shimmer ? Visibility.Hidden : Visibility.Visible)\n", "K4-band-visible"),
    ("v2 窄带 opacity 0", SK, TRANSLATE, TRANSLATE + "          .opacity(0)\n", "K4-band-visible"),
    ("v2 窄带所在分支在播时不进", SK, "      if (this.shimmer) {\n        Row()", "      if (!this.shimmer) {\n        Row()", "K4-band-visible"),
    ("v2 窄带改成 muted 色（与块底色相同）", SK, "[CouliColors.backgroundSurface, 0.5]", "[CouliColors.backgroundMuted, 0.5]", "K4-band-color"),
    # ---- v2 S3-6：Host 调度
    ("v2 Host 到点（due 0）不排定时器", SK, "    if (due >= 0) {\n", "    if (due > 0) {\n", "K6-schedule"),
    ("v2 Host 负数也排定时器（空转）", SK, "    if (due >= 0) {\n", "    if (due >= -1) {\n", "K6-schedule"),
    ("v2 Host 延时写死 300", SK, "      }, due);\n", "      }, 300);\n", "K6-schedule"),
    ("v2 Host 定时器回调不再 tick", SK, HOST_TIMER, HOST_TIMER.replace("        this.update();\n", ""), "K6-tick"),
    ("v2 Host 排定时器前不清旧的", SK, HOST_UPDATE, "  private update(): void {\n", "K6-clear-first"),
    ("v2 Host 先排后清", SK, HOST_UPDATE + "    this.phase = this.gate.tick();\n    const due: number = this.gate.nextDueInMs();\n    if (due >= 0) {\n" + HOST_TIMER + "    }\n  }\n",
     "  private update(): void {\n    this.phase = this.gate.tick();\n    const due: number = this.gate.nextDueInMs();\n    if (due >= 0) {\n" + HOST_TIMER + "    }\n    this.cancel();\n  }\n",
     "K6-clear-first"),
    ("v2 Host 句柄不存", SK, HOST_TIMER, HOST_TIMER.replace("      this.timer = setTimeout(", "      setTimeout("), "K6-handle"),
    # ---- v3（HM-BATCH1-DEVFIX §3.4）：最短停留从骨架上屏起算——Host 在骨架上屏回调里调 markOnScreen
    ("v3 Host 不调 markOnScreen（最短停留从判定时刻起算，实现现状）", SK, HOST_ON_SCREEN,
     HOST_ON_SCREEN.replace("          this.gate.markOnScreen();\n", ""), "K6-on-screen"),
    ("v3 Host 去掉上屏回调", SK, "        .width('100%')\n" + HOST_ON_SCREEN, "        .width('100%')\n", "K6-on-screen"),
    ("v3 Host 在判定时刻调 markOnScreen（update 里 tick 出 SHOWING 就调，不挂上屏回调）", SK, HOST_SPAN,
     HOST_SPAN.replace("    this.phase = this.gate.tick();\n",
                       "    this.phase = this.gate.tick();\n    if (this.phase === SkeletonPhase.SHOWING) {\n      this.gate.markOnScreen();\n    }\n", 1)
     .replace("        .width('100%')\n" + HOST_ON_SCREEN, "        .width('100%')\n"), "K6-on-screen"),
    ("v3 Host 上屏回调挂在外层容器（宿主挂载即触发，不是骨架上屏）", SK, "        .width('100%')\n" + HOST_ON_SCREEN + HOST_BUILD_TAIL,
     "        .width('100%')\n" + HOST_BUILD_TAIL + OUTER_ON_SCREEN, "K6-on-screen"),
    ("v3 Host 上屏回调挂在内容分支", SK, HOST_BUILD,
     "      if (this.phase === SkeletonPhase.SHOWING) {\n        Column() {\n          this.skeleton()\n        }\n        .width('100%')\n"
     "      } else if (this.phase === SkeletonPhase.CONTENT) {\n        Column() {\n          this.content()\n        }\n" + HOST_ON_SCREEN + "      }\n",
     "K6-on-screen"),
    ("v3 Host 用离屏回调 onDisAppear 调 markOnScreen", SK, HOST_ON_SCREEN, HOST_ON_SCREEN.replace(".onAppear(", ".onDisAppear("), "K6-on-screen"),
    ("v3 Host 上屏回调里另 new 一个门控来 mark", SK, "          this.gate.markOnScreen();\n",
     "          new SkeletonGate(new SystemSkeletonClock()).markOnScreen();\n", "K6-on-screen"),
    ("v3 门控缺 markOnScreen", GT, GATE_MARK, "", "K3-gate-api"),
    # ---- v4（HM-BATCH1-DEVFIX 评审 Codex S2-1）：调用写在不会执行的位置不算（原守卫对这些返回 [] 仍过）
    ("v4 markOnScreen 包进 if (false)", SK, MARK, "          if (false) {\n            this.gate.markOnScreen();\n          }\n", "K6-on-screen"),
    ("v4 markOnScreen 放进未调用的闭包", SK, MARK,
     "          const mark = (): void => {\n            this.gate.markOnScreen();\n          };\n", "K6-on-screen"),
    ("v4 markOnScreen 在 return 之后", SK, HOST_ON_SCREEN,
     ON_SCREEN_HEAD + "          this.update();\n          return;\n" + MARK + "        })\n", "K6-on-screen"),
    ("v4 markOnScreen 在常量为假的三元分支", SK, MARK, "          false ? this.gate.markOnScreen() : this.update();\n", "K6-on-screen"),
    ("v4 markOnScreen 在常量为假的 && 右侧", SK, MARK, "          false && this.gate.markOnScreen();\n", "K6-on-screen"),
    ("v4 markOnScreen 由局部 const 假值守住", SK, MARK,
     "          const enabled: boolean = false;\n          if (enabled) {\n            this.gate.markOnScreen();\n          }\n", "K6-on-screen"),
    ("v4 markOnScreen 在 while (false) 体里", SK, MARK, "          while (false) {\n            this.gate.markOnScreen();\n          }\n", "K6-on-screen"),
    ("v4 markOnScreen 在裸箭头表达式语句里（从不调用）", SK, MARK, "          () => {\n            this.gate.markOnScreen();\n          };\n", "K6-on-screen"),
    ("v4 markOnScreen 在只被 void 引用的闭包里", SK, MARK,
     "          const mark = (): void => {\n            this.gate.markOnScreen();\n          };\n          void mark;\n", "K6-on-screen"),
    ("v4 markOnScreen 在未调用的局部函数声明里", SK, MARK,
     "          function mark(): void {\n            this.gate.markOnScreen();\n          }\n", "K6-on-screen"),
    ("v4 上屏回调经私有方法，方法里 return 之后才 mark", SK, HOST_SPAN2,
     "  private onSkeletonShown(): void {\n    return;\n    this.gate.markOnScreen();\n  }\n\n" +
     HOST_SPAN2.replace(MARK, "          this.onSkeletonShown();\n"), "K6-on-screen"),
    ("v4 上屏属性本身在 SHOWING 分支里常量为假的 if 中", SK, HOST_BUILD,
     "      if (this.phase === SkeletonPhase.SHOWING) {\n        Column() {\n          this.skeleton()\n        }\n        .width('100%')\n"
     "        if (false) {\n          Column()\n" + HOST_ON_SCREEN.replace("        ", "          ", 1) + "        }\n"
     "      } else if (this.phase === SkeletonPhase.CONTENT) {\n        this.content()\n      }\n", "K6-on-screen"),
    # ---- v4 同类钉调用的规则：@Monitor / 离开清定时器 / 定时器回调 tick / 排前先清 / 门控调用
    ("v4 Host @Monitor 里 return 之后才 loadingChanged", SK, "  onLoadingChanged(): void {\n    this.gate.loadingChanged(",
     "  onLoadingChanged(): void {\n    return;\n    this.gate.loadingChanged(", "K6-monitor"),
    ("v4 Host 离开的 clearTimeout 包进 if (false)", SK, "  aboutToDisappear(): void {\n    this.cancel();\n  }\n",
     "  aboutToDisappear(): void {\n    if (false) {\n      this.cancel();\n    }\n  }\n", "K6-timer"),
    ("v4 Host 定时器回调的 tick 包进 if (false)", SK, HOST_TIMER,
     HOST_TIMER.replace("        this.update();\n", "        if (false) {\n          this.update();\n        }\n"), "K6-tick"),
    ("v4 Host 排前清旧定时器放进未调用的闭包", SK, HOST_UPDATE,
     "  private update(): void {\n    const clear = (): void => {\n      this.cancel();\n    };\n", "K6-clear-first"),
    ("v4 Host 的 gate.tick() 只在常量为假的分支", SK, "    this.phase = this.gate.tick();\n",
     "    if (false) {\n      this.phase = this.gate.tick();\n    }\n", "K6-gate"),
    # ---- K7 目录
    ("目录漏 host × gated", MF, ", m(['host'], ['gated'])]),", "]),", "K7-manifest"),
    ("目录漏 wallet", MF, "[m(['product', 'order', 'wallet'], ['loading'])", "[m(['product', 'order'], ['loading'])", "K7-manifest"),
    ("目录标 L1", MF, "c('Skeleton', GROUP_FEEDBACK, KIND_L2,", "c('Skeleton', GROUP_FEEDBACK, KIND_L1,", "K7-manifest"),
    ("ProductCardSkeleton 改矩阵", MF, "[m(['list'], ['loading'])]", "[m(['list'], ['loading', 'gated'])]", "K7-manifest"),
    ("样例仍用 SkeletonBlock 拼订单卡", SV, "          SkeletonOrderCard()\n", "          SkeletonBlock({ blockWidth: '30%', blockHeight: 14 })\n", "K7-samples"),
    ("样例没有 SkeletonHost", SV, "        SkeletonHost({\n", "        SkeletonHostX({\n", "K7-samples"),
    ("样例缺 slow 按钮 id", SV, "          .id('catalog-skeleton-host/slow')\n", "", "K7-sample-ids"),
    ("样例事件 id 改名", SV, ".id('catalog-events/Skeleton/host/gated')", ".id('catalog-events/Skeleton/host')", "K7-sample-ids"),
    ("样例不记骨架消失时刻", SV, "    .onDisAppear(() => {\n      if (this.run !== 'idle') {\n        this.hidden = this.since();\n      }\n    })\n", "", "K7-samples"),
    ("样例容器自刷白底", SV, "      .width('100%')\n      .id(this.controlId)\n    }\n  }\n}", "      .width('100%')\n      .backgroundColor(CouliColors.backgroundSurface)\n      .id(this.controlId)\n    }\n  }\n}", "K7-sample-wrap"),
    ("样例 Host 不传 loading", SV, "          loading: this.loading,\n", "", "K7-samples"),
    ("inventory 漏 host 行", IV, "Skeleton\t§3.6\tL2 业务组件\thost\tgated\n", "", "K7-inventory"),
    ("inventory 与目录不一致", IV, "Skeleton\t§3.6\tL2 业务组件\thost\tgated\n", "Skeleton\t§3.6\tL2 业务组件\thost\tloading\n", "K7-inventory"),
    # ---- K8 登记
    ("designsystem List 没注册", DL, "  skeletonGateTest();\n", "", "K8-ds-list"),
    ("designsystem List 注册两次", DL, "  skeletonGateTest();\n", "  skeletonGateTest();\n  skeletonGateTest();\n", "K8-ds-list"),
    ("designsystem List 包进 if", DL, "  skeletonGateTest();\n", "  if (Date.now() > 0) {\n    skeletonGateTest();\n  }\n", "K8-ds-list"),
    ("verify 缺本体", VF, 'python3 "$ROOT/tools/ci/l2skeleton/check_l2_skeleton.py" || fail_fast', '# python3 "$ROOT/tools/ci/l2skeleton/check_l2_skeleton.py" || fail_fast', "K8-verify"),
    ("verify 缺 logic", VF, 'node "$ROOT/tools/ci/l2skeleton/run-logic.cjs"', 'true "$ROOT/tools/ci/l2skeleton/run-logic"', "K8-verify"),
    ("verify 缺 arkts", VF, 'node "$ROOT/tools/ci/l2skeleton/check-arkts.cjs" --real', 'true', "K8-verify"),
    ("设备名单与常量不一致", DC, "l2skel_06_font200_skeleton_layout_unchanged\n", "l2skel_06_renamed\n", "K8-cases"),
    ("设备用例少注册一条", DS, "  it(L2SKEL_DEVICE_CASES[5], 0,", "  hypiumIt(L2SKEL_DEVICE_CASES[5], 0,", "K8-cases"),
    ("设备用例注册两次", DS, "  it(L2SKEL_DEVICE_CASES[5], 0,", "  it(L2SKEL_DEVICE_CASES[4], 0,", "K8-cases"),
    ("注册函数没在 describe 里调", DS, "    l2SkeletonDeviceCases();\n", "", "K8-cases"),
    ("另起 describe（过滤 class=Ds02L2Ui 跑不到）", DS, "export function l2SkeletonDeviceCases(): void {\n",
     "export function l2SkeletonDeviceCases(): void {\n  describe('L2Skeleton', () => {});\n", "K8-cases"),
    # ---- K9 页面
    ("页面迁了 SkeletonHost", PAGE_AUTH, "SkeletonBlock({ blockWidth: '100%', blockHeight: 56 })\n            SkeletonBlock",
     "SkeletonHost({ loading: true })\n            SkeletonBlock", "K9"),
    ("页面骨架换成 SkeletonOrderCard", PAGE_SEARCH, "            SkeletonProductCard()\n", "            SkeletonOrderCard()\n", "K9"),
    ("页面多了一处 SkeletonBlock", PAGE_DEMO, "      Text(this.note)\n", "      Text(this.note)\n      SkeletonBlock()\n", "K9-pages-calls"),
]
# 页面正例：DemoPage.ets 只在注释 / 字符串里提到新件名，不算（K9 走 AST）。

# v4（Codex S2-1）正例：合法写法须仍绿（check 返回 []）。（名字，文件，原串，新串）
GOOD_VARIANTS = [
    ("onAppear 里只调 markOnScreen（不重排）", SK, HOST_ON_SCREEN, ON_SCREEN_HEAD + MARK + "        })\n"),
    ("onAppear 经私有方法调 markOnScreen", SK, HOST_SPAN2,
     "  private onSkeletonShown(): void {\n    this.gate.markOnScreen();\n    this.update();\n  }\n\n" +
     HOST_SPAN2.replace(MARK + "          this.update();\n", "          this.onSkeletonShown();\n")),
    ("onAppear 里局部闭包随即调用", SK, MARK, "          const mark = (): void => {\n            this.gate.markOnScreen();\n          };\n          mark();\n"),
    ("onAppear 里常量为真的 if", SK, MARK, "          if (true) {\n            this.gate.markOnScreen();\n          }\n"),
    ("onAppear 里非常量条件守卫", SK, MARK, "          if (this.phase === SkeletonPhase.SHOWING) {\n            this.gate.markOnScreen();\n          }\n"),
    ("markOnScreen 之后才 return", SK, HOST_ON_SCREEN, ON_SCREEN_HEAD + MARK + "          this.update();\n          return;\n        })\n"),
    ("改用 onAttach 回调", SK, HOST_ON_SCREEN, HOST_ON_SCREEN.replace(".onAppear(", ".onAttach(")),
]


def apply_edit(root, rel, old, new):
    """在 root 副本上把 rel 里唯一的 old 换成 new；返回错误文案或 None。"""
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.count(old) != 1:
        return "原串出现 %d 次（应 1 次）" % text.count(old)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(old, new))
    return None


def copy_good(dest):
    shutil.copytree(GOOD, dest)


LOGIC_MUTANTS = [
    ("延时 0", "static readonly SHOW_DELAY_MS: number = 300;", "static readonly SHOW_DELAY_MS: number = 0;"),
    ("最短显示 0", "static readonly MIN_VISIBLE_MS: number = 300;", "static readonly MIN_VISIBLE_MS: number = 0;"),
    ("延时边界写成 >（300ms 整还不出）", "now - this.loadingSince >= SkeletonGate.SHOW_DELAY_MS", "now - this.loadingSince > SkeletonGate.SHOW_DELAY_MS"),
    ("最短显示边界写成 <=（满 300 还留）", "now - this.shownAt < SkeletonGate.MIN_VISIBLE_MS", "now - this.shownAt <= SkeletonGate.MIN_VISIBLE_MS"),
    ("重复 true 重新起算", "    if (loading === this.loading) {\n      return;\n    }\n", ""),
    ("新一轮加载不重新起算", "    if (loading && this.shownAt < 0) {", "    if (loading && this.shownAt < 0 && this.loadingSince === 0) {"),
    ("加载一结束就撤骨架（无最短显示）", "      if (this.loading || now - this.shownAt < SkeletonGate.MIN_VISIBLE_MS) {", "      if (this.loading) {"),
    ("显示中又加载也照最短显示撤（闪内容）", "      if (this.loading || now - this.shownAt < SkeletonGate.MIN_VISIBLE_MS) {",
     "      if (now - this.shownAt < SkeletonGate.MIN_VISIBLE_MS) {"),
    ("延时内结束仍会出骨架（不看 loading）", "    if (!this.loading) {\n      return SkeletonPhase.CONTENT;\n    }\n    if (now - this.loadingSince", "    if (now - this.loadingSince"),
    ("没加载时报 HIDDEN", "    if (!this.loading) {\n      return SkeletonPhase.CONTENT;\n    }\n    if (now - this.loadingSince",
     "    if (!this.loading) {\n      return SkeletonPhase.HIDDEN;\n    }\n    if (now - this.loadingSince"),
    ("nextDue 到点后为负", "    return Math.max(0, this.loadingSince + SkeletonGate.SHOW_DELAY_MS - now);", "    return this.loadingSince + SkeletonGate.SHOW_DELAY_MS - now;"),
    ("nextDue 最短显示段为负", "      return Math.max(0, this.shownAt + SkeletonGate.MIN_VISIBLE_MS - now);", "      return this.shownAt + SkeletonGate.MIN_VISIBLE_MS - now;"),
    ("nextDue 显示中仍在加载给 0（空转定时）", "      if (this.loading) {\n        return -1;\n      }", "      if (this.loading) {\n        return 0;\n      }"),
    ("nextDue 空闲给 0", "    if (!this.loading) {\n      return -1;\n    }\n    return Math.max(0, this.loadingSince", "    if (!this.loading) {\n      return 0;\n    }\n    return Math.max(0, this.loadingSince"),
    ("减弱动态照播微光", "  return !reduced;", "  return true;"),
    ("微光开关写反", "  return !reduced;", "  return reduced;"),
    ("阶段枚举两个同值", "  HIDDEN,\n  SHOWING,\n  CONTENT\n", "  HIDDEN = 0,\n  SHOWING = 0,\n  CONTENT = 2\n"),
    # ---- v3（HM-BATCH1-DEVFIX §3.4）：最短停留从骨架上屏（markOnScreen）起算
    ("v3 markOnScreen 空实现（仍从判定时刻起算，实现现状）", GATE_MARK, "  markOnScreen(): void {\n  }\n"),
    ("v3 markOnScreen 往前挪（取 min）", "Math.max(this.shownAt, this.clock.now())", "Math.min(this.shownAt, this.clock.now())"),
    ("v3 markOnScreen 没在显示也起算（HIDDEN / 撤后调用会出骨架）", GATE_MARK,
     "  markOnScreen(): void {\n    this.shownAt = this.clock.now();\n  }\n"),
    ("v3 markOnScreen 不改最短显示、只重启出现延时", GATE_MARK,
     "  markOnScreen(): void {\n    if (this.shownAt >= 0) {\n      this.loadingSince = this.clock.now();\n    }\n  }\n"),
]


def run_logic_mutants():
    """run-logic.cjs 的行为变异（SkeletonGate.test.ets 真跑在参照件 SkeletonGate.ets 上）：参照件全绿、每个变异至少一条红。"""
    failures = []
    tool = lint.hm10_toolchain()
    base = [tool["node"], RUN_LOGIC, "--root", GOOD]
    env = dict(os.environ, COULI_HM_TYPESCRIPT=tool["typescript"])
    proc = subprocess.run(base, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    if proc.returncode != 0:
        failures.append("run-logic 参照件不绿：%s" % proc.stdout.decode("utf-8", "replace")[-600:])
    with open(os.path.join(GOOD, GATE), encoding="utf-8") as f:
        text = f.read()
    with tempfile.TemporaryDirectory(prefix="l2skel-logic-") as tmp:
        for i, (name, old, new) in enumerate(LOGIC_MUTANTS):
            if text.count(old) != 1:
                failures.append("run-logic 变异「%s」原串出现 %d 次（应 1 次）" % (name, text.count(old)))
                continue
            swap = os.path.join(tmp, "m%02d.ets" % i)
            with open(swap, "w", encoding="utf-8") as f:
                f.write(text.replace(old, new))
            proc = subprocess.run(base + ["--swap", GATE, swap, "--expect-red"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
            if proc.returncode != 0:
                failures.append("run-logic 变异「%s」没被打红：%s" % (name, proc.stdout.decode("utf-8", "replace")[-400:]))
        # 先红口径：被测文件不存在时各条红在断言（CONTRACT_MISSING），不是 LOAD_FAIL / THROW。
        empty = os.path.join(tmp, "empty-root")
        os.makedirs(empty)
        proc = subprocess.run([tool["node"], RUN_LOGIC, "--root", empty], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        out = proc.stdout.decode("utf-8", "replace")
        if proc.returncode == 0 or "LOAD_FAIL" in out or "FAIL[THROW]" in out or "CONTRACT_MISSING" not in out:
            failures.append("run-logic 缺文件时应各条 FAIL[ASSERT] CONTRACT_MISSING：%s" % out[-400:])
    return failures, 1 + len(LOGIC_MUTANTS) + 1


def self_test():
    failures = []
    with tempfile.TemporaryDirectory(prefix="l2skel-selftest-") as tmp:
        good = os.path.join(tmp, "good")
        copy_good(good)
        got = check(good)
        if got:
            failures.append("参照件不过：%s" % [(v["rule"], v["file"], v["line"], v["msg"]) for v in got])
        for idx, (name, rel, old, new, want) in enumerate(MUTATIONS):
            root = os.path.join(tmp, "m%02d" % idx)
            copy_good(root)
            path = os.path.join(root, rel)
            if old is None:
                os.remove(path)
            else:
                with open(path, encoding="utf-8") as f:
                    text = f.read()
                if old == "":
                    text = text + new
                elif text.count(old) != 1:
                    failures.append("变异「%s」的原串出现 %d 次（应 1 次）" % (name, text.count(old)))
                    shutil.rmtree(root)
                    continue
                else:
                    text = text.replace(old, new)
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text)
            try:
                rules = {v["rule"] for v in check(root)}
            except Incomplete as e:
                rules = {"INCOMPLETE"}
                failures.append("变异「%s」没红在断言（Incomplete：%s）" % (name, e))
            if not any(r == want or r.startswith(want + "-") for r in rules) and "INCOMPLETE" not in rules:
                failures.append("变异「%s」没被 %s 杀（实际 %s）" % (name, want, sorted(rules)))
            shutil.rmtree(root)
        for idx, (name, rel, old, new) in enumerate(GOOD_VARIANTS):
            root = os.path.join(tmp, "g%02d" % idx)
            copy_good(root)
            err = apply_edit(root, rel, old, new)
            if err:
                failures.append("正例「%s」%s" % (name, err))
            else:
                try:
                    got = check(root)
                except Incomplete as e:
                    got = [{"rule": "INCOMPLETE", "file": rel, "line": 0, "msg": str(e)}]
                if got:
                    failures.append("正例「%s」应绿却红：%s" % (name, [(v["rule"], v["line"], v["msg"][:60]) for v in got]))
            shutil.rmtree(root)
        root = os.path.join(tmp, "msyntax")
        copy_good(root)
        with open(os.path.join(root, SKEL), "a", encoding="utf-8") as f:
            f.write("\nexport struct {\n")
        try:
            check(root)
            failures.append("语法错误应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
    logic_failures, logic_total = run_logic_mutants()
    failures += logic_failures
    total = len(MUTATIONS) + len(GOOD_VARIANTS) + 1 + logic_total
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("L2SKEL_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("L2SKEL_SELFTEST 通过（REFERENCE_ONLY）：参照件 0 违反 + 宿主变异 %d 全杀 + 合法写法正例 %d 全绿 + 语法错误 fail-closed"
          " + run-logic 参照绿 / 变异 %d 全红 / 缺文件红在断言" % (len(MUTATIONS), len(GOOD_VARIANTS), len(LOGIC_MUTANTS)))
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", default=REPO_ROOT)
    ap.add_argument("--self-test", action="store_true")
    try:
        args = ap.parse_args()
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        if args.self_test:
            return self_test()
        violations = check(os.path.abspath(args.root))
    except lint.HM10ToolchainError as e:
        print("L2SKEL 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("L2SKEL 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    if violations:
        print("L2SKEL_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("L2SKEL_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
