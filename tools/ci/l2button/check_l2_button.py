#!/usr/bin/env python3
"""HM-L2-BUTTON-harmony（书 §3「结构」B1–B7；README 末节编排裁定 D10-1177）：按钮走系统 Button + buttonStyle / controlSize 的宿主守卫。

用法：
    python3 tools/ci/l2button/check_l2_button.py [--root <目录>]    # 检查（默认仓库根）
    python3 tools/ci/l2button/check_l2_button.py --self-test        # 参考实现（fixtures/good）全过 + 每个变异都要被杀（书 B7）

退出码：0 通过；1 有违反（自测：有变异没被杀或正例不过）；2 参数不对；3 解析工具链不可用（复用 lint.hm10_toolchain，node + 鸿蒙 SDK
ohos-typescript）；4 无法保证判定完整（文件缺失、语法错误）。解析错误不算「红在断言」，一律 4。

解析与判定在 tools/ci/l2button/l2button_ast.cjs（AST，不用正则切块；注释与字符串里的字不算）。规则编号对应书 §3「结构」：
    B1 CouliButton.build 根节点是系统 Button(ButtonType.Normal)，链上 buttonStyle / controlSize / enabled 各一处、stateEffect 不写死 false；
       buttonStyle：PRIMARY / ON_BRAND → EMPHASIZED、SECONDARY → NORMAL、TEXT → TEXTUAL；controlSize：COMPACT → SMALL、REGULAR → NORMAL
       （静态求值实参）；enabled 与 onClick 再判都看加载与禁用（加载防连点）；不得有 Row / Column + onClick 自画
    B2 features/*/src/main、entry/src/main 不传 pressedPreview；CouliButton / CouliIconButton 的 pressedPreview 注释写「目录专用」
    B3 Basics.ets 的 CouliButton 颜色只来自 CouliColors / Color.Transparent（同 ds02/test_host.py test_component_colors_have_no_literals 口径，
       另核各颜色入口的实参）
    B4 BuyButton 内是 CouliButton、label() 改调 BuyButtonModel.stateLabel；Price.ets、Basics.ets、CouliIconButton 无触感调用
    B5 ProductCardMapper 下架分支赋 BuyButtonState.DISABLED + error.30141、无 RETRY_LATER、之后不再改状态；ProductCard 的 retryText 实参是
       this.data.retryText
    B4-a11y / B4-hidden / B5-hidden / B5-mask（测试 v3，评审 r1 S3-1：组件层隐私接线，真实树变异 M1 / M2 / M5 / M6 原先三层都放过）
       BuyButton.spoken() 只返回 this.label()（非 NORMAL）或 BuyButtonModel.spoken(this.base, this.rebate, this.amountHidden, this.context)；
       CouliButton 的 accessibilityName 是 this.spoken()，build 不另挂 accessibilityText / accessibilityDescription；label() 的 stateLabel 实参原样透传；
       ProductCard 给 BuyButton 的 rebate 是未遮罩的 this.data.rebate（卡内 this.rebate() 是 CardAmountMask 遮罩后的，不行）、amountHidden 是
       this.data.amountHidden（允许经无参 this.m() / 唯一局部常量转一手，最终必须就是它）；产品源码（features/*/src/main、entry/src/main、
       common/*/src/main）任何 BuyButton 调用点的 rebate 都不得经 CardAmountMask 遮罩
    B6 BuyButtonModel 回落走 contractText('btn.buy')（不引用 PriceTerms.buy），回落方法看 amountHidden，text / spoken / stateLabel 都走到回落
    B8（书外接线）designsystem List.test.ets 直接调用 l2ButtonTest(); 恰好一次并有对应 import
    B9（书外接线，设备套件 Ds02L2Ui 的前提）目录 BuyButton 有 single × off-shelf；目录详情有点按计数 catalog-events/CouliButton、
       catalog-events/BuyButton（同 catalog-events/OAuthButton 写法）
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
AST_TOOL = os.path.join(HERE, "l2button_ast.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")

BASICS = "common/designsystem/src/main/ets/components/Basics.ets"
CONTROLS = "common/designsystem/src/main/ets/components/Controls.ets"
PRICE = "common/designsystem/src/main/ets/components/Price.ets"
CARD = "common/designsystem/src/main/ets/components/ProductCard.ets"
MODELS = "common/designsystem/src/main/ets/format/PriceModels.ets"
MAPPER = "common/designsystem/src/main/ets/format/ProductCardMapper.ets"
DS_LIST = "common/designsystem/src/test/List.test.ets"
CATALOG = "entry/src/staging/ets/catalog/CatalogManifest.ets"
DETAIL = "entry/src/staging/ets/catalog/CatalogDetail.ets"
REQUIRED = (BASICS, CONTROLS, PRICE, CARD, MODELS, MAPPER, DS_LIST, CATALOG, DETAIL)
SKIP_DIRS = {"build", "oh_modules", "node_modules", ".hvigor", ".test", ".preview"}
RULE_TITLES = {
    "B1": "CouliButton 是系统 Button + buttonStyle / controlSize / stateEffect / 防连点",
    "B2": "页面不传 pressedPreview；注释「目录专用」",
    "B3": "CouliButton 颜色只来自 CouliColors / Color.Transparent",
    "B4": "BuyButton 包 CouliButton、label 走 stateLabel、读屏名称不绕开回落；按钮无触感",
    "B5": "下架 = DISABLED + 下架文案；ProductCard 透传 retryText、未遮罩返利与 amountHidden；BuyButton 不吃遮罩返利",
    "B6": "D10-871 回落走字典 btn.buy",
    "B8": "L2Button 逻辑套件已登记",
    "B9": "目录 off-shelf 态与点按计数",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_l2button", os.path.join(HERE, "..", "lint.py"))
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


def page_files(root):
    """features/*/src/main 与 entry/src/main 下全部 .ets（含 pressedPreview 子串的才交给 AST 判）。"""
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
                if "pressedPreview" in text:
                    out[rel] = text
    return out


def buy_files(root):
    """测试 v3（评审 r1 S3-1）：产品源码（features/*/src/main、entry/src/main、common/*/src/main）里含 BuyButton 的 .ets，交 AST 判 B5-mask。"""
    out = {}
    bases = [os.path.join(root, "entry", "src", "main")]
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
                    raise Incomplete("%s: 读不出（%s），BuyButton 调用点扫描无法保证完整" % (rel, e))
                if "BuyButton" in text:
                    out[rel] = text
    return out


def check(root):
    """返回违反列表；文件缺失 / 语法错误抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
    tool = lint.hm10_toolchain()
    scan = page_files(root)
    buys = buy_files(root)
    files = dict(scan)
    files.update(buys)
    for rel in REQUIRED:
        text = read(root, rel)
        if text is None:
            raise Incomplete("%s: 文件不存在，无法判定" % rel)
        files[rel] = text
    payload = json.dumps({"files": files, "scan": sorted(scan), "buyScan": sorted(buys)}, ensure_ascii=False).encode("utf-8")
    try:
        proc = subprocess.run([tool["node"], AST_TOOL, tool["typescript"]], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise lint.HM10ToolchainError("运行 node 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("l2button_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("l2button_ast.cjs 输出无法解析：%s" % e)
    if out["incomplete"]:
        raise Incomplete("；".join(out["incomplete"]))
    return out["violations"]


def render(violations):
    groups = {}
    for v in violations:
        groups.setdefault(v["rule"].split("-")[0], []).append(v)
    for key in sorted(RULE_TITLES):
        state = "红" if key in groups else "绿"
        print("%s %s：%s（%d 处）" % (key, state, RULE_TITLES[key], len(groups.get(key, []))))
    for v in sorted(violations, key=lambda x: (x["rule"], x["file"], x["line"])):
        print("  [%s] %s:%d %s" % (v["rule"], v["file"], v["line"], v["msg"]))


# ---------------------------------------------------------------- 自测（书 B7）：参考实现的变异，全部要杀
PAGE = "features/demo/src/main/ets/pages/DemoPage.ets"
ENTRY_PAGE = "entry/src/main/ets/pages/DemoEntry.ets"
BUY_PAGE = "features/demo/src/main/ets/pages/DemoBuyPage.ets"
# （名字，文件，原串，新串，应报的规则前缀）；原串在参考实现里必须唯一
MUTATIONS = [
    # B1
    ("去 buttonStyle（书 B7）", BASICS, "    .buttonStyle(styleMode(this.variant))\n", "", "B1-chain"),
    ("去 controlSize", BASICS, "    .controlSize(sizeOf(this.buttonSize))\n", "", "B1-chain"),
    ("buttonStyle 写死强调", BASICS, ".buttonStyle(styleMode(this.variant))", ".buttonStyle(ButtonStyleMode.EMPHASIZED)", "B1-style"),
    ("次按钮映射成强调", BASICS, "    case CouliButtonVariant.SECONDARY:\n      return ButtonStyleMode.NORMAL;",
     "    case CouliButtonVariant.SECONDARY:\n      return ButtonStyleMode.EMPHASIZED;", "B1-style"),
    ("文字按钮映射成普通", BASICS, "      return ButtonStyleMode.TEXTUAL;", "      return ButtonStyleMode.NORMAL;", "B1-style"),
    ("实底卡内白底映射成普通", BASICS, "    case CouliButtonVariant.TEXT:\n      return ButtonStyleMode.TEXTUAL;\n",
     "    case CouliButtonVariant.TEXT:\n      return ButtonStyleMode.TEXTUAL;\n    case CouliButtonVariant.ON_BRAND:\n      return ButtonStyleMode.NORMAL;\n", "B1-style"),
    ("buttonStyle 实参无法判定", BASICS, ".buttonStyle(styleMode(this.variant))", ".buttonStyle(this.someStyle)", "B1-style"),
    ("紧凑与常规尺寸写反", BASICS, "? ControlSize.SMALL : ControlSize.NORMAL", "? ControlSize.NORMAL : ControlSize.SMALL", "B1-size"),
    ("controlSize 写死", BASICS, ".controlSize(sizeOf(this.buttonSize))", ".controlSize(ControlSize.NORMAL)", "B1-size"),
    ("stateEffect 写死 false", BASICS, "stateEffect: !this.inactive()", "stateEffect: false", "B1-effect"),
    ("去 stateEffect", BASICS, "Button({ type: ButtonType.Normal, stateEffect: !this.inactive() })", "Button({ type: ButtonType.Normal })", "B1-effect"),
    ("enabled 写死 true", BASICS, ".enabled(!this.inactive())", ".enabled(true)", "B1-enabled"),
    ("enabled 只看禁用（加载可点）", BASICS, ".enabled(!this.inactive())", ".enabled(!this.disabled)", "B1-enabled"),
    ("去 enabled", BASICS, "    .enabled(!this.inactive())\n", "", "B1-chain"),
    ("onClick 去掉再判", BASICS, "      if (!this.inactive()) {\n        this.onTap();\n      }", "      this.onTap();", "B1-guard"),
    ("onClick 只判禁用", BASICS, "      if (!this.inactive()) {\n        this.onTap();\n      }", "      if (!this.disabled) {\n        this.onTap();\n      }", "B1-guard"),
    ("根节点换 Row + onClick 自画", BASICS, "    Button({ type: ButtonType.Normal, stateEffect: !this.inactive() }) {\n      Row({ space: CouliComponentMetrics.buttonGap }) {",
     "    Row() {\n      Row({ space: CouliComponentMetrics.buttonGap }) {", "B1-root"),
    ("Button 外再包 Column", BASICS, "  build() {\n    Button({", "  build() {\n    Column() {\n    }\n    Button({", "B1-root"),
    ("内层 Row 挂 onClick", BASICS, "      .justifyContent(FlexAlign.Center)\n", "      .justifyContent(FlexAlign.Center)\n      .onClick(() => {\n        this.onTap();\n      })\n", "B1-redraw"),
    ("Button 类型换 Capsule", BASICS, "Button({ type: ButtonType.Normal,", "Button({ type: ButtonType.Capsule,", "B1-root"),
    # B2
    ("业务页传 pressedPreview", PAGE, "variant: CouliButtonVariant.SECONDARY, onTap:", "variant: CouliButtonVariant.SECONDARY, pressedPreview: true, onTap:", "B2-page"),
    ("entry 页传 pressedPreview", ENTRY_PAGE, "CouliButton({ text: '去看看', fullWidth: true })", "CouliButton({ text: '去看看', fullWidth: true, pressedPreview: false })", "B2-page"),
    ("CouliButton 注释没改", BASICS, "目录专用，业务不得传：目录页静态展示", "目录页静态展示", "B2-doc"),
    ("CouliIconButton 注释没改", CONTROLS, "  /** 目录专用，业务不得传：目录页静态展示「按下」底色。 */\n", "", "B2-doc"),
    # B3
    ("禁用底写死色值", BASICS, "return CouliColors.buttonPrimaryDisabledBackground;", "return '#E9E2D9';", "B3"),
    ("字色用命名色", BASICS, "return CouliColors.buttonPrimaryDefaultText;", "return Color.White;", "B3"),
    ("描边用资源", BASICS, "color: CouliColors.borderControl }", "color: $r('sys.color.ohos_id_color_component_normal') }", "B3"),
    ("底色实参用外部函数", BASICS, ".backgroundColor(this.bgColor())", ".backgroundColor(themeColor(this.variant))", "B3-sink"),
    ("转圈色用数值", BASICS, ".color(this.foreground())", ".color(0xFFFFFFFF)", "B3"),
    # B4
    ("BuyButton 自画 Button", PRICE, "  build() {\n    CouliButton({\n      text: this.label(),",
     "  build() {\n    Button(this.label())\n    CouliButton({\n      text: this.label(),", "B4-buy"),
    ("BuyButton.label 不走 stateLabel", PRICE, "return BuyButtonModel.stateLabel(this.state, this.base, this.retryText, this.rebate, this.amountHidden, this.context);",
     "return BuyButtonModel.text(this.base, this.rebate, this.amountHidden, this.context);", "B4-label"),
    ("BuyButton 加触感", PRICE, "      onTap: () => {\n        this.onTap();", "      onTap: () => {\n        CouliHaptics.emit(1);\n        this.onTap();", "B4-haptics"),
    ("CouliButton 加触感", BASICS, "      if (!this.inactive()) {\n        this.onTap();", "      if (!this.inactive()) {\n        CouliHaptics.emit(1);\n        this.onTap();", "B4-haptics"),
    ("Basics 引入振动器", BASICS, "import { CouliIcon } from './CouliIcon';", "import { CouliIcon } from './CouliIcon';\nimport { vibrator } from '@kit.SensorServiceKit';", "B4-haptics"),
    # B5
    ("下架留 RETRY_LATER（书 B7）", MAPPER, "      d.buyState = BuyButtonState.DISABLED;\n      d.retryText = texts.text(ProductCardKeys.OFF_SHELF);",
     "      d.buyState = BuyButtonState.RETRY_LATER;\n      d.retryText = texts.text(ProductCardKeys.OFF_SHELF);", "B5-mapper"),
    ("下架不给下架文案", MAPPER, "      d.retryText = texts.text(ProductCardKeys.OFF_SHELF);", "      d.retryText = '';", "B5-mapper"),
    ("下架盖过价格不可用", MAPPER, "if (!d.priceUnavailable && card['availability'] === ProductCardMapper.OFF_SHELF) {",
     "if (card['availability'] === ProductCardMapper.OFF_SHELF) {", "B5-mapper"),
    ("下架后平台状态再改按钮", MAPPER, "    if (purchaseStatus === ProductCardMapper.PURCHASE_NOT_LAUNCHED) {\n      // 共性第 31 条",
     "    if (purchaseStatus === ProductCardMapper.PURCHASE_NOT_LAUNCHED) {\n      d.buyState = BuyButtonState.RETRY_LATER;\n      // 共性第 31 条", "B5-mapper"),
    (":369 留兜底（书 B7）", CARD, "retryText: this.data.retryText,", "retryText: BuyButtonModel.retryText(this.data.retryText),", "B5-card"),
    # 测试 v3（评审 r1 S3-1）：组件层隐私接线。前 4 条就是评审在真实树上做、原先放过的 M1 / M2 / M5 / M6。
    ("评审 M1：spoken 非 NORMAL 读 this.base", PRICE, "    if (this.state !== BuyButtonState.NORMAL) {\n      return this.label();",
     "    if (this.state !== BuyButtonState.NORMAL) {\n      return this.base;", "B4-a11y"),
    ("评审 M2：accessibilityName 用 base", PRICE, "      accessibilityName: this.spoken(),", "      accessibilityName: this.base,", "B4-a11y"),
    ("评审 M5：卡片传 CardAmountMask 遮罩后的返利", CARD, "      base: this.data.buyBase,\n      rebate: this.data.rebate,",
     "      base: this.data.buyBase,\n      rebate: CardAmountMask.rebate(this.data.rebate, this.data.amountHidden),", "B5-hidden"),
    ("评审 M6：卡片 amountHidden 写死 false", CARD, "      amountHidden: this.data.amountHidden,\n      context: this.context(),",
     "      amountHidden: false,\n      context: this.context(),", "B5-hidden"),
    ("PRODUCT-CELL 坑：卡片改传卡内 this.rebate()", CARD, "      base: this.data.buyBase,\n      rebate: this.data.rebate,",
     "      base: this.data.buyBase,\n      rebate: this.rebate(),", "B5-hidden"),
    ("卡片不传 amountHidden", CARD, "      amountHidden: this.data.amountHidden,\n      context: this.context(),", "      context: this.context(),", "B5-hidden"),
    ("卡片 amountHidden 取反", CARD, "      amountHidden: this.data.amountHidden,\n      context: this.context(),",
     "      amountHidden: !this.data.amountHidden,\n      context: this.context(),", "B5-hidden"),
    ("spoken NORMAL 金额隐藏写死 false", PRICE, "    return BuyButtonModel.spoken(this.base, this.rebate, this.amountHidden, this.context);",
     "    return BuyButtonModel.spoken(this.base, this.rebate, false, this.context);", "B4-a11y"),
    ("spoken NORMAL 改读 text（绕开读屏）", PRICE, "    return BuyButtonModel.spoken(this.base, this.rebate, this.amountHidden, this.context);",
     "    return this.base + this.rebate.spokenText;", "B4-a11y"),
    ("label 的 stateLabel 金额隐藏写死 false", PRICE, "this.state, this.base, this.retryText, this.rebate, this.amountHidden, this.context);",
     "this.state, this.base, this.retryText, this.rebate, false, this.context);", "B4-hidden"),
    ("BuyButton 另挂 accessibilityText(base)", PRICE, "        this.onTap();\n      }\n    })\n  }\n}",
     "        this.onTap();\n      }\n    })\n    .accessibilityText(this.base)\n  }\n}", "B4-a11y"),
    ("页面 BuyButton 吃 this.shownRebate()（遮罩）", BUY_PAGE, "rebate: this.rebate, amountHidden", "rebate: this.shownRebate(), amountHidden", "B5-mask"),
    ("页面 BuyButton 吃 CardAmountMask.rebate(...)", BUY_PAGE, "rebate: this.rebate, amountHidden",
     "rebate: CardAmountMask.rebate(this.rebate, true), amountHidden", "B5-mask"),
    # B6
    ("回落改 PriceTerms.buy（书 B7）", MODELS, "const fallback: string = contractText(KEY_BUY_FALLBACK);", "const fallback: string = PriceTerms.buy;", "B6"),
    ("回落键换成 btn.buy.coupon", MODELS, "const KEY_BUY_FALLBACK: string = 'btn.buy';", "const KEY_BUY_FALLBACK: string = 'btn.buy.coupon';", "B6-dict"),
    ("hidden 分支恒 false（书 B7）", MODELS, "    if (!amountHidden) {\n      return null;\n    }\n    const literal",
     "    if (true) {\n      return null;\n    }\n    const literal", "B6-gate"),
    ("spoken 不走回落", MODELS, "    const hiddenSpoken: string | null = BuyButtonModel.hiddenFallback(base, rebate, amountHidden);",
     "    const hiddenSpoken: string | null = null;", "B6-entry"),
    ("text 不走回落", MODELS, "    const hiddenText: string | null = BuyButtonModel.hiddenFallback(base, rebate, amountHidden);",
     "    const hiddenText: string | null = null;", "B6-entry"),
    # B8 / B9
    ("逻辑套件没登记", DS_LIST, "  l2ButtonTest();\n", "", "B8-register"),
    ("登记只在注释里", DS_LIST, "  l2ButtonTest();\n", "  // l2ButtonTest();\n", "B8-register"),
    ("登记包进 if", DS_LIST, "  l2ButtonTest();\n", "  if (Date.now() < 0) {\n    l2ButtonTest();\n  }\n", "B8-register"),
    ("目录缺 off-shelf", CATALOG, ", m(['single'], ['off-shelf'])]),", "]),", "B9-catalog"),
    ("目录缺点按计数", DETAIL, " ? 'catalog-events/CouliButton' : 'catalog-events/BuyButton')", " ? 'catalog-events/CouliButton' : 'catalog-events/Other')", "B9-events"),
]

# 测试 v3：良性改写（重构但接线不变），必须仍然全绿——防判据收紧过头。（名字，[(文件，原串，新串)…]）
BENIGN = [
    ("卡片经无参方法 this.buyRebate() 转一手未遮罩返利", [
        (CARD, "      base: this.data.buyBase,\n      rebate: this.data.rebate,", "      base: this.data.buyBase,\n      rebate: this.buyRebate(),"),
        (CARD, "  /** 卡内显示的返利（金额隐藏时不带金额，R1-02）。 */\n  private rebate(): RebateTagContent {",
         "  private buyRebate(): RebateTagContent {\n    return this.data.rebate;\n  }\n\n"
         "  /** 卡内显示的返利（金额隐藏时不带金额，R1-02）。 */\n  private rebate(): RebateTagContent {"),
    ]),
]


def self_test():
    failures = []
    with tempfile.TemporaryDirectory(prefix="l2button-selftest-") as tmp:
        good = os.path.join(tmp, "good")
        shutil.copytree(GOOD, good)
        got = check(good)
        if got:
            failures.append("参考实现不过：%s" % [(v["rule"], v["file"], v["line"], v["msg"]) for v in got])
        for idx, (name, rel, old, new, want) in enumerate(MUTATIONS):
            root = os.path.join(tmp, "m%02d" % idx)
            shutil.copytree(GOOD, root)
            path = os.path.join(root, rel)
            with open(path, encoding="utf-8") as f:
                text = f.read()
            if text.count(old) != 1:
                failures.append("变异「%s」的原串出现 %d 次（应 1 次）" % (name, text.count(old)))
                continue
            with open(path, "w", encoding="utf-8") as f:
                f.write(text.replace(old, new))
            try:
                rules = {v["rule"] for v in check(root)}
            except Incomplete as e:
                failures.append("变异「%s」解析不完整（变异写坏了，不算杀）：%s" % (name, e))
                continue
            if not any(r == want or r.startswith(want + "-") for r in rules):
                failures.append("变异「%s」没被 %s 杀（实际 %s）" % (name, want, sorted(rules)))
            shutil.rmtree(root)
        for idx, (name, edits) in enumerate(BENIGN):
            root = os.path.join(tmp, "b%02d" % idx)
            shutil.copytree(GOOD, root)
            for rel, old, new in edits:
                path = os.path.join(root, rel)
                with open(path, encoding="utf-8") as f:
                    text = f.read()
                if text.count(old) != 1:
                    failures.append("良性改写「%s」的原串出现 %d 次（应 1 次）" % (name, text.count(old)))
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text.replace(old, new))
            got = check(root)
            if got:
                failures.append("良性改写「%s」被误报：%s" % (name, [(v["rule"], v["msg"]) for v in got]))
            shutil.rmtree(root)
        # 语法错误必须 4（Incomplete），不算断言红
        root = os.path.join(tmp, "msyntax")
        shutil.copytree(GOOD, root)
        with open(os.path.join(root, PRICE), "a", encoding="utf-8") as f:
            f.write("\nexport struct {\n")
        try:
            check(root)
            failures.append("语法错误应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
        # 必查文件缺失也必须 4
        root = os.path.join(tmp, "mmissing")
        shutil.copytree(GOOD, root)
        os.remove(os.path.join(root, MAPPER))
        try:
            check(root)
            failures.append("缺文件应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
    total = len(MUTATIONS) + len(BENIGN) + 2
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("L2BUTTON_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("L2BUTTON_SELFTEST 通过：参考实现 1 + 变异 %d 全杀 + 良性改写 %d 全绿 + 语法错误 / 缺文件 fail-closed" % (len(MUTATIONS), len(BENIGN)))
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
        print("L2BUTTON 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("L2BUTTON 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    if violations:
        print("L2BUTTON_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("L2BUTTON_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
