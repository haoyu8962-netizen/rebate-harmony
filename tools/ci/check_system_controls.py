#!/usr/bin/env python3
"""FU-HM-G1-SYSTEM-CONTROLS-harmony（D10-827 ③ / D10-901 ② / D10-734 / D10-951）：禁止自绘系统已有控件。现存违规全进基线
tools/ci/system-controls-baseline.json，只减不增：计数超出失败，计数变少也失败（须同步降基线），基线里的文件不存在也失败。
只用 Python 3 标准库 + lint.py 的四个检测器（lint.g1_scan，同一条 node + 鸿蒙 SDK ohos-typescript 解析链）；列举、基线读写、判定用
importlib 复用 check_hardcoded_style.py 的函数（私有实例，不改那个文件），格式与严格度相同。

用法：
    python3 tools/ci/check_system_controls.py [--root <目录>] [--baseline <文件>]                   # 检查（默认仓库根与正式基线）
    python3 tools/ci/check_system_controls.py [--root <目录>] [--baseline <文件>] --write-baseline  # 按现状写基线，不做判定
    python3 tools/ci/check_system_controls.py --self-test                                           # 内嵌参照件 + 错误实现逐个打红

退出码：0 通过 / 写基线成功 / 自测通过；1 有违反（超出基线、少于基线、基线里的文件不存在、基线外新增；自测有错误实现没被打红或参照件
不过）；2 参数不对、基线文件缺失或非法（不是 JSON、不是对象、计数不是正整数、未知规则 key，含 couli-style/*）；3 解析工具链不可用
（复用 lint.hm10_toolchain）；4 无法保证扫完（语法错误、范围内目录无法列举、符号链接或特殊文件、源码读不出、记号切分与解析器不一致）。
--write-baseline 遇 4 不写文件。

范围（lint.g1_rules_for，D10-734 ④）：S1 / S2 / S4 = features/*/src/main/**、entry/src/main/**、entry/src/release/**；S3 另加
common/designsystem/src/main/**。范围内任意层目录都扫（mock/、build/ 同样照扫）；entry/src/staging、其余 common/*、src/test、src/ohosTest、
tools/ 不计。

规则：
    couli-g1/self-drawn-control      .accessibilityRole 是 SWITCH / CHECKBOX / RADIO / TAB_BAR，组件本身或子树里没有对应系统件（薄封装算；同文件 @Builder 展开一层）
    couli-g1/click-without-feedback  Row / Column / Stack / Flex / Text / Image / RelativeContainer 上的 .onClick，同一条链没有 stateStyles / clickEffect
    couli-g1/edge-effect-none        代码里出现 EdgeEffect.None
    couli-g1/hide-title-bar          NavDestination 的 .hideTitleBar 第一个参数不是字面量 false（根 Navigation 不算）
    couli-g1/exemption-reason        豁免注释没写理由（报在注释行；该豁免不生效）
白名单里的系统控件在任何范围都不计（lint.SYSTEM_CONTROLS，D37）。

豁免：`// couli-style-disable-next-line couli-g1/<规则>[ couli-g1/<规则>…] -- <理由>`，只管紧接的下一行、只管点名的规则。无理由或空理由 →
报 couli-g1/exemption-reason，豁免不生效。只点名 couli-style/* 的注释归 LINT-STYLE：本脚本既不报也不豁免。字符串里的伪指令不算。

基线 JSON：{"couli-g1/<规则>": {"<相对路径>": 计数}}，规则键只许上面五条；json.dumps(indent=2, ensure_ascii=False, sort_keys=True) + 换行；
不写 0 计数、不写空规则、无时间戳。按文件计数（不按行号）。
"""

import argparse
import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
BASELINE_REL = "tools/ci/system-controls-baseline.json"
PROG = "check_system_controls.py"

_spec = importlib.util.spec_from_file_location("couli_style_for_g1", os.path.join(HERE, "check_hardcoded_style.py"))
style = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(style)
lint = style.lint

S1, S2, S3, S4 = lint.G1_DETECTORS
EXR = "couli-g1/exemption-reason"
DETECTORS = [S1, S2, S3, S4]
RULES = DETECTORS + [EXR]

# 这是本脚本私有的模块实例，改它的范围与规则键不影响 LINT-STYLE 本身
style.KNOWN_RULES = RULES
style.SCOPES = list(style.SCOPES) + [("common/designsystem", False, ("src", "main"))]
# 范围路径的上层：list_scope 只查模块目录与 src、src/main，这几层是符号链接时同样不跟随
SCOPE_PARENTS = ["features", "entry", "common", "common/designsystem"]

JUDGE_WORDING = ("新增写死样式改用令牌", "新增自绘控件改用系统控件")
REASON_REQUIRED = True


def parse_exemptions(source, code):
    """返回 ({下一行号: {规则}}, [(注释行号, 说明)])。注释判定同 LINT-STYLE：源码行有指令、解析器去注释后的代码行没有（字符串里的伪指令
    在代码里原样保留，因而不算）。"""
    allowed = {}
    bad = []
    src_lines = re.sub("\r\n?| | ", "\n", source).split("\n")
    code_lines = code.split("\n")
    for idx, line in enumerate(src_lines):
        m = style.DISABLE_RE.search(line)
        if not m or (idx < len(code_lines) and "couli-style-disable-next-line" in code_lines[idx]):
            continue
        rules_text, _, reason = m.group(1).partition("--")
        rules = [r for r in re.split(r"[\s,]+", rules_text.strip()) if r.startswith("couli-g1/")]
        if not rules:
            continue  # 只点名 couli-style/*（或没点名）的注释归 LINT-STYLE
        if REASON_REQUIRED and not reason.strip():
            bad.append((idx + 1, "豁免注释缺少理由（写成 `-- <理由>`），该豁免不生效"))
            continue
        allowed.setdefault(idx + 2, set()).update(r for r in rules if r in DETECTORS)
    return allowed, bad


def analyze(rel, source, lexed):
    """单文件：返回 [(规则, 行号, 说明)]。切分不可靠抛 lint.G1ScanError。"""
    code = lexed["code"]
    hits = lint.g1_scan(code, lexed.get("braces"), lint.g1_rules_for(rel))
    allowed, bad = parse_exemptions(source, code)
    out = [h for h in hits if h[0] not in allowed.get(h[1], set())]
    if lint.g1_rules_for(rel):
        out.extend((EXR, ln, msg) for ln, msg in bad)
    return sorted(out, key=lambda h: (h[1], h[0]))


def scan(root):
    """返回 (hits: {规则: {相对路径: [(行, 说明)]}}, 范围内文件集合, incomplete)。工具链不可用抛 lint.HM10ToolchainError。"""
    incomplete = []
    lint.hm10_toolchain()
    for rel in SCOPE_PARENTS:
        if os.path.islink(os.path.join(root, *rel.split("/"))):
            incomplete.append("%s: 是符号链接（不跟随），无法保证扫完" % rel)
    files = style.list_scope(root, incomplete)
    items = []
    for rel in files:
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as f:
                items.append((rel, f.read()))
        except (OSError, UnicodeDecodeError) as e:
            incomplete.append("%s: 源码文件读不出（%s），无法保证扫完" % (rel, e))
    hits = {}
    for (rel, src), res in zip(items, style.lex_files(items) if items else []):
        if res.get("incomplete"):
            incomplete.append("%s:%d: %s，无法保证扫完" % (rel, res["incomplete"]["line"], res["incomplete"]["reason"]))
            continue
        try:
            found = analyze(rel, src, res)
        except lint.G1ScanError as e:
            incomplete.append("%s: %s，无法保证扫完" % (rel, e))
            continue
        for rule, ln, msg in found:
            hits.setdefault(rule, {}).setdefault(rel, []).append((ln, msg))
    return hits, set(files), incomplete


def judge(hits, files, baseline):
    return [line.replace(*JUDGE_WORDING) for line in style.judge(hits, files, baseline)]


def run(root, baseline_path, write):
    """返回退出码；输出打印到 stdout / stderr。"""
    baseline = None
    if not write:
        try:
            baseline = style.load_baseline(baseline_path)
        except style.BaselineError as e:
            print("%s：%s" % (PROG, e), file=sys.stderr)
            return 2
    try:
        hits, files, incomplete = scan(root)
    except lint.HM10ToolchainError as e:
        print("%s：解析工具链不可用（不退化为手写词法）：%s" % (PROG, e), file=sys.stderr)
        return 3
    if incomplete:
        for line in dict.fromkeys(incomplete):
            print(line)
        print("%s：%d 处无法保证扫完，失败（exit 4）%s" % (PROG, len(incomplete), "；未写基线" if write else ""), file=sys.stderr)
        return 4
    counts = style.counts_of(hits)
    if write:
        text = style.dump_baseline(counts)
        os.makedirs(os.path.dirname(os.path.abspath(baseline_path)), exist_ok=True)
        with open(baseline_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print("%s：已写基线 %s（%d 个文件、%d 处）" % (PROG, baseline_path, len(files), sum(sum(v.values()) for v in counts.values())))
        return 0
    problems = judge(hits, files, baseline)
    for p in problems:
        print(p)
    if problems:
        print("%s：%d 行违反（基线 %s）" % (PROG, len(problems), baseline_path), file=sys.stderr)
        return 1
    print("%s：0 处违反，计数与基线一致（%d 个文件，%s）" % (PROG, len(files), root))
    return 0


# ---------------------------------------------------------------------------------------------- 自测
_page = style._page
_D = "// couli-style-disable-next-line "
_F = "features/home/src/main/ets/"
_LIB = "common/designsystem/src/main/ets/"
_KNOB = "Row() {\n  Column()\n}\n"


def _role(kind):
    return ".accessibilityRole(AccessibilityRoleType.%s)" % kind


def _builder_page(builders, body):
    return ("@ComponentV2\nexport struct P {\n" + builders + "\n  build() {\n    Column() {\n"
            + "\n".join("      " + line for line in body.split("\n")) + "\n    }\n  }\n}\n")


_ALL_FOUR = _page(_KNOB + _role("SWITCH") + "\nRow() {\n}\n.onClick(() => {\n})\nList() {\n}\n.edgeEffect(EdgeEffect.None)\n"
                  "NavDestination() {\n}\n.hideTitleBar(true)")
_ALL_ONE = {S1: 1, S2: 1, S3: 1, S4: 1}
_ONE_LAYER = "  @Builder\n  body() {\n    Checkbox({ name: 'c' })\n  }\n"
_TWO_LAYERS = "  @Builder\n  outer() {\n    this.inner()\n  }\n\n  @Builder\n  inner() {\n    Toggle({ type: ToggleType.Switch })\n  }\n"
# 参照件：(相对路径, 源码, 期望计数)
SELF_FILES = [
    (_F + "S1Hits.ets", _page(_KNOB + _role("SWITCH") + "\nText('t')\n  " + _role("TAB_BAR") + "\nRow() {\n  Text('a')\n}\n"
                              ".accessibilityRole(this.f ? AccessibilityRoleType.RADIO : AccessibilityRoleType.BUTTON)"), {S1: 3}),
    (_F + "S1Wrong.ets", _page("Row() {\n  Checkbox({ name: 'c' })\n}\n" + _role("SWITCH")), {S1: 1}),
    (_F + "S1Legal.ets", _page("Row() {\n  Toggle({ type: ToggleType.Switch })\n}\n" + _role("SWITCH") + "\nColumn() {\n  TabSegmentButtonV2({ items: this.i })\n}\n"
                               + _role("TAB_BAR") + "\nToggle({ type: ToggleType.Switch })\n  " + _role("SWITCH") + "\nRow() {\n  CouliSwitch({ on: this.o })\n}\n"
                               + _role("SWITCH") + "\n" + _KNOB + _role("BUTTON") + "\n" + _KNOB + ".myAccessibilityRole(AccessibilityRoleType.SWITCH)\n"
                               "Text('.accessibilityRole(AccessibilityRoleType.RADIO)')"), {}),
    (_F + "S1Builder.ets", _builder_page(_ONE_LAYER, "Row() {\n  this.body()\n}\n" + _role("CHECKBOX")), {}),
    (_F + "S1Deep.ets", _builder_page(_TWO_LAYERS, "Row() {\n  this.outer()\n}\n" + _role("SWITCH")), {S1: 1}),
    (_F + "S2Hits.ets", _page("Row() {\n  Text('a')\n    .onClick(() => {\n    })\n}\n.onClick(() => {\n})\nImage($r('app.media.a'))\n  .onClick(() => {\n  })\n"
                              "Stack() {\n}\n.width('100%')\n.onClick(() => {\n})"), {S2: 4}),
    (_F + "S2Legal.ets", _page("Row() {\n}\n.onClick(() => {\n})\n.stateStyles({ pressed: this.p })\nText('a')\n  .clickEffect({ level: ClickEffectLevel.LIGHT })\n"
                               "  .onClick(() => {\n  })\nButton('ok')\n  .onClick(() => {\n  })\nList() {\n  ListItem() {\n  }\n  .onClick(() => {\n  })\n}\n"
                               "CouliButton({ text: this.t })\n  .onClick(() => {\n  })\nRow() {\n}\n.onClickX(() => {\n})\n"
                               "Text('Row().onClick(() => {})')\n// Row().onClick(() => {})"), {}),
    (_F + "S3Hits.ets", _page("List() {\n}\n.edgeEffect(this.f ? EdgeEffect.None : EdgeEffect.Spring)",
                              top="const E: EdgeEffect = EdgeEffect.None;\n"), {S3: 2}),
    (_F + "S3Clean.ets", _page("List() {\n}\n.edgeEffect(EdgeEffect.Spring)\n// .edgeEffect(EdgeEffect.None)\nText('EdgeEffect.None')",
                               top="const A: number = MyEdgeEffect.None;\n"), {}),
    (_F + "S4Hits.ets", _page("NavDestination() {\n}\n.hideTitleBar(true)\nNavDestination() {\n}\n.hideTitleBar(this.h)\nNavDestination() {\n}\n.hideTitleBar(!this.s)"), {S4: 3}),
    (_F + "S4Legal.ets", _page("NavDestination() {\n}\n.hideTitleBar(false)\nNavigation() {\n}\n.hideTitleBar(true)\nNavDestination() {\n}\n.hideTitleBarX(true)"), {}),
    (_F + "Ex.ets", _page("List() {\n}\n" + _D + S3 + " -- 弹层拖拽\n.edgeEffect(EdgeEffect.None)\nList() {\n}\n" + _D + S3 + "\n.edgeEffect(EdgeEffect.None)\n"
                          "List() {\n}\n" + _D + "couli-style/no-hex-color\n.edgeEffect(EdgeEffect.None)\nRow() {\n}\n" + _D + S3 + " -- 点名别的规则\n.onClick(() => {\n})"),
     {S3: 2, S2: 1, EXR: 1}),
    (_F + "ExString.ets", _page("List() {\n}\n.edgeEffect(EdgeEffect.None)", top="const S: string = '" + _D + S3 + " -- x';\n"), {S3: 1}),
    # 除号不能被当成正则开头：i++ / n、a.of / 2（切错就以 4 失败，参照件会红）
    (_F + "Div.ets", _page("Text('a')", top="let i: number = 0;\nconst n: number = i++ / 2;\nconst a: A = { of: 6 };\nconst m: number = a.of / 2;\n"), {}),
    (_F + "Ctl.ets", _page("Button('a')\nCheckbox({ name: 'c' })\nToggle({ type: ToggleType.Switch })\nDivider()\nTextInput()\nTabs() {\n}\nText('b').bindSheet(true, this.p())"), {}),
    (_F + "mock/M.ets", _page("Row() {\n}\n.onClick(() => {\n})"), {S2: 1}),
    ("entry/src/main/ets/build/B.ets", _page("NavDestination() {\n}\n.hideTitleBar(true)"), {S4: 1}),
    ("entry/src/release/ets/R.ets", _ALL_FOUR, _ALL_ONE),
    (_LIB + "components/C.ets", _ALL_FOUR, {S3: 1}),
    ("entry/src/staging/ets/S.ets", _ALL_FOUR, {}),
    ("common/core/src/main/ets/K.ets", _ALL_FOUR, {}),
    ("features/home/src/test/T.ets", _ALL_FOUR, {}),
]


def _expected_counts():
    out = {}
    for rel, _, want in SELF_FILES:
        for rule, n in want.items():
            out.setdefault(rule, {})[rel] = n
    return out


def _self_scenarios():
    """(说明, 改动的文件 {rel: 源码 | ("->", 目标)}, 基线, 期望退出码)。"""
    base = _expected_counts()
    lower = json.loads(json.dumps(base))
    lower[S2][_F + "S2Hits.ets"] = 3
    higher = json.loads(json.dumps(base))
    higher[S2][_F + "S2Hits.ets"] = 5
    ghost = json.loads(json.dumps(base))
    ghost[S3][_F + "Gone.ets"] = 1
    return [
        ("参照件 = 基线", {}, base, 0),
        ("超出基线", {}, lower, 1),
        ("少于基线须降", {}, higher, 1),
        ("基线里的文件不存在", {}, ghost, 1),
        ("新文件注入 EdgeEffect.None", {_F + "New.ets": _page("List() {\n}\n.edgeEffect(EdgeEffect.None)")}, base, 1),
        ("范围内符号链接 → 4", {_F + "Link.ets": ("->", "S1Hits.ets")}, base, 4),
        ("组件库符号链接 → 4", {_LIB + "Link.ets": ("->", "components/C.ets")}, base, 4),
        # `)` 之后的正则被切成除号，里面的花括号被当成代码：括号本身配得上，只有与解析器核对才查得出
        ("记号切分与解析器不一致 → 4", {_F + "Re.ets": _page("Text('a')", top="function f(s: string): boolean {\n  if (s.length > 0) /{x}/.test(s) / 1;\n  return true;\n}\n")}, base, 4),
        ("正则里的括号配不上 → 4", {_F + "Re.ets": _page("Text('a')", top="function f(s: string): boolean {\n  if (s.length > 0) /\\(/.test(s);\n  return true;\n}\n")}, base, 4),
    ]


def _self_run(files, baseline):
    """在临时树里跑一遍；返回 (counts, 退出码)。"""
    tmp = tempfile.mkdtemp(prefix="couli-g1-self-")
    try:
        for rel, src in files.items():
            path = os.path.join(tmp, *rel.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if isinstance(src, tuple):
                os.symlink(src[1], path)
                continue
            with open(path, "w", encoding="utf-8") as f:
                f.write(src)
        hits, scope, incomplete = scan(tmp)
        if incomplete:
            return None, 4
        return style.counts_of(hits), (1 if judge(hits, scope, baseline) else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _load_rejected(data):
    """基线内容 data 是否被判非法。"""
    tmp = tempfile.mkdtemp(prefix="couli-g1-base-")
    try:
        path = os.path.join(tmp, "b.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f)
        try:
            style.load_baseline(path)
            return False
        except style.BaselineError:
            return True
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _evaluate():
    """参照件全部场景都对 → []；否则返回不对的场景说明。"""
    bad = []
    files = {rel: src for rel, src, _ in SELF_FILES}
    for title, change, baseline, want in _self_scenarios():
        tree = dict(files)
        tree.update(change)
        counts, code = _self_run(tree, baseline)
        if title == "参照件 = 基线" and counts != _expected_counts():
            bad.append("%s：计数不符" % title)
        elif code != want:
            bad.append("%s：退出 %s，应为 %d" % (title, code, want))
    for title, data in [("未知规则 key", {"couli-g1/nope": {_F + "A.ets": 1}}), ("LINT-STYLE 规则 key", {"couli-style/no-hex-color": {_F + "A.ets": 1}}),
                        ("计数为 0", {S3: {_F + "A.ets": 0}})]:
        if not _load_rejected(data):
            bad.append("基线非法未被拒绝：%s" % title)
    return bad


def _set(obj, name, value):
    def apply():
        old = getattr(obj, name)
        setattr(obj, name, value)
        return lambda: setattr(obj, name, old)
    return apply


def _set_here(name, value):
    """同 _set，改本模块的全局名字（import 或直接运行都可用）。"""
    def apply():
        old = globals()[name]
        globals()[name] = value
        return lambda: globals().__setitem__(name, old)
    return apply


def _both(*patches):
    def apply():
        restores = [p() for p in patches]
        return lambda: [r() for r in reversed(restores)]
    return apply


_ROLES = lint.G1_ROLE_CONTROLS
# 错误实现：(规则类, 说明, 打补丁)
MUTANTS = [
    (S1, "子树一律判合法", _set(lint, "_g1_role_legal", lambda toks, chain, role, builders: chain[1] is not None or lint._g1_is_role_control(toks[chain[0]][1], role))),
    (S1, "漏判 TAB_BAR", _set(lint, "G1_ROLE_CONTROLS", {k: v for k, v in _ROLES.items() if k != "TAB_BAR"})),
    (S1, "只认 Row 不认 Text", _set(lint, "G1_ROLE_HEADS", {"Row", "Column"})),
    (S1, "不展开同文件 @Builder", _set(lint, "_g1_builders", lambda toks, match: {})),
    (S1, "错配的系统件也算合法", _set(lint, "_g1_is_role_control", lambda name, role: any(name in v for v in _ROLES.values()) or "SegmentButton" in name)),
    (S1, "@Builder 展开不止一层", _set(lint, "_g1_has_control", lambda toks, lo, hi, role: any(
        lint._g1_is_call(toks, i) and lint._g1_is_role_control(toks[i][1], role) for i in range(lo, hi)) or any(toks[i][1] == "inner" for i in range(lo, hi)))),
    (S2, "Button 也计入", _set(lint, "G1_CLICK_HEADS", lint.G1_CLICK_HEADS | {"Button"})),
    (S2, "ListItem 也计入", _set(lint, "G1_CLICK_HEADS", lint.G1_CLICK_HEADS | {"ListItem"})),
    (S2, "漏判 Image", _set(lint, "G1_CLICK_HEADS", lint.G1_CLICK_HEADS - {"Image"})),
    (S2, "忽略 stateStyles", _set(lint, "G1_CLICK_FEEDBACK", {"clickEffect"})),
    (S2, "忽略 clickEffect", _set(lint, "G1_CLICK_FEEDBACK", {"stateStyles"})),
    (S2, "计入字符串里的 onClick", _both(_set(lint, "G1_SKIP_STRINGS", False), _set(lint, "G1_BRACE_CROSSCHECK", False))),
    (S3, "不扫组件库", _set(lint, "G1_LIBRARY_SCOPE", None)),
    (S3, "把 staging 计入", _both(_set(lint, "G1_PAGE_SCOPE_RE", re.compile(r"(?:features/[^/]+/src/main/|entry/src/main/|entry/src/release/|entry/src/staging/)")),
                                  _set(style, "SCOPES", style.SCOPES + [("entry", False, ("src", "staging"))]))),
    (S3, "组件库也算 S1 / S2 / S4", _set(lint, "g1_rules_for", lambda rel: lint.G1_DETECTORS if rel.startswith(("features/", "entry/", "common/designsystem/")) else ())),
    (S4, "把根 Navigation 计入", _set(lint, "G1_TITLE_HEADS", {"NavDestination", "Navigation"})),
    (S4, "只认字面量 true", _set(lint, "_g1_hides_title_bar", lambda toks, match, op, cl: cl == op + 2 and toks[op + 1][1] == "true")),
    (S4, "字面量 false 也报", _set(lint, "_g1_hides_title_bar", lambda toks, match, op, cl: True)),
    (EXR, "豁免不要求理由", _set_here("REASON_REQUIRED", False)),
    (EXR, "豁免对所有规则生效", _set_here("parse_exemptions", lambda s, c: (
        {i: set(DETECTORS) for i in range(1, s.count("\n") + 2) if ("couli-g1/" in s.split("\n")[i - 2] if i >= 2 else False)}, []))),
    (EXR, "字符串里的伪指令也算", _set_here("parse_exemptions", lambda s, c: (
        {i + 2: set(DETECTORS) for i, ln in enumerate(s.split("\n")) if "couli-g1/edge-effect-none" in ln}, []))),
    ("基线", "超出不失败", _set(style, "CHECK_EXCEED", False)),
    ("基线", "变少不失败", _set(style, "CHECK_DECREASE", False)),
    ("基线", "基线里的文件消失不失败", _set(style, "CHECK_MISSING", False)),
    ("基线", "未知 key 收下", _set(style, "KNOWN_RULES", RULES + ["couli-g1/nope", "couli-style/no-hex-color"])),
    ("范围", "页面范围内 mock / build 目录被跳过", _set(style, "SKIP_DIR_NAMES", {"mock", "build"})),
    ("范围", "符号链接静默跳过", _set(style, "SYMLINK_FAILS", False)),
    ("解析", "去掉与解析器的花括号核对", _set(lint, "G1_BRACE_CROSSCHECK", False)),
]


def self_test():
    try:
        lint.hm10_toolchain()
    except lint.HM10ToolchainError as e:
        print("自测：解析工具链不可用：%s" % e, file=sys.stderr)
        return 3
    failed = 0
    bad = _evaluate()
    if bad:
        failed += 1
        print("  FAIL 参照件：%s" % "；".join(bad))
    else:
        print("  PASS 参照件：%d 个文件、%d 个场景全部符合" % (len(SELF_FILES), len(_self_scenarios())))
    for rule, title, patch in MUTANTS:
        restore = patch()
        try:
            killed = _evaluate()
        except Exception as e:  # 错误实现崩溃也算打红
            killed = ["崩溃：%s" % e]
        finally:
            restore()
        if killed:
            print("  PASS 错误实现被打红 [%s] %s（%s）" % (rule, title, killed[0]))
        else:
            failed += 1
            print("  FAIL 错误实现没被打红 [%s] %s" % (rule, title))
    print("%s 自测：参照件 + %d 个错误实现，%d 项失败" % (PROG, len(MUTANTS), failed))
    return 1 if failed else 0


# ---------------------------------------------------------------------------------------------- 入口
def main(argv):
    parser = argparse.ArgumentParser(prog=PROG, description="禁自绘系统控件基线检查（FU-HM-G1-SYSTEM-CONTROLS-harmony）")
    parser.add_argument("--root", help="仓库根（默认脚本所在仓库）")
    parser.add_argument("--baseline", help="基线文件（默认 <root>/%s）" % BASELINE_REL)
    parser.add_argument("--write-baseline", action="store_true", help="按现状写基线，不做判定")
    parser.add_argument("--self-test", action="store_true", help="内嵌参照件 + 错误实现逐个打红")
    args = parser.parse_args(argv)  # 参数不对 argparse 以 2 退出
    if args.self_test:
        if args.root or args.baseline or args.write_baseline:
            parser.error("--self-test 不与其他参数同用")
        return self_test()
    root = os.path.abspath(args.root or REPO_ROOT)
    if not os.path.isdir(root):
        print("%s：--root 不是目录：%s" % (PROG, root), file=sys.stderr)
        return 2
    baseline = os.path.abspath(args.baseline or os.path.join(root, *BASELINE_REL.split("/")))
    return run(root, baseline, args.write_baseline)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
