#!/usr/bin/env python3
"""HM-L2-CARD-harmony（测试作者 v1 / v2，新鲜独立 Claude）：新件 CouliCard + F-HM-98（CouliPressable 读屏 / 禁用态）的宿主守卫。

依据：NATIVE/HM-L2-BATCH1/brief-CARD.md §2、§3（C1–C5）、§4、§5；README「编排裁定 D10-1177」（⑨ 清单各单只加行、⑩ Ds02L2Ui 本单首次注册）；
sprint-plan-harmony.md §1.1「每单要先写的测试」（可点卡有 clickEffect / stateStyles；没有无反馈的裸 .onClick；颜色只来自 CouliColors）。
照 tools/ci/tabbar/check_tab_bar.py：.ets 一律经 l2card_ast.cjs 用 SDK ohos-typescript 解析（AST，注释与字符串里的字不算）。

  C1 CouliCard（components/CouliCard.ets）：export enum CouliCardKind { STATIC, TAPPABLE }；@ComponentV2 export struct CouliCard，
     参数 kind=STATIC / press=BOUNCE / disabled=false / a11yText='' / groupAccessibility=true / elevated=true、@Event onTap、@BuilderParam content；
     build() 以 this.kind 与 CouliCardKind 的单一比较分两支：TAPPABLE 恰经一个 CouliPressable（kind/disabled/groupAccessibility/a11yText
     直传、onTap 转发、this.content() 在其尾随闭包里），STATIC 不经 Pressable；卡内无 .onClick / 手势（无反馈的裸点击）；Index.ets 导出
  C2 令牌：STATIC 卡容器同链 backgroundColor(CouliColors.backgroundSurface) + borderRadius(CouliRadius.card) + shadow(…CouliShadow.card…)；
     TAPPABLE 白底经 normalColor 或 Pressable 外层（不许画在 Pressable 内容里盖住按压色）、外层 borderRadius(CouliRadius.card) + clip(true)、
     shadow(…CouliShadow.card…)；用 this.elevated；全文件无颜色字面量 / 具名色 / $r；样式属性实参无字面量、只来自令牌类（同 ds02/test_host.py:159）
  C3 CouliPressable（F-HM-98 / S2-1、S2-2）：@Param disabled=false / groupAccessibility=true / a11yText='' / normalColor: ResourceColor=Color.Transparent；
     两条 .onClick 链（BOUNCE clickEffect、HIGHLIGHT stateStyles）各有 .enabled(!this.disabled)、.accessibilityGroup(this.groupAccessibility)、
     .accessibilityText(…this.a11yText…)；onClick 闭包里 this.onTap() 被禁用态守住；HIGHLIGHT 常态底色取 this.normalColor
     书 §2.1 / §2.2 写的 @Param enabled 落不了：与 CustomComponent.enabled（通用属性方法）同名，SDK 类型检查 2416（参照件实测），
     按仓库惯例（Basics / Controls / Display 的 @Param disabled: boolean = false）改名 disabled，语义不变
  C4 CouliPressable / CouliCard 无 CouliHaptics / vibrator / HapticPlan，不读 motion 令牌（README §3.2、D10-838）
  C5 --self-test：参照件 0 违反；去 group、去禁用判定、TAPPABLE 无反馈、白底字面量、加触感等错误实现逐个打红（另含 run-logic 变异）
  C6 目录：CatalogManifest 恰一条 c('CouliCard', GROUP_LISTS, KIND_L2, …)，矩阵 = 3 × 3 + list-group × default；CatalogSampleViews 有单独 CouliCard
     分支，样例画真实 CouliCard（kind / press / disabled / onTap + 内容）与 ListItemGroup(CARD) + ≥ 2 个 ListItem(CARD)，样例不自己刷底色；
     inventory.tsv 的 CouliCard 行与矩阵一致（README ⑨，#24 只加行）
  C7 登记：entry ohosTest List.test.ets 顶层恰调用一次 ds02L2UiTest（README ⑩，#24 只加）；designsystem List.test.ets 恰调用一次 l2CardTest；
     verify.sh 跑本检查（自测 + 本体）、run-logic.cjs、check-arkts.cjs；Ds02L2Ui 的 describe 名 = Ds02L2Ui、it 名 = L2CARD_DEVICE_CASES = device-cases.txt
  C8 页面 / 功能模块（features/*/src/main、entry/src/main）不出现 CouliCard / CouliCardKind（书 §2.4、§4 页面 0 改动）

测试 v2（评审 r1，判据只收紧；属性实参按参数取值求，只认 this.elevated / this.inset 的布尔式、三元与 if，求不出按违反）：
  S2-1  C3-corner：CouliPressable 两条 .onClick 链（clickEffect 缩放 / stateStyles 那层）各有 .borderRadius(this.cornerRadius) + .clip(true)，
        @Param cornerRadius: Length = 0（C3-props）；C2-tappable-corner：CouliCard 传 cornerRadius: CouliRadius.card
  S3-2  C2-elevated：elevated=false（或 inset=true）时任何 shadow 都不是 shadow.card（极性）；C2-shadow-radius：带 shadow.card 的那层同链
        borderRadius(CouliRadius.card)；C2-padding：两种卡包住 this.content() 的最近一层 .padding(this.cardPadding)（TAPPABLE 在 Pressable 闭包里）
  S3-5  C9 给 HM-L2-SKELETON / HM-L2-PRODUCT-CELL 的接口（调用方不能在卡后接属性，SDK 1128，check-arkts.cjs 另有探针）：
        C1-props 加 a11yLevel: string = 'auto'、inset: boolean = false、cardPadding: Padding | Length = CouliSpacing.space3；
        C9-a11y STATIC 包住内容的一层 accessibilityGroup(this.groupAccessibility) + accessibilityText(…this.a11yText…)；
        C9-level 两种卡最外层 .accessibilityLevel(this.a11yLevel)；C9-clip STATIC 常态按卡片圆角 clip、inset 时不按卡片圆角 clip；
        C9-inset inset=true 时无 surface 白底（含 Pressable normalColor）、无 shadow.card

用法：
  python3 tools/ci/l2card/check_l2_card.py [--root <目录>]    检查（默认仓库根）
  python3 tools/ci/l2card/check_l2_card.py --self-test        参照件（fixtures/good）0 违反 + 每个错误实现被打红（REFERENCE_ONLY，不算产品通过）
退出码：0 通过；1 有违反（自测：有变异没被杀或正例不过）；2 参数不对；3 解析工具链不可用；4 无法保证判定完整（语法错误、必需文件缺失）。
CouliCard.ets 不存在按 C1 违反（红在断言），不按 4。
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
AST_TOOL = os.path.join(HERE, "l2card_ast.cjs")
RUN_LOGIC = os.path.join(HERE, "run-logic.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")

CARD = "common/designsystem/src/main/ets/components/CouliCard.ets"
PRESS = "common/designsystem/src/main/ets/components/CouliPressable.ets"
INDEX = "common/designsystem/Index.ets"
MANIFEST = "entry/src/staging/ets/catalog/CatalogManifest.ets"
SAMPLES = "entry/src/staging/ets/catalog/CatalogSampleViews.ets"
ENTRY_LIST = "entry/src/ohosTest/ets/test/List.test.ets"
DS_LIST = "common/designsystem/src/test/List.test.ets"
DEVICE_SUITE = "entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets"
DEVICE_CASES = "tools/ci/l2card/device-cases.txt"
INVENTORY = "tools/ci/ds02/fixtures/inventory.tsv"
VERIFY = "tools/ci/verify.sh"
FILES = (CARD, PRESS, INDEX, MANIFEST, SAMPLES, ENTRY_LIST, DS_LIST, DEVICE_SUITE)
PAGE_DIRS = ("entry/src/main",)
SKIP_DIRS = {"build", "oh_modules", "node_modules", ".hvigor", ".test", ".preview"}
EXPECTED_CASES = sorted([v + "/" + s for v in ("static", "tappable-bounce", "tappable-highlight")
                         for s in ("default", "pressed", "disabled")] + ["list-group/default"])
VERIFY_STEPS = ("tools/ci/l2card/check_l2_card.py --self-test", "tools/ci/l2card/check_l2_card.py",
                "tools/ci/l2card/run-logic.cjs", "tools/ci/l2card/check-arkts.cjs")
RULE_TITLES = {
    "C1": "CouliCard 结构（两种入口、经 CouliPressable、无裸点击、默认值、导出）",
    "C2": "卡内只用令牌（白底 / 圆角 / 阴影；不盖住按压色；回弹层圆角、阴影极性与圆角、内边距）",
    "C3": "CouliPressable F-HM-98（disabled → enabled(!disabled)、判禁用、读屏合一、normalColor）+ 按压层圆角 cornerRadius",
    "C4": "无触感、不读 motion 令牌",
    "C6": "目录矩阵、样例分支、ListItemGroup CARD、inventory",
    "C7": "登记（两份 List、verify 步、设备用例名单）",
    "C8": "页面不用 CouliCard",
    "C9": "给后续单的接口（静态卡读屏参数、最外层读屏层级、静态卡圆角裁剪、平铺 inset）",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_l2card", os.path.join(HERE, "..", "lint.py"))
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
    """features/*/src/main 与 entry/src/main 下含 CouliCard 子串的 .ets / .ts（再由 AST 判是否真是标识符）。"""
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
                if "CouliCard" in text:
                    out[rel] = text
    return out


def check_inventory(root, manifest_cases):
    text = read(root, INVENTORY)
    if text is None:
        raise Incomplete("%s: 文件不存在，无法判定" % INVENTORY)
    rows = [line.split("\t") for line in text.splitlines() if line.startswith("CouliCard\t")]
    if not rows:
        return [{"rule": "C6-inventory", "file": INVENTORY, "line": 0,
                 "msg": "inventory.tsv 没有 CouliCard 行（README ⑨：本单只加行，#24 落；gen.py 重出两份 Ds02Expected）"}]
    out = []
    cases = []
    for row in rows:
        if len(row) < 5:
            out.append({"rule": "C6-inventory", "file": INVENTORY, "line": 0, "msg": "CouliCard 行缺列：%s" % "\t".join(row)})
            continue
        if row[1] != "§3.5" or row[2] != "L2 业务组件":
            out.append({"rule": "C6-inventory", "file": INVENTORY, "line": 0,
                        "msg": "CouliCard 行应为 §3.5 / L2 业务组件，实际 %s / %s" % (row[1], row[2])})
        cases += [v + "/" + s for v in row[3].split(",") for s in row[4].split(",")]
    if sorted(cases) != EXPECTED_CASES or (manifest_cases is not None and sorted(cases) != sorted(manifest_cases)):
        out.append({"rule": "C6-inventory", "file": INVENTORY, "line": 0,
                    "msg": "inventory 的 CouliCard 变体 × 状态应与目录矩阵一致（10 例），实际 %s" % " ".join(sorted(cases))})
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
            out.append({"rule": "C7-verify", "file": VERIFY, "line": 0, "msg": "verify.sh 没有（非注释）跑 %s（书 §4：verify 一步，只加）" % step})
    return out


def check_device_cases(root, facts):
    out = []
    text = read(root, DEVICE_CASES)
    listed = None if text is None else [line.strip() for line in text.splitlines() if line.strip() and not line.startswith("#")]
    const = facts.get("deviceConst")
    its = facts.get("deviceIts")
    if listed is None or const is None or its is None:
        out.append({"rule": "C7-cases", "file": DEVICE_CASES, "line": 0, "msg": "缺 device-cases.txt 或 Ds02L2Ui.test.ets 的 L2CARD_DEVICE_CASES"})
        return out
    if facts.get("deviceDescribes") != ["Ds02L2Ui"]:
        out.append({"rule": "C7-cases", "file": DEVICE_SUITE, "line": 0,
                    "msg": "Ds02L2Ui.test.ets 应恰有一个 describe('Ds02L2Ui')（COULI_HM_TEST_FILTER class=Ds02L2Ui），实际 %s" % facts.get("deviceDescribes")})
    if not (sorted(listed) == sorted(const) == sorted(its)) or len(set(listed)) != len(listed):
        out.append({"rule": "C7-cases", "file": DEVICE_CASES, "line": 0,
                    "msg": "device-cases.txt / L2CARD_DEVICE_CASES / it 名不一致：%s | %s | %s" % (sorted(listed), sorted(const), sorted(its))})
    return out


def check(root):
    """返回违反列表；语法错误 / 必需文件缺失抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
    tool = lint.hm10_toolchain()
    scan = page_candidates(root)
    files = dict(scan)
    for rel in FILES:
        files[rel] = read(root, rel)
    payload = json.dumps({"files": files, "scan": sorted(scan)}, ensure_ascii=False).encode("utf-8")
    try:
        proc = subprocess.run([tool["node"], AST_TOOL, tool["typescript"]], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise lint.HM10ToolchainError("运行 node 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("l2card_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("l2card_ast.cjs 输出无法解析：%s" % e)
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

CD, PR, IX, MF, SV, EL, DL, DS, VF, IV = CARD, PRESS, INDEX, MANIFEST, SAMPLES, ENTRY_LIST, DS_LIST, DEVICE_SUITE, VERIFY, INVENTORY
PAGE = "features/demo/src/main/ets/DemoPage.ets"
# 参照件 CouliCard（测试 v2）里反复用到的原串
ST_BG = ("        .backgroundColor(this.inset ? Color.Transparent : CouliColors.backgroundSurface)\n        .borderRadius(CouliRadius.card)\n"
         "        .clip(!this.inset)\n")
ST_SH = ("      .borderRadius(CouliRadius.card)\n      .shadow(this.elevated && !this.inset ? CouliShadow.card : undefined)\n"
         "      .accessibilityGroup(this.groupAccessibility)\n")
TP_SH = ("      .borderRadius(CouliRadius.card)\n      .shadow(this.elevated && !this.inset ? CouliShadow.card : undefined)\n"
         "      .accessibilityLevel(this.a11yLevel)\n    } else {")
TP_NORMAL = "normalColor: this.inset ? Color.Transparent : CouliColors.backgroundSurface,"
TP_PAD = "            .width('100%')\n            .padding(this.cardPadding)\n"
ST_PAD = "        .width('100%')\n        .padding(this.cardPadding)\n"
PR_BOUNCE = "      }\n      .borderRadius(this.cornerRadius)\n      .clip(true)\n      .backgroundColor(this.normalColor)\n"
PR_HIGH = "      }\n      .borderRadius(this.cornerRadius)\n      .clip(true)\n      .stateStyles({\n"
# （名字，文件，原串，新串，应报的规则前缀）；原串在参照件里必须唯一。
MUTATIONS = [
    # ---- 书 §3 C5 点名的五类
    ("去 group（BOUNCE 链）", PR, "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .enabled(!this.disabled)\n      .accessibilityGroup(this.groupAccessibility)\n",
     "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .enabled(!this.disabled)\n", "C3-group"),
    ("去 group（HIGHLIGHT 链）", PR, "      })\n      .enabled(!this.disabled)\n      .accessibilityGroup(this.groupAccessibility)\n",
     "      })\n      .enabled(!this.disabled)\n", "C3-group"),
    ("group 写死 true（不随参数，商品卡关不掉）", PR, "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .enabled(!this.disabled)\n      .accessibilityGroup(this.groupAccessibility)\n",
     "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .enabled(!this.disabled)\n      .accessibilityGroup(true)\n", "C3-group"),
    ("去禁用判定（BOUNCE 闭包直接调）", PR, "      .onClick((): void => {\n        if (!this.disabled) {\n          this.onTap();\n        }\n      })\n    } else {",
     "      .onClick((): void => {\n        this.onTap();\n      })\n    } else {", "C3-guard"),
    ("禁用判定写反（不禁用时 return）", PR, "        if (this.disabled) {\n          return;\n        }\n        this.onTap();",
     "        if (!this.disabled) {\n          return;\n        }\n        this.onTap();", "C3-guard"),
    ("判定挪出 onClick（闭包里不再调 onTap）", PR, "        if (this.disabled) {\n          return;\n        }\n        this.onTap();",
     "        this.fire();", "C3-guard"),
    ("TAPPABLE 无反馈（不经 Pressable，裸 Column + onClick）", CD,
     "          CouliPressable({\n            kind: this.press,", "          Column() {\n          }\n          .onClick((): void => {\n            this.onTap();\n          })\n          Blank({\n            kind: this.press,", "C1"),
    ("STATIC 卡加裸 onClick", CD, "      .accessibilityLevel(this.a11yLevel)\n    }\n  }\n}",
     "      .accessibilityLevel(this.a11yLevel)\n      .onClick((): void => {\n        this.onTap();\n      })\n    }\n  }\n}", "C1-click"),
    ("白底字面量（STATIC）", CD, ST_BG, ST_BG.replace("CouliColors.backgroundSurface", "'#FFFFFF'"), "C2"),
    ("白底具名色 Color.White（TAPPABLE normalColor）", CD, TP_NORMAL, TP_NORMAL.replace("CouliColors.backgroundSurface", "Color.White"), "C2"),
    ("加触感（CouliCard）", CD, "            onTap: (): void => {\n              this.onTap();",
     "            onTap: (): void => {\n              CouliHaptics.selection();\n              this.onTap();", "C4-haptics"),
    ("加触感（CouliPressable）", PR, "        this.onTap();\n      })\n    }\n  }\n}", "        CouliHaptics.selection();\n        this.onTap();\n      })\n    }\n  }\n}", "C4-haptics"),
    # ---- C1 结构
    ("CouliCard.ets 不存在", CD, None, None, "C1-missing"),
    ("枚举顺序反了（默认值 0 变成 TAPPABLE）", CD, "  STATIC,\n  TAPPABLE\n", "  TAPPABLE,\n  STATIC\n", "C1-enum"),
    ("枚举多一个 BRAND（书 §2.2 不提供品牌实底）", CD, "  STATIC,\n  TAPPABLE\n", "  STATIC,\n  TAPPABLE,\n  BRAND\n", "C1-enum"),
    ("kind 默认 TAPPABLE", CD, "@Param kind: CouliCardKind = CouliCardKind.STATIC;", "@Param kind: CouliCardKind = CouliCardKind.TAPPABLE;", "C1-props"),
    ("press 默认 HIGHLIGHT", CD, "@Param press: PressKind = PressKind.BOUNCE;", "@Param press: PressKind = PressKind.HIGHLIGHT;", "C1-props"),
    ("groupAccessibility 默认 false", CD, "@Param groupAccessibility: boolean = true;", "@Param groupAccessibility: boolean = false;", "C1-props"),
    ("disabled 改 @Local", CD, "@Param disabled: boolean = false;", "@Local disabled: boolean = false;", "C1-props"),
    ("缺 a11yText 参数", CD, "  @Param a11yText: string = '';\n", "", "C1-props"),
    ("struct 用 V1 @Component", CD, "@ComponentV2\nexport struct CouliCard", "@Component\nexport struct CouliCard", "C1-struct"),
    ("分支写反（STATIC 走 Pressable）", CD, "if (this.kind === CouliCardKind.TAPPABLE) {", "if (this.kind === CouliCardKind.STATIC) {", "C1"),
    ("分支条件复合", CD, "if (this.kind === CouliCardKind.TAPPABLE) {", "if (this.kind === CouliCardKind.TAPPABLE && !this.disabled) {", "C1-branch"),
    ("disabled 不传给 Pressable（禁用卡照样可点）", CD, "            disabled: this.disabled,\n", "", "C1-forward"),
    ("group 不传给 Pressable", CD, "            groupAccessibility: this.groupAccessibility,\n", "", "C1-forward"),
    ("press 写死 BOUNCE（highlight 变体失效）", CD, "            kind: this.press,", "            kind: PressKind.BOUNCE,", "C1-forward"),
    ("a11yText 不传", CD, "            a11yText: this.a11yText,\n", "", "C1-forward"),
    ("onTap 不转发（点击丢失）", CD, "            onTap: (): void => {\n              this.onTap();\n            }", "            onTap: (): void => {\n            }", "C1-forward"),
    ("内容放在 Pressable 外（不在同一读屏项）", CD, "          }) {\n            Column() {\n              this.content()\n            }",
     "          }) {\n            Column() {\n            }", "C1-content"),
    ("Index 不导出 CouliCardKind", IX, "export { CouliCard, CouliCardKind } from './src/main/ets/components/CouliCard';",
     "export { CouliCard } from './src/main/ets/components/CouliCard';", "C1-index"),
    ("TAPPABLE 加 TapGesture", CD, "        .borderRadius(CouliRadius.card)\n        .clip(true)\n",
     "        .borderRadius(CouliRadius.card)\n        .clip(true)\n        .gesture(TapGesture().onAction(() => {\n          this.onTap();\n        }))\n", "C1-click"),
    # ---- C2 令牌
    ("Pressable 内容自带白底（盖住 HIGHLIGHT 按压色，书 §1 表）", CD, "            .alignItems(HorizontalAlign.Start)\n          }",
     "            .alignItems(HorizontalAlign.Start)\n            .backgroundColor(CouliColors.backgroundSurface)\n          }", "C2-cover"),
    ("TAPPABLE 没有白底", CD, "            " + TP_NORMAL + "\n", "", "C2-tappable-surface"),
    ("TAPPABLE 白底换成 muted", CD, TP_NORMAL, TP_NORMAL.replace("backgroundSurface", "backgroundMuted"), "C2-tappable-surface"),
    ("TAPPABLE 不 clip（按压色方角漏出）", CD, "        .borderRadius(CouliRadius.card)\n        .clip(true)\n", "        .borderRadius(CouliRadius.card)\n", "C2-tappable-radius"),
    ("TAPPABLE clip 与圆角不在同一容器", CD, "        .borderRadius(CouliRadius.card)\n        .clip(true)\n      }\n      .width('100%')\n      .borderRadius(CouliRadius.card)\n",
     "        .clip(true)\n      }\n      .width('100%')\n      .borderRadius(CouliRadius.card)\n", "C2-tappable-radius"),
    ("TAPPABLE 圆角写 12", CD, "        .borderRadius(CouliRadius.card)\n        .clip(true)\n", "        .borderRadius(12)\n        .clip(true)\n", "C2"),
    ("TAPPABLE 圆角换 small", CD, "        .borderRadius(CouliRadius.card)\n        .clip(true)\n", "        .borderRadius(CouliRadius.small)\n        .clip(true)\n", "C2-tappable-radius"),
    ("TAPPABLE 无阴影", CD, TP_SH, TP_SH.replace("      .shadow(this.elevated && !this.inset ? CouliShadow.card : undefined)\n", ""), "C2-tappable-shadow"),
    ("STATIC 阴影字面量", CD, ST_SH, ST_SH.replace("this.elevated && !this.inset ? CouliShadow.card : undefined", "{ radius: 8, color: CouliColors.backgroundMuted }"), "C2"),
    ("STATIC 圆角 panel", CD, ST_BG, ST_BG.replace("CouliRadius.card", "CouliRadius.panel"), "C2-static-surface"),
    ("STATIC 底色 canvas", CD, ST_BG, ST_BG.replace("CouliColors.backgroundSurface", "CouliColors.backgroundCanvas"), "C2-static-surface"),
    ("STATIC 直接 $r 资源", CD, ST_BG, ST_BG.replace("CouliColors.backgroundSurface", "$r('app.color.background_surface')"), "C2"),
    ("elevated 不起作用", CD, ST_SH, ST_SH.replace("this.elevated && !this.inset ? CouliShadow.card : undefined", "!this.inset ? CouliShadow.card : undefined"), "C2-elevated"),
    # ---- 测试 v2：评审 r1 S3-2 宿主 / 设备都拦不住的三个变异（原样）及同类
    ("STATIC elevated 判断写反（评审 r1 漏网 ①）", CD, ST_SH, ST_SH.replace("this.elevated && !this.inset ? CouliShadow.card : undefined", "this.elevated ? undefined : CouliShadow.card"), "C2-elevated"),
    ("TAPPABLE elevated 判断写反", CD, TP_SH, TP_SH.replace("this.elevated && !this.inset ? CouliShadow.card : undefined", "this.elevated ? undefined : CouliShadow.card"), "C2-elevated"),
    ("elevated 取反（条件里仍提到 elevated，v1 的「受控」判据放过）", CD, ST_SH, ST_SH.replace("this.elevated && !this.inset ?", "!this.elevated && !this.inset ?"), "C2-elevated"),
    ("TAPPABLE 外层去掉圆角（阴影变直角，评审 r1 漏网 ②）", CD, TP_SH, TP_SH.replace("      .borderRadius(CouliRadius.card)\n", ""), "C2-shadow-radius"),
    ("STATIC 阴影那层去掉圆角", CD, ST_SH, ST_SH.replace("      .borderRadius(CouliRadius.card)\n", ""), "C2-shadow-radius"),
    ("TAPPABLE 阴影那层圆角换 small", CD, TP_SH, TP_SH.replace("CouliRadius.card", "CouliRadius.small"), "C2-shadow-radius"),
    ("TAPPABLE 不用 cardPadding（评审 r1 漏网 ③）", CD, TP_PAD, "            .width('100%')\n", "C2-padding"),
    ("TAPPABLE 内边距写死 space3", CD, TP_PAD, TP_PAD.replace("this.cardPadding", "CouliSpacing.space3"), "C2-padding"),
    ("STATIC 不用 cardPadding", CD, ST_PAD, "        .width('100%')\n", "C2-padding"),
    ("TAPPABLE 内边距挪到 Pressable 外（白底 / 按压色不盖内边距）", CD,
     TP_PAD + "            .alignItems(HorizontalAlign.Start)\n          }\n        }\n        .width('100%')\n",
     "            .width('100%')\n            .alignItems(HorizontalAlign.Start)\n          }\n        }\n        .width('100%')\n        .padding(this.cardPadding)\n", "C2-padding"),
    ("阴影开关写成方法（守卫求不出，按违反）", CD, ST_SH, ST_SH.replace("this.elevated && !this.inset ?", "this.elevated && this.flat() ?"), "C2-elevated"),
    # ---- 测试 v2：评审 r1 S2-1 回弹卡按住露直角白底
    ("Pressable BOUNCE 层无圆角（S2-1 原样）", PR, PR_BOUNCE, PR_BOUNCE.replace("      .borderRadius(this.cornerRadius)\n", ""), "C3-corner"),
    ("Pressable BOUNCE 层不裁剪", PR, PR_BOUNCE, PR_BOUNCE.replace("      .clip(true)\n", ""), "C3-corner"),
    ("Pressable BOUNCE 层圆角写死 0", PR, PR_BOUNCE, PR_BOUNCE.replace("this.cornerRadius", "0"), "C3-corner"),
    ("Pressable HIGHLIGHT 层无圆角（按压色方角）", PR, PR_HIGH, PR_HIGH.replace("      .borderRadius(this.cornerRadius)\n", ""), "C3-corner"),
    ("Pressable HIGHLIGHT 层 clip(false)", PR, PR_HIGH, PR_HIGH.replace("clip(true)", "clip(false)"), "C3-corner"),
    ("cornerRadius 默认 16（FeelLab 观感变了）", PR, "@Param cornerRadius: Length = 0;", "@Param cornerRadius: Length = 16;", "C3-props"),
    ("缺 @Param cornerRadius", PR, "  @Param cornerRadius: Length = 0;\n", "", "C3-props"),
    ("卡片不把圆角交给 Pressable（S2-1：只有外层裁剪，缩放层直角）", CD, "            cornerRadius: CouliRadius.card,\n", "", "C2-tappable-corner"),
    ("卡片 cornerRadius 传 small", CD, "            cornerRadius: CouliRadius.card,\n", "            cornerRadius: CouliRadius.small,\n", "C2-tappable-corner"),
    # ---- 测试 v2：评审 r1 S3-5 后续单接口（SKELETON / PRODUCT-CELL）
    ("STATIC 不合组读屏", CD, "      .accessibilityGroup(this.groupAccessibility)\n", "", "C9-a11y"),
    ("STATIC 读屏合组写死 true（商品卡关不掉）", CD, "      .accessibilityGroup(this.groupAccessibility)\n", "      .accessibilityGroup(true)\n", "C9-a11y"),
    ("STATIC 不传读屏名", CD, "      .accessibilityText(this.a11yText)\n", "", "C9-a11y"),
    ("缺 a11yLevel 参数", CD, "  @Param a11yLevel: string = 'auto';\n", "", "C1-props"),
    ("a11yLevel 默认 no-hide-descendants（所有卡读屏消失）", CD, "@Param a11yLevel: string = 'auto';", "@Param a11yLevel: string = 'no-hide-descendants';", "C1-props"),
    ("TAPPABLE 最外层没有 accessibilityLevel", CD, "      .accessibilityLevel(this.a11yLevel)\n    } else {", "    } else {", "C9-level"),
    ("STATIC 读屏层级写死 auto（骨架藏不掉）", CD, "      .accessibilityLevel(this.a11yLevel)\n    }\n  }\n}", "      .accessibilityLevel('auto')\n    }\n  }\n}", "C9-level"),
    ("STATIC 不裁剪（内容贴边盖住圆角）", CD, ST_BG, ST_BG.replace("        .clip(!this.inset)\n", ""), "C9-clip"),
    ("STATIC 裁剪写死 true（平铺也切角）", CD, ST_BG, ST_BG.replace("clip(!this.inset)", "clip(true)"), "C9-clip"),
    ("缺 inset 参数", CD, "  @Param inset: boolean = false;\n", "", "C1-props"),
    ("inset 默认 true", CD, "@Param inset: boolean = false;", "@Param inset: boolean = true;", "C1-props"),
    ("STATIC 平铺仍画白底", CD, ST_BG, ST_BG.replace("this.inset ? Color.Transparent : CouliColors.backgroundSurface", "CouliColors.backgroundSurface"), "C9-inset"),
    ("STATIC inset 判断写反（常态透明）", CD, ST_BG, ST_BG.replace("this.inset ? Color.Transparent : CouliColors.backgroundSurface", "this.inset ? CouliColors.backgroundSurface : Color.Transparent"), "C2-static-surface"),
    ("TAPPABLE 平铺仍画白底", CD, TP_NORMAL, "normalColor: CouliColors.backgroundSurface,", "C9-inset"),
    ("STATIC 平铺仍有阴影", CD, ST_SH, ST_SH.replace("this.elevated && !this.inset ?", "this.elevated ?"), "C9-inset"),
    ("TAPPABLE 平铺仍有阴影", CD, TP_SH, TP_SH.replace("this.elevated && !this.inset ?", "this.elevated ?"), "C9-inset"),
    ("cardPadding 默认改 space2", CD, "@Param cardPadding: Padding | Length = CouliSpacing.space3;", "@Param cardPadding: Padding | Length = CouliSpacing.space2;", "C1-props"),
    # ---- C3 CouliPressable
    ("去 .enabled(!this.disabled)（HIGHLIGHT 禁用仍有按压色）", PR, "      })\n      .enabled(!this.disabled)\n      .accessibilityGroup", "      })\n      .accessibilityGroup", "C3-enabled"),
    ("enabled 写死 true", PR, "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .enabled(!this.disabled)\n", "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .enabled(true)\n", "C3-enabled"),
    ("缺 @Param disabled", PR, "  @Param disabled: boolean = false;\n", "", "C3-props"),
    ("groupAccessibility 默认 false", PR, "@Param groupAccessibility: boolean = true;", "@Param groupAccessibility: boolean = false;", "C3-props"),
    ("normalColor 默认白（库内其他可点行全变白底）", PR, "@Param normalColor: ResourceColor = Color.Transparent;", "@Param normalColor: ResourceColor = CouliColors.backgroundSurface;", "C3-props"),
    ("HIGHLIGHT 常态仍写死透明", PR, "normal: { .backgroundColor(this.normalColor) }", "normal: { .backgroundColor(Color.Transparent) }", "C3-normal"),
    ("BOUNCE 不用 normalColor（回弹卡丢白底）", PR, "      .backgroundColor(this.normalColor)\n      .clickEffect", "      .clickEffect", "C2-bounce-surface"),
    ("去 accessibilityText（HIGHLIGHT）", PR, "      .accessibilityGroup(this.groupAccessibility)\n      .accessibilityText(this.a11yText)\n      .onClick((): void => {\n        if (this.disabled)",
     "      .accessibilityGroup(this.groupAccessibility)\n      .onClick((): void => {\n        if (this.disabled)", "C3-text"),
    ("HIGHLIGHT 分支没了 onClick（只剩一条链）", PR, "      .accessibilityText(this.a11yText)\n      .onClick((): void => {\n        if (this.disabled) {\n          return;\n        }\n        this.onTap();\n      })\n",
     "      .accessibilityText(this.a11yText)\n", "C3-branches"),
    # ---- C4
    ("CouliPressable 读 motion 令牌", PR, "@Param a11yText: string = '';", "@Param a11yText: string = '';\n  private token: string = 'motion.duration.micro';", "C4-motion-token"),
    ("CouliCard 读 motion 令牌", CD, "@Param a11yText: string = '';", "@Param a11yText: string = '';\n  private token: string = 'motion.duration.micro';", "C4-motion-token"),
    # ---- C6 目录
    ("目录漏 disabled 态", MF, "['default', 'pressed', 'disabled']", "['default', 'pressed']", "C6-manifest"),
    ("目录漏 list-group 样例", MF, ", m(['list-group'], ['default'])", "", "C6-manifest"),
    ("目录标成 L1", MF, "c('CouliCard', GROUP_LISTS, KIND_L2,", "c('CouliCard', GROUP_LISTS, KIND_L1,", "C6-manifest"),
    ("目录放到业务组", MF, "c('CouliCard', GROUP_LISTS, KIND_L2,", "c('CouliCard', GROUP_BUSINESS, KIND_L2,", "C6-manifest"),
    ("目录没有 CouliCard 分支（落进 BusinessSample）", SV, "      } else if (this.component === 'CouliCard') {\n        CardSample({ variant: this.variant, state: this.state, controlId: this.controlId() })\n",
     "", "C6-sample-branch"),
    ("ListItemGroup 不是 CARD 样式", SV, "ListItemGroup({ style: ListItemGroupStyle.CARD })", "ListItemGroup({ style: ListItemGroupStyle.NONE })", "C6-sample-list"),
    ("ListItem 不是 CARD 样式", SV, "ListItem({ style: ListItemStyle.CARD }) {\n            Text('订单状态通知')", "ListItem() {\n            Text('订单状态通知')", "C6-sample-list"),
    ("样例自己刷白底", SV, "        .width('100%')\n        .id(this.controlId)\n        Text(", "        .width('100%')\n        .backgroundColor(CouliColors.backgroundSurface)\n        .id(this.controlId)\n        Text(", "C6-sample-nobg"),
    ("样例不传 disabled（禁用态不禁用）", SV, "            disabled: this.state === 'disabled',\n", "", "C6-sample-card"),
    ("inventory 漏 CouliCard", IV, "CouliCard\t§3.5\tL2 业务组件\tstatic,tappable-bounce,tappable-highlight\tdefault,pressed,disabled\n", "", "C6-inventory"),
    ("inventory 状态与目录不同", IV, "\tdefault,pressed,disabled\n", "\tdefault,pressed\n", "C6-inventory"),
    # ---- C7 登记
    ("entry List 没注册 Ds02L2Ui", EL, "  ds02L2UiTest();\n", "", "C7-entry-list"),
    ("entry List 注册包进 if", EL, "  ds02L2UiTest();\n", "  if (Date.now() < 0) {\n    ds02L2UiTest();\n  }\n", "C7-entry-list"),
    ("entry List 注册两次", EL, "  ds02L2UiTest();\n", "  ds02L2UiTest();\n  ds02L2UiTest();\n", "C7-entry-list"),
    ("entry List 只在注释里", EL, "  ds02L2UiTest();\n", "  // ds02L2UiTest();\n", "C7-entry-list"),
    ("designsystem List 没注册 L2Card", DL, "  l2CardTest();\n", "", "C7-ds-list"),
    ("verify 只跑自测不跑本体", VF, "python3 \"$ROOT/tools/ci/l2card/check_l2_card.py\"\n", "", "C7-verify"),
    ("verify 不跑 run-logic", VF, "node \"$ROOT/tools/ci/l2card/run-logic.cjs\"\n", "# node \"$ROOT/tools/ci/l2card/run-logic.cjs\"\n", "C7-verify"),
    ("设备套件 describe 改名（过滤 class=Ds02L2Ui 失效）", DS, "describe('Ds02L2Ui'", "describe('Ds02L2UiX'", "C7-cases"),
    ("设备名单与 it 不一致", DS, "it('l2card_08_list_item_group_card_style_sample'", "it('l2card_08_renamed'", "C7-cases"),
    # ---- C8 页面
    ("页面用了 CouliCard", PAGE, "  build() {\n    Column() {\n", "  build() {\n    Column() {\n      CouliCard() {\n      }\n", "C8-pages"),
]
# 页面正例：DemoPage.ets 只在注释 / 字符串里提到 CouliCard，不算（保证不是全文 grep）。


def copy_good(dest):
    shutil.copytree(GOOD, dest)


def run_logic_mutants():
    """run-logic.cjs 的行为变异（L2Card.test.ets 真跑在参照件的枚举与 Index 导出上）：参照件全绿、变异至少一条红。"""
    failures = []
    tool = lint.hm10_toolchain()
    base = [tool["node"], RUN_LOGIC, "--root", GOOD]
    env = dict(os.environ, COULI_HM_TYPESCRIPT=tool["typescript"])
    proc = subprocess.run(base, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    if proc.returncode != 0:
        failures.append("run-logic 参照件不绿：%s" % proc.stdout.decode("utf-8", "replace")[-600:])
    with tempfile.TemporaryDirectory(prefix="l2card-logic-") as tmp:
        for name, rel, old, new in [
            ("枚举顺序反了", CARD, "  STATIC,\n  TAPPABLE\n", "  TAPPABLE,\n  STATIC\n"),
            ("TAPPABLE 显式 = 0", CARD, "  STATIC,\n  TAPPABLE\n", "  STATIC = 1,\n  TAPPABLE = 0\n"),
            ("Index 不导出 CouliCardKind", INDEX, "export { CouliCard, CouliCardKind } from './src/main/ets/components/CouliCard';",
             "export { CouliCard } from './src/main/ets/components/CouliCard';"),
        ]:
            with open(os.path.join(GOOD, rel), encoding="utf-8") as f:
                text = f.read()
            if text.count(old) != 1:
                failures.append("run-logic 变异「%s」原串不唯一" % name)
                continue
            swap = os.path.join(tmp, name.replace(" ", "_") + os.path.splitext(rel)[1])
            with open(swap, "w", encoding="utf-8") as f:
                f.write(text.replace(old, new))
            proc = subprocess.run(base + ["--swap", rel, swap, "--expect-red"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
            if proc.returncode != 0:
                failures.append("run-logic 变异「%s」没被打红：%s" % (name, proc.stdout.decode("utf-8", "replace")[-400:]))
    return failures, 4


SIM = os.path.join(HERE, "sim-corners.cjs")


def sim_mutants():
    """测试 v2：设备 l2card_03 的「缩小卡片四角」判定（真实 Ds02L2Ui.test.ets 原文）离线合成图自测：原样全对、削弱判定的变异必须被打红。"""
    failures = []
    tool = lint.hm10_toolchain()
    env = dict(os.environ, COULI_HM_TYPESCRIPT=tool["typescript"])
    suite_path = os.path.join(REPO_ROOT, DEVICE_SUITE)
    proc = subprocess.run([tool["node"], SIM, "--suite", suite_path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    if proc.returncode != 0:
        failures.append("sim-corners 原样不过：%s" % proc.stdout.decode("utf-8", "replace")[-600:])
    with open(suite_path, encoding="utf-8") as f:
        text = f.read()
    mutants = [
        ("不查截屏是否在按住期间（松手后截也算过）", "  if (left < heldMin) {\n", "  if (left < 0) {\n"),
        # 测试 v4（编排 17:46，#24）：前置判定容差两侧都要有牙。
        ("前置判定退回严格大于理论值（按住也判 NOT_HELD）", "  const heldMin: number = Math.round(4 * dens * scale) - 1;",
         "  const heldMin: number = Math.round(4 * dens * scale) + 1;"),
        ("前置判定容差放宽（没按住也判成按住）", "  const heldMin: number = Math.round(4 * dens * scale) - 1;",
         "  const heldMin: number = Math.round(4 * dens * scale) - 3;"),
        ("角点取样不往里收（落在卡边抗锯齿上）", "  const k: number = Math.max(2, Math.round(1.5 * dens * scale));",
         "  const k: number = -Math.max(2, Math.round(1.5 * dens * scale));"),
        ("角点判定反了", "      if (isTone(shot, x, y, surface)) { square.push(", "      if (!isTone(shot, x, y, surface)) { square.push("),
        ("isTone 只认 RGB（BGR 快照读错）", "  return Math.min(a, b) <= TOL;", "  return a <= TOL;"),
    ]
    with tempfile.TemporaryDirectory(prefix="l2card-sim-") as tmp:
        for name, old, new in mutants:
            if text.count(old) != 1:
                failures.append("sim 变异「%s」原串出现 %d 次（应 1 次）" % (name, text.count(old)))
                continue
            path = os.path.join(tmp, "Ds02L2Ui.test.ets")
            with open(path, "w", encoding="utf-8") as f:
                f.write(text.replace(old, new))
            proc = subprocess.run([tool["node"], SIM, "--suite", path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
            if proc.returncode == 0:
                failures.append("sim 变异「%s」没被打红" % name)
    return failures, 1 + len(mutants)


def self_test():
    failures = []
    with tempfile.TemporaryDirectory(prefix="l2card-selftest-") as tmp:
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
                if text.count(old) != 1:
                    failures.append("变异「%s」的原串出现 %d 次（应 1 次）" % (name, text.count(old)))
                    shutil.rmtree(root)
                    continue
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text.replace(old, new))
            try:
                rules = {v["rule"] for v in check(root)}
            except Incomplete as e:
                rules = {"INCOMPLETE"}
                failures.append("变异「%s」没红在断言（Incomplete：%s）" % (name, e))
            if not any(r == want or r.startswith(want + "-") for r in rules) and "INCOMPLETE" not in rules:
                failures.append("变异「%s」没被 %s 杀（实际 %s）" % (name, want, sorted(rules)))
            shutil.rmtree(root)
        # 语法错误必须 Incomplete（4），不算断言红
        root = os.path.join(tmp, "msyntax")
        copy_good(root)
        with open(os.path.join(root, PRESS), "a", encoding="utf-8") as f:
            f.write("\nexport struct {\n")
        try:
            check(root)
            failures.append("语法错误应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
    logic_failures, logic_total = run_logic_mutants()
    failures += logic_failures
    sim_failures, sim_total = sim_mutants()
    failures += sim_failures
    total = len(MUTATIONS) + 1 + logic_total + sim_total
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("L2CARD_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("L2CARD_SELFTEST 通过（REFERENCE_ONLY）：参照件 0 违反 + 宿主变异 %d 全杀 + 语法错误 fail-closed + run-logic 参照绿 / 变异 3 全红"
          " + 设备角点判定离线合成图原样全对 / 变异 %d 全红" % (len(MUTATIONS), sim_total - 1))
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
        print("L2CARD 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("L2CARD 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    if violations:
        print("L2CARD_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("L2CARD_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
