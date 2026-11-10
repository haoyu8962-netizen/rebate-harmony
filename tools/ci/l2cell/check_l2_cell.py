#!/usr/bin/env python3
"""HM-L2-PRODUCT-CELL-harmony（测试作者 v1，新鲜独立 Claude，先红）：商品卡整卡承载、去预估返后（DETAIL-V3 U1）、读屏合一的宿主守卫。

依据：NATIVE/HM-L2-BATCH1/brief-PRODUCT-CELL.md §2、§3「结构」P1–P6、§4、§7；README 末节「编排裁定 D10-1177」（⑥ @Param openable=false +
@Event onOpen，页面零改动；② D10-871 回落）与「FREEZE 集成备忘」（Ds02L2Ui 单一 describe + 段函数 + 段边界，各单只加本段分支）；
NATIVE/HM-L2-BUTTON/review-harmony-r1.md S3-1 与 tests-harmony-v3-handback.md（卡内 this.rebate() 是遮罩值，误传给 BuyButton 在金额隐藏时
露出金额：l2button B5-hidden 已钉，本单不削弱、在新卡结构下再钉一次，自测里另把 l2button 的 check() 打在本单参照件与变异上，证明它仍红）。
照 tools/ci/l2button/check_l2_button.py：.ets 一律经 l2cell_ast.cjs 用 SDK ohos-typescript 解析（AST，注释与字符串里的字不算）。

  P1 外壳：@Param openable: boolean = false、@Event onOpen: () => void；ProductCard 不再内联 shadow(CouliShadow.card) /
     backgroundSurface / radius.card，卡壳经 CouliCard；openable=true 时 LIST / AI / GRID 有 kind 恰为 TAPPABLE 的 CouliCard
     （press 缺省或 BOUNCE，onTap 恰调一次 this.onOpen()、不调 onBuy）；网格卡 inset 透传
  P2 不吞点击（书 §7，重要）：openable=false 时每个可达 CouliCard 的 kind 静态求值恰为 STATIC（求不出算红）；ProductCard.ets 全文件
     不出现 onClick / onTouch / 手势 / clickEffect / stateStyles / CouliPressable；页面（features/*/src/main、entry/src/main）调用
     ProductCard 不传 openable / onOpen（README ⑥ 页面零改动，3 处页面外层 .onClick 照旧，FLOW 单再切换）
  P3 预估返后：LIST / AI / GRID 可达界面无 EstNetLine、不读 estNet；LARGE 保留（归 HM-FLOW-DETAIL / U2）
  P4 读屏：LIST / AI / GRID 的 CouliCard 传 groupAccessibility: false；信息区 .accessibilityGroup(true) +
     .accessibilityText(ProductCardA11y.cellLabel(this.data))，标题 / PriceTag / RebateTag / 价格不可用 / priceBlock 都在组里
     （200% widePrice 分支也在）；BuyButton 不在任何读屏组里；口径 i 不在信息组里；组外 GridRebateBlock 传 spoken: false；
     ProductCardA11y.cellLabel 存在（行为由 L2ProductCell.test.ets 钉）
  P5 无 CouliHaptics / vibrator（外跳不加触感，README §3.2）；image 构建方法与基线逐字节相同（批 2 PRODUCT-IMAGE）
  P6 --self-test：参照件（fixtures/good）0 违反；删 openable 判定（吞点击）、留 EstNetLine、Buy 进 group、加触感等错误实现逐个打红；
     良性改写保持全绿；语法错误 / 缺文件 fail-closed；另把 l2button check() 打在参照件与 S3-1 变异上（B5-hidden 必须红）
  P7 隐私接线（S3-1）：ProductCard.ets 里每个 BuyButton 的 rebate 解析到未遮罩 this.data.rebate、amountHidden 解析到 this.data.amountHidden
     （可经无参 this.m() / 唯一局部常量转一手）；按钮 onTap 只回调 this.onBuy()、不碰 onOpen
  P8 目录（书外接线，设备 l2cell_ 用例前提）：CatalogSampleViews 有传 openable / onOpen 的 ProductCard 样例，样例所在 struct 有外层
     .onClick（页面外层点击模拟），有 catalog-events/ProductCard 计数 id
  P9 登记：designsystem List.test.ets 直接调用 l2ProductCellTest(); 恰一次；Ds02L2Ui：L2CELL_DEVICE_CASES = device-cases.txt、
     ds02L2UiCellCases() 在 describe('Ds02L2Ui') 里 STATE 段之后调用恰一次、it 按常量下标 0..n-1 注册、段边界有 cell 分支；
     verify.sh 跑本检查（自测 + 本体）、run-logic.cjs、check-arkts.cjs

用法：
  python3 tools/ci/l2cell/check_l2_cell.py [--root <目录>]    检查（默认仓库根）
  python3 tools/ci/l2cell/check_l2_cell.py --self-test        参照件 0 违反 + 每个错误实现被打红（REFERENCE_ONLY，不算产品通过）
退出码：0 通过；1 有违反（自测：有变异没被杀或正例不过）；2 参数不对；3 解析工具链不可用；4 无法保证判定完整（语法错误、必需文件缺失）。
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
AST_TOOL = os.path.join(HERE, "l2cell_ast.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")

PRODUCT = "common/designsystem/src/main/ets/components/ProductCard.ets"
SAMPLES = "entry/src/staging/ets/catalog/CatalogSampleViews.ets"
DS_LIST = "common/designsystem/src/test/List.test.ets"
SUITE = "entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets"
DEVICE_CASES = "tools/ci/l2cell/device-cases.txt"
VERIFY = "tools/ci/verify.sh"
FILES = (PRODUCT, SAMPLES, DS_LIST, SUITE)
SKIP_DIRS = {"build", "oh_modules", "node_modules", ".hvigor", ".test", ".preview"}
VERIFY_STEPS = ("tools/ci/l2cell/check_l2_cell.py --self-test", "tools/ci/l2cell/check_l2_cell.py",
                "tools/ci/l2cell/run-logic.cjs", "tools/ci/l2cell/check-arkts.cjs")
RULE_TITLES = {
    "P1": "外壳经 CouliCard；openable=true 整卡可点回调 onOpen；openable / onOpen 声明；网格 inset",
    "P2": "openable=false 不吞页面外层点击（只许 STATIC；全文件无点击 / 手势 / 按压）",
    "P3": "列表 / AI / 网格卡去预估返后，详情大卡保留",
    "P4": "读屏：信息区合一项（cellLabel）、购买按钮与口径 i 单独",
    "P5": "无触感；图片段逐字节不变",
    "P7": "BuyButton 吃未遮罩返利与真开关；点购买不触发 onOpen（S3-1）",
    "P8": "目录 openable / onOpen 样例、外层点击模拟、计数节点",
    "P9": "登记：L2ProductCell 套件、Ds02L2Ui cell 段、verify 一步",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_l2cell", os.path.join(HERE, "..", "lint.py"))
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


def check_verify(root):
    text = read(root, VERIFY)
    if text is None:
        raise Incomplete("%s: 文件不存在，无法判定" % VERIFY)
    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    out = []
    for step in VERIFY_STEPS:
        script, _, flag = step.partition(" ")
        pattern = re.compile(re.escape(script) + r'"?(?P<rest>.*)$')
        hit = 0
        for line in lines:
            m = pattern.search(line)
            if not m:
                continue
            rest = m.group("rest").split()
            if (flag and flag in rest) or (not flag and "--self-test" not in rest):
                hit += 1
        if hit != 1:
            out.append({"rule": "P9-verify", "file": VERIFY, "line": 0,
                        "msg": "verify.sh 应（非注释）恰跑一次 %s，实际 %d 次（书 §4：verify.sh 一步，只加）" % (step, hit)})
    return out


def check_device_cases(root, facts):
    text = read(root, DEVICE_CASES)
    if text is None:
        return [{"rule": "P9-cases", "file": DEVICE_CASES, "line": 0, "msg": "缺 tools/ci/l2cell/device-cases.txt（本段设备用例名单）"}]
    listed = [line.strip() for line in text.splitlines() if line.strip() and not line.startswith("#")]
    out = []
    got = facts.get("suiteNames") or []
    if listed != got:
        out.append({"rule": "P9-cases", "file": SUITE, "line": 0,
                    "msg": "L2CELL_DEVICE_CASES 与 device-cases.txt 不一致：套件 %s / 名单 %s" % (got, listed)})
    bad = [n for n in listed if not re.match(r"^l2cell_\d\d_[a-z0-9_]+$", n)]
    if bad or len(set(listed)) != len(listed) or not listed:
        out.append({"rule": "P9-cases", "file": DEVICE_CASES, "line": 0,
                    "msg": "名单须非空、不重复、都是 l2cell_NN_xxx（段边界按 l2cell_ 前缀分段）：%s" % bad})
    return out


def page_files(root):
    """features/*/src/main 与 entry/src/main 下含 ProductCard 且含 openable / onOpen 字样的 .ets（交 AST 判 P2-page）。"""
    out = {}
    bases = [os.path.join(root, "entry", "src", "main")]
    features = os.path.join(root, "features")
    if os.path.isdir(features):
        bases += [os.path.join(features, d, "src", "main") for d in sorted(os.listdir(features))]
    for base in bases:
        for cur, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in files:
                if not name.endswith(".ets"):
                    continue
                path = os.path.join(cur, name)
                rel = os.path.relpath(path, root).replace(os.sep, "/")
                try:
                    with open(path, encoding="utf-8") as f:
                        text = f.read()
                except (OSError, UnicodeDecodeError) as e:
                    raise Incomplete("%s: 读不出（%s），页面扫描无法保证完整" % (rel, e))
                if "ProductCard" in text and ("openable" in text or "onOpen" in text):
                    out[rel] = text
    return out


def check(root):
    """返回违反列表；语法错误 / 必需文件缺失抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
    tool = lint.hm10_toolchain()
    scan = page_files(root)
    files = dict(scan)
    for rel in FILES:
        text = read(root, rel)
        if text is None:
            raise Incomplete("%s: 文件不存在，无法判定" % rel)
        files[rel] = text
    payload = json.dumps({"files": files, "scan": sorted(scan)}, ensure_ascii=False).encode("utf-8")
    try:
        proc = subprocess.run([tool["node"], AST_TOOL, tool["typescript"]], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise lint.HM10ToolchainError("运行 node 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("l2cell_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("l2cell_ast.cjs 输出无法解析：%s" % e)
    if out["incomplete"]:
        raise Incomplete("；".join(out["incomplete"]))
    return out["violations"] + check_device_cases(root, out["facts"]) + check_verify(root)


def render(violations):
    groups = {}
    for v in violations:
        groups.setdefault(v["rule"].split("-")[0], []).append(v)
    for key in sorted(RULE_TITLES):
        state = "红" if key in groups else "绿"
        print("%s %s：%s（%d 处）" % (key, state, RULE_TITLES[key], len(groups.get(key, []))))
    for v in sorted(violations, key=lambda x: (x["rule"], x["file"], x["line"])):
        print("  [%s] %s:%d %s" % (v["rule"], v["file"], v["line"], v["msg"]))


# ---------------------------------------------------------------- 自测（书 P6）：参照件 + 错误实现，全部要杀

PC, SV, DL, ST, DC, VF = PRODUCT, SAMPLES, DS_LIST, SUITE, DEVICE_CASES, VERIFY
PG = "features/demo/src/main/ets/pages/DemoListPage.ets"
LIST_SHELL = ("    CouliCard({\n      kind: this.cardKind(),\n      press: PressKind.BOUNCE,\n      groupAccessibility: false,\n"
              "      cardPadding: CouliSpacing.space3,\n")
INFO_GROUP = ("      .alignItems(HorizontalAlign.Start)\n      .width('100%')\n      .accessibilityGroup(true)\n"
              "      .accessibilityText(ProductCardA11y.cellLabel(this.data))\n\n      // 底行")
BUY_ROW = ("        Row() {\n          this.buyButton()\n        }\n        .flexGrow(1)\n        .justifyContent(FlexAlign.End)\n")
WIDE = ("        // 大字号：价格区占整卡宽（金额段不拆、不裁切，放不下时整块换行；Android 第 2 轮评审，三端统一）。\n"
        "        if (this.widePrice()) {\n          this.priceBlock()\n        }\n      }\n")
BUY_ARGS = "      base: this.data.buyBase,\n      rebate: this.data.rebate,\n"
HIDDEN_ARG = "      amountHidden: this.data.amountHidden,\n      context: this.context(),\n"
SUB_LINES = ("      this.notes(CouliTypography.caption)\n    }\n    .alignItems(HorizontalAlign.Start)\n  }\n\n"
             "  /** 规格说明")
# （名字，文件，原串，新串，应报的规则前缀）；原串在参照件里必须唯一
MUTATIONS = [
    # P2 吞点击（书 P6「删 openable 判定」）
    ("删 openable 判定：kind 写死 TAPPABLE（吞页面外层点击）", PC, "    return this.openable ? CouliCardKind.TAPPABLE : CouliCardKind.STATIC;",
     "    return CouliCardKind.TAPPABLE;", "P2-static"),
    ("openable 判定取反", PC, "    return this.openable ? CouliCardKind.TAPPABLE : CouliCardKind.STATIC;",
     "    return this.openable ? CouliCardKind.STATIC : CouliCardKind.TAPPABLE;", "P2-static"),
    ("kind 求值不了（外部函数）", PC, "    return this.openable ? CouliCardKind.TAPPABLE : CouliCardKind.STATIC;",
     "    return kindOf(this.openable);", "P2-static"),
    ("网格卡 kind 写死 TAPPABLE", PC, "    CouliCard({\n      kind: this.cardKind(),\n      press: PressKind.BOUNCE,\n      groupAccessibility: false,\n      inset: this.inset,",
     "    CouliCard({\n      kind: CouliCardKind.TAPPABLE,\n      press: PressKind.BOUNCE,\n      groupAccessibility: false,\n      inset: this.inset,", "P2-static"),
    ("大卡改可点且不看 openable", PC, "CouliCard({ kind: CouliCardKind.STATIC, groupAccessibility: false, cardPadding: CouliSpacing.space4 })",
     "CouliCard({ kind: CouliCardKind.TAPPABLE, groupAccessibility: false, cardPadding: CouliSpacing.space4 })", "P2-static"),
    ("信息区无条件接 .onClick", PC, INFO_GROUP, INFO_GROUP.replace(".accessibilityText(ProductCardA11y.cellLabel(this.data))\n",
     ".accessibilityText(ProductCardA11y.cellLabel(this.data))\n      .onClick(() => {\n        this.onOpen();\n      })\n"), "P2-click"),
    ("整卡包 CouliPressable", PC, "      this.listBody()\n", "      CouliPressable({ onTap: () => {\n        this.onOpen();\n      } }) {\n        this.listBody()\n      }\n",
     "P2-click"),
    ("信息区挂 TapGesture", PC, INFO_GROUP, INFO_GROUP.replace(".accessibilityText(ProductCardA11y.cellLabel(this.data))\n",
     ".accessibilityText(ProductCardA11y.cellLabel(this.data))\n      .gesture(TapGesture().onAction(() => {\n        this.onOpen();\n      }))\n"), "P2-click"),
    ("自画按压色 stateStyles", PC, INFO_GROUP, INFO_GROUP.replace(".accessibilityText(ProductCardA11y.cellLabel(this.data))\n",
     ".accessibilityText(ProductCardA11y.cellLabel(this.data))\n      .stateStyles({ pressed: { .opacity(0.8) } })\n"), "P2-click"),
    # P1
    ("删 @Param openable", PC, "  @Param openable: boolean = false;\n", "  openable: boolean = false;\n", "P1-decl"),
    ("openable 默认 true", PC, "  @Param openable: boolean = false;\n", "  @Param openable: boolean = true;\n", "P1-decl"),
    ("删 @Event onOpen", PC, "  @Event onOpen: () => void = () => {\n  };\n", "", "P1-decl"),
    ("保留内联阴影", PC, "    .alignItems(HorizontalAlign.Start)\n    .width('100%')\n  }\n\n  @Builder\n  aiCard()",
     "    .alignItems(HorizontalAlign.Start)\n    .width('100%')\n    .shadow(CouliShadow.card)\n  }\n\n  @Builder\n  aiCard()", "P1-inline"),
    ("网格保留内联白底", PC, "    .alignItems(HorizontalAlign.Start)\n    .width('100%')\n  }\n\n  @Builder\n  gridInfo()",
     "    .alignItems(HorizontalAlign.Start)\n    .width('100%')\n    .backgroundColor(this.inset ? Color.Transparent : CouliColors.backgroundSurface)\n  }\n\n  @Builder\n  gridInfo()", "P1-inline"),
    ("列表卡不经 CouliCard（外壳换回 Column）", PC, LIST_SHELL + "      onTap: () => {\n        this.onOpen();\n      }\n    }) {\n      this.listBody()\n    }\n",
     "    Column() {\n      this.listBody()\n    }\n", "P1-shell"),
    ("可点卡 onTap 调 onBuy", PC, LIST_SHELL + "      onTap: () => {\n        this.onOpen();\n      }\n",
     LIST_SHELL + "      onTap: () => {\n        this.onBuy();\n      }\n", "P1-tap"),
    ("可点卡按压改 HIGHLIGHT", PC, LIST_SHELL, LIST_SHELL.replace("PressKind.BOUNCE", "PressKind.HIGHLIGHT"), "P1-tap"),
    ("网格 inset 不透传", PC, "      inset: this.inset,\n", "", "P1-inset"),
    # P3
    ("列表副行留 EstNetLine（书 P6）", PC, SUB_LINES,
     "      this.notes(CouliTypography.caption)\n      EstNetLine({ text: this.estNet(), rebate: this.rebate() })\n    }\n    .alignItems(HorizontalAlign.Start)\n  }\n\n  /** 规格说明", "P3-list"),
    ("列表副行改用 Text 显示预估返后", PC, SUB_LINES,
     "      this.notes(CouliTypography.caption)\n      Text(this.estNet() ?? '')\n    }\n    .alignItems(HorizontalAlign.Start)\n  }\n\n  /** 规格说明", "P3-list"),
    ("大卡删 EstNetLine", PC, "            EstNetLine({ text: this.estNet(), large: true, rebate: this.rebate() })\n", "", "P3-large"),
    # P4
    ("购买按钮进信息组（书 P6）", PC, WIDE + "      .alignItems(HorizontalAlign.Start)\n      .width('100%')\n      .accessibilityGroup(true)",
     "        this.buyButton()\n" + WIDE + "      .alignItems(HorizontalAlign.Start)\n      .width('100%')\n      .accessibilityGroup(true)", "P4-buy"),
    ("CouliCard 整卡合组（groupAccessibility: true）", PC, LIST_SHELL, LIST_SHELL.replace("groupAccessibility: false", "groupAccessibility: true"), "P4-group"),
    ("CouliCard 不传 groupAccessibility（默认合组吞按钮）", PC, LIST_SHELL, LIST_SHELL.replace("      groupAccessibility: false,\n", ""), "P4-group"),
    ("信息区不合组", PC, INFO_GROUP, INFO_GROUP.replace("      .accessibilityGroup(true)\n", ""), "P4-info"),
    ("信息区读屏名只读标题", PC, INFO_GROUP, INFO_GROUP.replace("ProductCardA11y.cellLabel(this.data)", "this.data.title"), "P4-info"),
    ("200% 价格区挪到信息组外", PC, WIDE + "      .alignItems(HorizontalAlign.Start)\n      .width('100%')\n      .accessibilityGroup(true)\n"
     "      .accessibilityText(ProductCardA11y.cellLabel(this.data))\n",
     "      }\n      .alignItems(HorizontalAlign.Start)\n      .width('100%')\n      .accessibilityGroup(true)\n"
     "      .accessibilityText(ProductCardA11y.cellLabel(this.data))\n\n      if (this.widePrice()) {\n        this.priceBlock()\n      }\n", "P4-info"),
    ("口径 i 进信息组", PC, "        this.tagRow()\n        if (this.data.priceUnavailable) {\n          this.unavailableNote(CouliTypography.caption)\n        }\n",
     "        this.tagRow()\n        this.gridInfo()\n        if (this.data.priceUnavailable) {\n          this.unavailableNote(CouliTypography.caption)\n        }\n", "P4-buy"),
    ("网格返利块组外仍读（返利读两遍）", PC, "          noteCloseText: this.data.disclaimerCloseText,\n          spoken: false\n",
     "          noteCloseText: this.data.disclaimerCloseText\n", "P4-rebate"),
    ("删 ProductCardA11y.cellLabel", PC, "  static cellLabel(data: ProductCardData): string {\n    return ProductCardA11y.scrollTileLabel(data, null);\n  }\n",
     "", "P4-fn"),
    # P5
    ("整卡打开加触感（书 P6）", PC, "      onTap: () => {\n        this.onOpen();\n      }\n    }) {\n      this.listBody()",
     "      onTap: () => {\n        CouliHaptics.emit(1);\n        this.onOpen();\n      }\n    }) {\n      this.listBody()", "P5-haptics"),
    ("引入振动器", PC, "import { PressKind } from '../logic/MotionPolicy';\n",
     "import { PressKind } from '../logic/MotionPolicy';\nimport { vibrator } from '@kit.SensorServiceKit';\n", "P5-haptics"),
    ("改图片段（objectFit）", PC, "          .objectFit(ImageFit.Cover)\n", "          .objectFit(ImageFit.Contain)\n", "P5-image"),
    ("改图片段（读屏层级）", PC, "    .accessibilityLevel('no')\n  }\n\n  /** 平台标签", "    .accessibilityLevel('auto')\n  }\n\n  /** 平台标签", "P5-image"),
    # P7（BUTTON 评审 r1 S3-1）
    ("S3-1：按钮改传卡内 this.rebate()（遮罩值）", PC, BUY_ARGS, BUY_ARGS.replace("this.data.rebate", "this.rebate()"), "P7-hidden"),
    ("S3-1：按钮传 CardAmountMask.rebate(...)", PC, BUY_ARGS,
     BUY_ARGS.replace("this.data.rebate", "CardAmountMask.rebate(this.data.rebate, this.data.amountHidden)"), "P7-hidden"),
    ("按钮 amountHidden 写死 false", PC, HIDDEN_ARG, HIDDEN_ARG.replace("this.data.amountHidden", "false"), "P7-hidden"),
    ("按钮不传 amountHidden", PC, HIDDEN_ARG, "      context: this.context(),\n", "P7-hidden"),
    ("点购买也触发 onOpen", PC, "      onTap: () => {\n        this.onBuy();\n      }\n",
     "      onTap: () => {\n        this.onOpen();\n        this.onBuy();\n      }\n", "P7-buy"),
    # P8
    ("页面给 ProductCard 传 openable: true（吞外层点击）", PG, "ProductCard({ data: this.item, onBuy: () => {",
     "ProductCard({ data: this.item, openable: true, onBuy: () => {", "P2-page"),
    ("页面给 ProductCard 接 onOpen", PG, "ProductCard({ data: this.item, onBuy: () => {",
     "ProductCard({ data: this.item, onOpen: () => {\n          this.opened++;\n        }, onBuy: () => {", "P2-page"),
    ("目录样例不传 openable", SV, "            openable: this.openable(),\n", "", "P8-catalog"),
    ("目录没有外层点击模拟", SV, "        .onClick(() => {\n          this.outers++;\n        })\n", "", "P8-catalog"),
    ("目录缺计数 id", SV, "        .id('catalog-events/ProductCard/' + this.variant + '/' + this.state)\n", "", "P8-catalog"),
    # P9
    ("逻辑套件没登记", DL, "  l2ProductCellTest();\n", "", "P9-ds-list"),
    ("登记只在注释里", DL, "  l2ProductCellTest();\n", "  // l2ProductCellTest();\n", "P9-ds-list"),
    ("段函数没在 describe 里调用", ST, "    ds02L2UiCellCases();\n  });\n}\n", "  });\n}\n", "P9-suite"),
    ("段函数被调两次", ST, "    ds02L2UiCellCases();\n  });\n}\n", "    ds02L2UiCellCases();\n    ds02L2UiCellCases();\n  });\n}\n", "P9-suite"),
    ("段函数排到 STATE 前面", ST, "    L2StateSegment.ds02L2UiStateCases();\n", "    ds02L2UiCellCases();\n    L2StateSegment.ds02L2UiStateCases();\n", "P9-suite"),
    ("少注册一条", ST, "    it(L2CELL_DEVICE_CASES[8], 0,", "    it(L2CELL_DEVICE_CASES[7] + 'x', 0,", "P9-suite"),
    ("段函数里另起 describe", ST, "export function ds02L2UiCellCases(): void {\n",
     "export function ds02L2UiCellCases(): void {\n  describe('Ds02L2UiCell', () => {\n  });\n", "P9-suite"),
    ("名单与套件不一致", DC, "l2cell_09_surface_is_token_light_and_dark\n", "l2cell_09_surface_is_token_light_and_dark_x\n", "P9-cases"),
    ("段边界缺 cell", ST, "const L2_SEGMENTS: string[] = ['card', 'button', 'price', 'state', 'cell'];",
     "const L2_SEGMENTS: string[] = ['card', 'button', 'price', 'state'];", "P9-segment"),
    ("前缀不归 cell 段", ST, "  if (name.startsWith('l2cell_')) { return 'cell'; }\n", "", "P9-segment"),
    ("段前准备缺 cell 分支", ST, "  } else if (segment === 'cell') {\n    await runUiTask(driver, async (): Promise<void> => { await L2CellRig.enterCatalog(); });\n",
     "", "P9-segment"),
    ("verify 缺本单自测", VF, 'python3 "$ROOT/tools/ci/l2cell/check_l2_cell.py" --self-test || fail_fast "l2cell-host 自测" "见上方输出"\n', "", "P9-verify"),
    ("verify 缺 run-logic", VF, 'node "$ROOT/tools/ci/l2cell/run-logic.cjs" || fail_fast "l2cell-logic" "见上方用例"\n', "", "P9-verify"),
]

# 良性改写（实现可能的合理写法），必须仍然全绿——防判据收紧过头。（名字，[(文件，原串，新串)…]）
BENIGN = [
    ("列表卡用 if / else 分两支外壳（openable 时 TAPPABLE，否则 STATIC）", [
        (PC, LIST_SHELL + "      onTap: () => {\n        this.onOpen();\n      }\n    }) {\n      this.listBody()\n    }\n",
         "    if (this.openable) {\n" + LIST_SHELL.replace("kind: this.cardKind()", "kind: CouliCardKind.TAPPABLE")
         + "      onTap: () => {\n        this.onOpen();\n      }\n    }) {\n      this.listBody()\n    }\n    } else {\n"
         "    CouliCard({ kind: CouliCardKind.STATIC, groupAccessibility: false, cardPadding: CouliSpacing.space3 }) {\n"
         "      this.listBody()\n    }\n    }\n"),
    ]),
    ("按钮经无参 this.buyRebate() 转一手未遮罩返利", [
        (PC, BUY_ARGS, BUY_ARGS.replace("this.data.rebate", "this.buyRebate()")),
        (PC, "  /** 卡内显示的返利（金额隐藏时不带金额，R1-02）。 */\n",
         "  private buyRebate(): RebateTagContent {\n    return this.data.rebate;\n  }\n\n  /** 卡内显示的返利（金额隐藏时不带金额，R1-02）。 */\n"),
    ]),
    ("信息区读屏名经无参 this.cellText() 转一手", [
        (PC, INFO_GROUP, INFO_GROUP.replace("ProductCardA11y.cellLabel(this.data)", "this.cellText()")),
        (PC, "  /** 卡片外壳：openable 时可点，否则静态（无按压、无点击）。 */\n",
         "  private cellText(): string {\n    return ProductCardA11y.cellLabel(this.data);\n  }\n\n  /** 卡片外壳：openable 时可点，否则静态（无按压、无点击）。 */\n"),
    ]),
    ("cardKind 写成 if / return", [
        (PC, "    return this.openable ? CouliCardKind.TAPPABLE : CouliCardKind.STATIC;",
         "    if (!this.openable) {\n      return CouliCardKind.STATIC;\n    }\n    return CouliCardKind.TAPPABLE;"),
    ]),
]

# 交叉核对（S3-1「新卡结构下要继续红」）：把 l2button 的 check() 打在「l2button 参照树 + 本单参照 ProductCard（或其变异）」上。
CROSS = [
    ("参照件（l2button B4 / B5 应全绿）", None, None, None),
    ("S3-1：按钮改传卡内 this.rebate()", BUY_ARGS, BUY_ARGS.replace("this.data.rebate", "this.rebate()"), "B5-hidden"),
    ("按钮 amountHidden 写死 false", HIDDEN_ARG, HIDDEN_ARG.replace("this.data.amountHidden", "false"), "B5-hidden"),
]


def copy_good(dest):
    """参照树 = fixtures/good + 本仓库真实的 Ds02L2Ui.test.ets 与 device-cases.txt（本单测试作者写的段，自测从仓库拷入，同 l2state 做法）。"""
    shutil.copytree(GOOD, dest)
    for rel in (SUITE, DEVICE_CASES):
        os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
        shutil.copyfile(os.path.join(REPO_ROOT, rel), os.path.join(dest, rel))


def apply(root, rel, old, new):
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.count(old) != 1:
        return text.count(old)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(old, new))
    return 1


def cross_check(tmp, failures):
    spec = importlib.util.spec_from_file_location("couli_l2button_for_l2cell", os.path.join(HERE, "..", "l2button", "check_l2_button.py"))
    btn = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(btn)
    with open(os.path.join(GOOD, PRODUCT), encoding="utf-8") as f:
        card = f.read()
    for idx, (name, old, new, want) in enumerate(CROSS):
        root = os.path.join(tmp, "x%02d" % idx)
        shutil.copytree(btn.GOOD, root)
        text = card
        if old is not None:
            if text.count(old) != 1:
                failures.append("交叉核对「%s」原串出现 %d 次" % (name, text.count(old)))
                continue
            text = text.replace(old, new)
        with open(os.path.join(root, btn.CARD), "w", encoding="utf-8") as f:
            f.write(text)
        try:
            rules = {v["rule"] for v in btn.check(root)}
        except btn.Incomplete as e:
            failures.append("交叉核对「%s」l2button 判不完整：%s" % (name, e))
            continue
        b45 = sorted(r for r in rules if r.startswith("B4") or r.startswith("B5"))
        if want is None and b45:
            failures.append("交叉核对「%s」：l2button 在本单参照件上报 %s（新卡结构把 BUTTON 判据弄红了）" % (name, b45))
        if want is not None and want not in rules:
            failures.append("交叉核对「%s」：l2button 没报 %s（新卡结构下 BUTTON 判据失牙，实际 %s）" % (name, want, sorted(rules)))
        shutil.rmtree(root)
    return len(CROSS)


def self_test():
    failures = []
    with tempfile.TemporaryDirectory(prefix="l2cell-selftest-") as tmp:
        good = os.path.join(tmp, "good")
        copy_good(good)
        got = check(good)
        if got:
            failures.append("参照件不过：%s" % [(v["rule"], v["file"], v["line"], v["msg"]) for v in got])
        for idx, (name, rel, old, new, want) in enumerate(MUTATIONS):
            root = os.path.join(tmp, "m%02d" % idx)
            copy_good(root)
            n = apply(root, rel, old, new)
            if n != 1:
                failures.append("变异「%s」的原串出现 %d 次（应 1 次）" % (name, n))
                shutil.rmtree(root)
                continue
            try:
                rules = {v["rule"] for v in check(root)}
            except Incomplete as e:
                failures.append("变异「%s」解析不完整（变异写坏了，不算杀）：%s" % (name, e))
                shutil.rmtree(root)
                continue
            if not any(r == want or r.startswith(want + "-") for r in rules):
                failures.append("变异「%s」没被 %s 杀（实际 %s）" % (name, want, sorted(rules)))
            shutil.rmtree(root)
        for idx, (name, edits) in enumerate(BENIGN):
            root = os.path.join(tmp, "b%02d" % idx)
            copy_good(root)
            for rel, old, new in edits:
                n = apply(root, rel, old, new)
                if n != 1:
                    failures.append("良性改写「%s」的原串出现 %d 次（应 1 次）" % (name, n))
            try:
                got = check(root)
            except Incomplete as e:
                failures.append("良性改写「%s」解析不完整：%s" % (name, e))
                got = []
            if got:
                failures.append("良性改写「%s」被误报：%s" % (name, [(v["rule"], v["msg"]) for v in got]))
            shutil.rmtree(root)
        # 语法错误 / 缺文件必须 Incomplete（4），不算断言红
        root = os.path.join(tmp, "msyntax")
        copy_good(root)
        with open(os.path.join(root, PRODUCT), "a", encoding="utf-8") as f:
            f.write("\nexport struct {\n")
        try:
            check(root)
            failures.append("语法错误应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
        root = os.path.join(tmp, "mmissing")
        copy_good(root)
        os.remove(os.path.join(root, SAMPLES))
        try:
            check(root)
            failures.append("缺文件应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
        cross = cross_check(tmp, failures)
    total = len(MUTATIONS) + len(BENIGN) + 3 + cross
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("L2CELL_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("L2CELL_SELFTEST 通过：参照件 1 + 变异 %d 全杀 + 良性改写 %d 全绿 + 语法错误 / 缺文件 fail-closed + l2button 交叉核对 %d"
          % (len(MUTATIONS), len(BENIGN), cross))
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
        print("L2CELL 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("L2CELL 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    if violations:
        print("L2CELL_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("L2CELL_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
