#!/usr/bin/env python3
"""HM-L2-PRICE-TAG-harmony（书 §3「结构」T1–T4；README 末节编排裁定 D10-1177 ④⑤）：价格 / 返利标签的金额节点与数字过渡宿主守卫。

用法：
    python3 tools/ci/l2price/check_l2_price.py [--root <目录>] [--numeric transition|replace]
    python3 tools/ci/l2price/check_l2_price.py --self-test      # 两种结局的参考实现各自全过 + 每个变异都要被杀（书 T4）

--numeric（README ⑤「先探针」的两种结局，判据由编排按探针结果定，写在 verify.sh 这一步的命令行上；缺省 transition）：
    transition  探针通过：金额拆独立 Text，挂系统 contentTransition，实参来自 CouliMotion.numeric()，减弱动态时为 undefined（直接替换）
    replace     探针不过：直接替换（记 FU、录屏给负责人看）。Price.ets 不出现 contentTransition / NumericTextTransition / CouliMotion.numeric；
                金额节点结构不强求拆（可留 Span）。两种结局都钉「不闪」与「不截断」。

退出码：0 通过；1 有违反（自测：有变异没被杀或正例不过）；2 参数不对；3 解析工具链不可用（复用 lint.hm10_toolchain，node + 鸿蒙 SDK
ohos-typescript）；4 无法保证判定完整（文件缺失、语法错误）。解析错误不算「红在断言」，一律 4。

解析与判定在 tools/ci/l2price/l2price_ast.cjs（AST，不用正则切块；注释与字符串里的字不算）。规则：
    P1（书 T1）PriceTag / RebateTag 的金额承载节点（内容是 content.mainAmount / amountParts / amountText 的 Text / Span）：
       transition：是 Text（不是 Span）且 .contentTransition(x) 恰好一处；静态求值 x：未减弱 = CouliMotion.numeric()、减弱 = undefined，
       条件经 MotionPolicy.numericTransition(CouliMotion.reduced())（P1-transition / P1-reduced / P1-policy / P1-span）；
       replace：Price.ets 无数字过渡（P1-replace）。
       两种都查：build 里金额出现 ≥ 2 处（P1-sites）；金额节点（或装 Span 的外层 Text）不挂 maxLines / textOverflow / minFontSize /
       maxFontScale / heightAdaptivePolicy 等、wordBreak 只许 NORMAL（P1-fit，03 §10.4 不截断、不缩字号、金额本身不拆）；
       if 条件不读金额值、不挂 .transition / .animation（P1-flash，换值不闪）；任何 Span 不挂 contentTransition（P1-span）
    P2（书 T2）Price.ets 无 CouliHaptics / vibrator / SensorServiceKit；无 animateTo / .animation / CouliMotion.run 自写过渡
    P3（书 T3）Price.ets 不读 motion 令牌（D10-838）：无 'motion.*' 字串、不导入令牌、不自定 duration / curve、不用 Curve / curves /
       CouliMotion 的时长曲线
    P5（D10-1177 ④，书外）PriceTag / RebateTag / EstNetLine 不加隐藏类参数、不自做遮罩；PriceModels 的 CardAmountMask.rebate / estNet 原样保留
    P6（D10-638，书 §3 逻辑 2「RANGE 分支无新增入口」的结构部分）RebateTagModel.make 的 RANGE 分支恰好一处；RebateKind.RANGE 只在
       PriceModels（≤ 2 处）；Price.ets 的 rangeBreakable 调用 ≤ 2
    P7（书外接线）designsystem List.test.ets 直接调用 l2PriceTagTest(); 恰好一次
    P8（书外接线，设备套件 Ds02L2Ui l2price_ 段的前提）目录 PriceTag / EstNetLine 样例行不变；RebateTag 既有行 + block × normal；
       目录详情有 this.action('catalog-amount-toggle', ...)，PriceTag 与 RebateTag 页都显示
"""

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
AST_TOOL = os.path.join(HERE, "l2price_ast.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")
REPLACE = os.path.join(HERE, "fixtures", "replace")

PRICE = "common/designsystem/src/main/ets/components/Price.ets"
MODELS = "common/designsystem/src/main/ets/format/PriceModels.ets"
DS_LIST = "common/designsystem/src/test/List.test.ets"
CATALOG = "entry/src/staging/ets/catalog/CatalogManifest.ets"
DETAIL = "entry/src/staging/ets/catalog/CatalogDetail.ets"
REQUIRED = (PRICE, MODELS, DS_LIST, CATALOG, DETAIL)
SKIP_DIRS = {"build", "oh_modules", "node_modules", ".hvigor", ".test", ".preview"}
RULE_TITLES = {
    "P1": "金额承载节点与数字过渡（README ⑤）、不截断、不闪",
    "P2": "Price.ets 无触感、无自写过渡",
    "P3": "Price.ets 不读 motion 令牌（D10-838）",
    "P5": "不做金额隐藏变体，CardAmountMask 留作防御（D10-1177 ④）",
    "P6": "RANGE 只兼容保留、无新增入口（D10-638）",
    "P7": "L2PriceTag 逻辑套件已登记",
    "P8": "目录样例行与「切换金额」动作",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_l2price", os.path.join(HERE, "..", "lint.py"))
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


def range_files(root):
    """产品源码（entry/src/main、entry/src/staging、features/*/src/main、common/*/src/main）里含 RebateKind 的 .ets，交 AST 判 P6。"""
    out = {}
    bases = [os.path.join(root, "entry", "src", "main"), os.path.join(root, "entry", "src", "staging")]
    for group in ("features", "common"):
        top = os.path.join(root, group)
        if os.path.isdir(top):
            bases += [os.path.join(top, d, "src", "main") for d in sorted(os.listdir(top))]
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
                    raise Incomplete("%s: 读不出（%s），RebateKind 扫描无法保证完整" % (rel, e))
                if "RebateKind" in text:
                    out[rel] = text
    return out


def check(root, numeric):
    """返回违反列表；文件缺失 / 语法错误抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
    tool = lint.hm10_toolchain()
    scan = range_files(root)
    files = dict(scan)
    for rel in REQUIRED:
        text = read(root, rel)
        if text is None:
            raise Incomplete("%s: 文件不存在，无法判定" % rel)
        files[rel] = text
    payload = json.dumps({"files": files, "rangeScan": sorted(scan), "numeric": numeric}, ensure_ascii=False).encode("utf-8")
    try:
        proc = subprocess.run([tool["node"], AST_TOOL, tool["typescript"]], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise lint.HM10ToolchainError("运行 node 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("l2price_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("l2price_ast.cjs 输出无法解析：%s" % e)
    if out["incomplete"]:
        raise Incomplete("；".join(out["incomplete"]))
    return out["violations"]


def render(violations, numeric):
    groups = {}
    for v in violations:
        groups.setdefault(v["rule"].split("-")[0], []).append(v)
    print("数字过渡结局：%s（README ⑤；--numeric）" % numeric)
    for key in sorted(RULE_TITLES):
        state = "红" if key in groups else "绿"
        print("%s %s：%s（%d 处）" % (key, state, RULE_TITLES[key], len(groups.get(key, []))))
    for v in sorted(violations, key=lambda x: (x["rule"], x["file"], x["line"])):
        print("  [%s] %s:%d %s" % (v["rule"], v["file"], v["line"], v["msg"]))


# ---------------------------------------------------------------- 自测（书 T4）：两种结局的参考实现与变异
# 参考实现：fixtures/good = transition 结局（书 §2.1 写法）；fixtures/replace 只放 Price.ets（= 基线 0b5adaa 的 Price.ets，金额仍在 Span、
# 直接替换），其余文件取 fixtures/good。
POLICY_OK = "MotionPolicy.numericTransition(CouliMotion.reduced()) ? CouliMotion.numeric() : undefined"
# （名字，结局，文件，原串，新串，应报的规则前缀）；原串在该结局的参考实现里必须唯一
MUTATIONS = [
    # 书 T4 点名的三个
    ("去 transition：PriceTag 金额不挂 contentTransition（书 T4）", "transition", PRICE,
     "        .wordBreak(WordBreak.NORMAL)\n        .contentTransition(amountTransition())\n", "        .wordBreak(WordBreak.NORMAL)\n", "P1-transition"),
    ("去 transition：RebateTag 金额不挂", "transition", PRICE,
     "      .wordBreak(WordBreak.NORMAL)\n      .contentTransition(amountTransition())\n  }", "      .wordBreak(WordBreak.NORMAL)\n  }", "P1-transition"),
    ("去减弱判断：一律 CouliMotion.numeric()（书 T4）", "transition", PRICE, POLICY_OK, "CouliMotion.numeric()", "P1-reduced"),
    ("transition 写到 Span 上（书 T4）", "transition", PRICE,
     "      Text(this.content.mainAmount)\n        .fontSize(this.amountStyle().fontSize)",
     "      Span(this.content.mainAmount)\n        .fontSize(this.amountStyle().fontSize)", "P1-span"),
    # 过渡实参
    ("减弱判断写反", "transition", PRICE, POLICY_OK,
     "MotionPolicy.numericTransition(CouliMotion.reduced()) ? undefined : CouliMotion.numeric()", "P1-transition"),
    ("减弱判断写死 false", "transition", PRICE, POLICY_OK, "MotionPolicy.numericTransition(false) ? CouliMotion.numeric() : undefined", "P1-reduced"),
    ("绕开 MotionPolicy 直接读 reduced", "transition", PRICE, POLICY_OK, "CouliMotion.reduced() ? undefined : CouliMotion.numeric()", "P1-policy"),
    ("组件里另 new NumericTextTransition", "transition", PRICE, POLICY_OK,
     "MotionPolicy.numericTransition(CouliMotion.reduced()) ? new NumericTextTransition() : undefined", "P1-transition"),
    ("实参无法判定（读外部变量）", "transition", PRICE, "    .contentTransition(amountTransition())\n  }",
     "    .contentTransition(globalTransition)\n  }", "P1-transition"),
    ("挂两次 contentTransition", "transition", PRICE, "        .contentTransition(amountTransition())\n",
     "        .contentTransition(amountTransition())\n        .contentTransition(CouliMotion.numeric())\n", "P1-transition"),
    ("RebateTag 列表行金额改回 Span", "transition", PRICE,
     "            if (this.content.hasAmount) {\n              this.amountText()\n            }",
     "            if (this.content.hasAmount) {\n              Span(rangeBreakable(this.content.amountParts))\n            }", "P1-span"),
    # 不截断 / 不拆 / 不闪 / 金额位置
    ("金额 maxLines(1)", "transition", PRICE, "        .fontFeature(TABULAR_FEATURE)\n        .wordBreak(WordBreak.NORMAL)\n        .contentTransition",
     "        .fontFeature(TABULAR_FEATURE)\n        .maxLines(1)\n        .wordBreak(WordBreak.NORMAL)\n        .contentTransition", "P1-fit"),
    ("金额 textOverflow 省略", "transition", PRICE, "      .wordBreak(WordBreak.NORMAL)\n      .contentTransition(amountTransition())\n  }",
     "      .wordBreak(WordBreak.NORMAL)\n      .textOverflow({ overflow: TextOverflow.Ellipsis })\n      .contentTransition(amountTransition())\n  }", "P1-fit"),
    ("金额 minFontSize 缩字号", "transition", PRICE, "        .fontWeight(CouliFontWeight.bold)\n        .fontFeature",
     "        .fontWeight(CouliFontWeight.bold)\n        .minFontSize(10)\n        .fontFeature", "P1-fit"),
    ("金额 BREAK_ALL 拆数字", "transition", PRICE, "        .wordBreak(WordBreak.NORMAL)\n        .contentTransition",
     "        .wordBreak(WordBreak.BREAK_ALL)\n        .contentTransition", "P1-fit"),
    ("金额按值 if 重建（闪）", "transition", PRICE, "      Text(this.content.mainAmount)\n",
     "      if (this.content.mainAmount.length > 0)\n      Text(this.content.mainAmount)\n", "P1-flash"),
    ("金额加 transition 淡入", "transition", PRICE, "        .contentTransition(amountTransition())\n",
     "        .contentTransition(amountTransition())\n        .transition(TransitionEffect.OPACITY)\n", "P1-flash"),
    ("PriceTag 预售行丢金额", "transition", PRICE, "          CouliChip({ label: this.content.presaleLabel })\n          this.mainText()",
     "          CouliChip({ label: this.content.presaleLabel })", "P1-sites"),
    ("RebateTag 列表行丢金额", "transition", PRICE, "            if (this.content.hasAmount) {\n              this.amountText()\n            }\n", "", "P1-sites"),
    # 触感 / 自写过渡 / 令牌（书 T2 / T3）
    ("加触感", "transition", PRICE, "import { CouliIcon } from './CouliIcon';",
     "import { CouliIcon } from './CouliIcon';\nimport { CouliHaptics } from './CouliHaptics';", "P2-haptics"),
    ("引入振动器", "transition", PRICE, "import { CouliIcon } from './CouliIcon';",
     "import { CouliIcon } from './CouliIcon';\nimport { vibrator } from '@kit.SensorServiceKit';", "P2-haptics"),
    ("自写 animateTo", "transition", PRICE, "    .accessibilityText(PriceTagModel.spoken(this.content, this.showSub, this.presale))\n  }",
     "    .accessibilityText(PriceTagModel.spoken(this.content, this.showSub, this.presale))\n  }\n\n"
     "  bump(): void {\n    this.getUIContext().animateTo({}, () => {});\n  }", "P2-anim"),
    ("用 CouliMotion.run", "transition", PRICE, "    .accessibilityText(PriceTagModel.spoken(this.content, this.showSub, this.presale))\n  }",
     "    .accessibilityText(PriceTagModel.spoken(this.content, this.showSub, this.presale))\n  }\n\n"
     "  bump(): void {\n    CouliMotion.run(this.getUIContext(), 150, () => {});\n  }", "P2-anim"),
    ("隐式 .animation", "transition", PRICE, "        .contentTransition(amountTransition())\n",
     "        .contentTransition(amountTransition())\n        .animation({ curve: Curve.Friction })\n", "P2-anim"),
    ("读 motion 令牌字串", "transition", PRICE, "export enum PriceTagSize {",
     "const PRICE_FLIP: string = 'motion.duration.fast';\n\nexport enum PriceTagSize {", "P3-token"),
    ("导入令牌", "transition", PRICE, "import { CouliIcon } from './CouliIcon';",
     "import { CouliIcon } from './CouliIcon';\nimport { CouliThemeTokens } from '../theme/CouliThemeTokens';", "P3-token"),
    ("自选时长", "transition", PRICE, "        .contentTransition(amountTransition())\n",
     "        .contentTransition(amountTransition())\n        .opacity(CouliMotion.durationMicro > 0 ? 1 : 1)\n", "P3-token"),
    # D10-1177 ④
    ("PriceTag 加 amountHidden 变体", "transition", PRICE, "  @Param presale: PresaleDisplay = PresaleDisplay.INLINE;",
     "  @Param presale: PresaleDisplay = PresaleDisplay.INLINE;\n  @Param amountHidden: boolean = false;", "P5-variant"),
    ("RebateTag 自做遮罩", "transition", PRICE, "    return this.content.hasAmount ? PriceTerms.rebate : this.content.text;",
     "    return this.content.hasAmount ? PriceTerms.rebate + PriceTerms.amountMask : this.content.text;", "P5-variant"),
    ("删 CardAmountMask.estNet", "transition", MODELS, "  static estNet(text: string | null, amountHidden: boolean): string | null {\n    return amountHidden ? null : text;\n  }\n",
     "", "P5-keep"),
    # D10-638
    ("删 RANGE 分支", "transition", MODELS, "    return new RebateTagContent(RebateKind.RANGE, PriceTerms.rebate + ' ' + amount, amount, parts, spoken);",
     "    return new RebateTagContent(RebateKind.AMOUNT, PriceTerms.rebate + ' ' + amount, amount, parts, spoken);", "P6-make"),
    ("组件新增 RANGE 入口", "transition", PRICE, "  private neutral(): boolean {\n    return this.content.kind === RebateKind.NONE;",
     "  private neutral(): boolean {\n    return this.content.kind === RebateKind.NONE || this.content.kind === RebateKind.RANGE;", "P6-range"),
    ("新增 rangeBreakable 调用", "transition", PRICE, "  private label(): string {\n    return this.content.hasAmount ? PriceTerms.rebate : this.content.text;",
     "  private label(): string {\n    return this.content.hasAmount ? rangeBreakable([PriceTerms.rebate]) : this.content.text;", "P6-range"),
    # 登记 / 目录
    ("逻辑套件没登记", "transition", DS_LIST, "  l2PriceTagTest();\n", "", "P7-register"),
    ("登记只在注释里", "transition", DS_LIST, "  l2PriceTagTest();\n", "  // l2PriceTagTest();\n", "P7-register"),
    ("目录缺 block × normal", "transition", CATALOG, ", m(['block'], ['normal'])]),", "]),", "P8-catalog"),
    ("目录删 amount-hidden（④ 防御态）", "transition", CATALOG, "  c('EstNetLine', GROUP_BUSINESS, KIND_L2, '「预估返后」一行。', [m(['default'], ['normal', 'amount-hidden'])]),",
     "  c('EstNetLine', GROUP_BUSINESS, KIND_L2, '「预估返后」一行。', [m(['default'], ['normal'])]),", "P8-catalog"),
    ("目录新增区间样例", "transition", CATALOG, ", m(['block'], ['normal'])]),", ", m(['block'], ['normal']), m(['range'], ['block'])]),", "P8-catalog"),
    ("目录缺切换金额", "transition", DETAIL, "this.action('catalog-amount-toggle', '切换金额'", "this.action('catalog-amount-switch', '切换金额'", "P8-toggle"),
    ("切换金额只在 PriceTag 页", "transition", DETAIL, "if (this.component === 'PriceTag' || this.component === 'RebateTag') {",
     "if (this.component === 'PriceTag') {", "P8-toggle"),
    # replace 结局（探针不过）：直接替换，不得出现数字过渡；照样钉不闪 / 不截断
    ("replace 结局里仍挂 contentTransition（Text）", "replace", PRICE, "    Text(rangeBreakable(this.content.amountParts))\n      .fontSize(this.amountStyle().fontSize)",
     "    Text(rangeBreakable(this.content.amountParts))\n      .contentTransition(undefined)\n      .fontSize(this.amountStyle().fontSize)", "P1-replace"),
    ("replace 结局里引 CouliMotion.numeric", "replace", PRICE, "  private neutral(): boolean {\n    return this.content.kind === RebateKind.NONE;\n  }",
     "  private neutral(): boolean {\n    return this.content.kind === RebateKind.NONE;\n  }\n\n  private t(): ContentTransition {\n    return CouliMotion.numeric();\n  }", "P1-replace"),
    ("replace 结局 Span 上挂 contentTransition", "replace", PRICE,
     "      Span(this.content.mainAmount)\n        .fontSize(this.amountStyle().fontSize)",
     "      Span(this.content.mainAmount)\n        .contentTransition(undefined)\n        .fontSize(this.amountStyle().fontSize)", "P1-span"),
    ("replace 结局 外层 Text maxLines（截断）", "replace", PRICE, "    .lineHeight(this.amountStyle().lineHeight)\n    .fontFeature(TABULAR_FEATURE)\n    // 口径词",
     "    .lineHeight(this.amountStyle().lineHeight)\n    .maxLines(1)\n    .fontFeature(TABULAR_FEATURE)\n    // 口径词", "P1-fit"),
    ("replace 结局 金额按值 if 重建（闪）", "replace", PRICE, "            if (this.content.hasAmount) {\n              Span(rangeBreakable(this.content.amountParts))",
     "            if (this.content.amountParts.length > 0) {\n              Span(rangeBreakable(this.content.amountParts))", "P1-flash"),
    ("replace 结局 列表行丢金额", "replace", PRICE,
     "            if (this.content.hasAmount) {\n              Span(rangeBreakable(this.content.amountParts))\n                .fontSize(this.amountStyle().fontSize)\n"
     "                .fontColor(this.fg())\n                .fontWeight(this.tagSize === RebateTagSize.LARGE ? CouliFontWeight.bold : CouliFontWeight.semibold)\n            }\n",
     "", "P1-sites"),
    ("replace 结局 加 animateTo", "replace", PRICE, "    .accessibilityText(PriceTagModel.spoken(this.content, this.showSub, this.presale))\n  }",
     "    .accessibilityText(PriceTagModel.spoken(this.content, this.showSub, this.presale))\n  }\n\n"
     "  bump(): void {\n    this.getUIContext().animateTo({}, () => {});\n  }", "P2-anim"),
]

# 良性改写（重构但判据不变），必须仍然全绿——防判据收紧过头。（名字，结局，[(文件，原串，新串)…]）
BENIGN = [
    ("过渡条件写成 if / return 的方法", "transition", [
        (PRICE, "function amountTransition(): ContentTransition | undefined {\n  return " + POLICY_OK + ";\n}",
         "function amountTransition(): ContentTransition | undefined {\n  const reduced: boolean = CouliMotion.reduced();\n"
         "  if (!MotionPolicy.numericTransition(reduced)) {\n    return undefined;\n  }\n  return CouliMotion.numeric();\n}"),
    ]),
    ("过渡实参直接写三元", "transition", [
        (PRICE, "        .contentTransition(amountTransition())\n", "        .contentTransition(" + POLICY_OK + ")\n"),
    ]),
    ("replace 结局：基线 Price.ets 原样", "replace", []),
]


def build_tree(tmp, name, numeric):
    root = os.path.join(tmp, name)
    shutil.copytree(GOOD, root)
    if numeric == "replace":
        shutil.copyfile(os.path.join(REPLACE, PRICE), os.path.join(root, PRICE))
    return root


def apply_edit(root, rel, old, new):
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.count(old) != 1:
        return text.count(old)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(old, new))
    return 1


def self_test():
    failures = []
    with tempfile.TemporaryDirectory(prefix="l2price-selftest-") as tmp:
        for numeric in ("transition", "replace"):
            got = check(build_tree(tmp, "good-" + numeric, numeric), numeric)
            if got:
                failures.append("参考实现（%s）不过：%s" % (numeric, [(v["rule"], v["file"], v["line"], v["msg"]) for v in got]))
        # 交叉：两种结局的判据互不放过
        crossed = {v["rule"] for v in check(build_tree(tmp, "cross-a", "transition"), "replace")}
        if "P1-replace" not in crossed:
            failures.append("transition 参考实现按 replace 判没报 P1-replace（实际 %s）" % sorted(crossed))
        crossed = {v["rule"] for v in check(build_tree(tmp, "cross-b", "replace"), "transition")}
        if "P1-span" not in crossed:
            failures.append("replace 参考实现（金额在 Span）按 transition 判没报 P1-span（实际 %s）" % sorted(crossed))
        for idx, (name, numeric, rel, old, new, want) in enumerate(MUTATIONS):
            root = build_tree(tmp, "m%02d" % idx, numeric)
            count = apply_edit(root, rel, old, new)
            if count != 1:
                failures.append("变异「%s」的原串出现 %d 次（应 1 次）" % (name, count))
                continue
            try:
                rules = {v["rule"] for v in check(root, numeric)}
            except Incomplete as e:
                failures.append("变异「%s」解析不完整（变异写坏了，不算杀）：%s" % (name, e))
                continue
            if not any(r == want or r.startswith(want + "-") for r in rules):
                failures.append("变异「%s」没被 %s 杀（实际 %s）" % (name, want, sorted(rules)))
            shutil.rmtree(root)
        for idx, (name, numeric, edits) in enumerate(BENIGN):
            root = build_tree(tmp, "b%02d" % idx, numeric)
            for rel, old, new in edits:
                count = apply_edit(root, rel, old, new)
                if count != 1:
                    failures.append("良性改写「%s」的原串出现 %d 次（应 1 次）" % (name, count))
            got = check(root, numeric)
            if got:
                failures.append("良性改写「%s」被误报：%s" % (name, [(v["rule"], v["msg"]) for v in got]))
            shutil.rmtree(root)
        # 语法错误、必查文件缺失都必须 4（Incomplete），不算断言红
        root = build_tree(tmp, "msyntax", "transition")
        with open(os.path.join(root, PRICE), "a", encoding="utf-8") as f:
            f.write("\nexport struct {\n")
        try:
            check(root, "transition")
            failures.append("语法错误应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
        root = build_tree(tmp, "mmissing", "transition")
        os.remove(os.path.join(root, DETAIL))
        try:
            check(root, "transition")
            failures.append("缺文件应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
    total = 2 + 2 + len(MUTATIONS) + len(BENIGN) + 2
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("L2PRICE_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("L2PRICE_SELFTEST 通过：参考实现 2（transition / replace）+ 交叉 2 + 变异 %d 全杀 + 良性改写 %d 全绿 + 语法错误 / 缺文件 fail-closed"
          % (len(MUTATIONS), len(BENIGN)))
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", default=REPO_ROOT)
    ap.add_argument("--numeric", choices=("transition", "replace"), default="transition")
    ap.add_argument("--self-test", action="store_true")
    try:
        args = ap.parse_args()
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        if args.self_test:
            return self_test()
        violations = check(os.path.abspath(args.root), args.numeric)
    except lint.HM10ToolchainError as e:
        print("L2PRICE 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("L2PRICE 无法保证判定完整：%s" % e)
        return 4
    render(violations, args.numeric)
    if violations:
        print("L2PRICE_HOST 失败：%d 处违反（--numeric %s）" % (len(violations), args.numeric))
        return 1
    print("L2PRICE_HOST 通过（--numeric %s）" % args.numeric)
    return 0


if __name__ == "__main__":
    sys.exit(main())
