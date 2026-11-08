#!/usr/bin/env python3
"""LINT-STYLE-harmony（D10-643 ④ / D10-729 / D10-734 / D10-901）：页面层禁写死颜色、字号、圆角、间距。
现存违规全进基线 tools/ci/hardcoded-style-baseline.json，只减不增：计数超出失败，计数变少也失败（须同步降基线），基线里的
文件不存在也失败。只用 Python 3 标准库 + lint.py 的解析链（importlib 复用 lint.lex_scan：node + 鸿蒙 SDK ohos-typescript
给出去掉注释的代码与解码后的字符串，本脚本不手写注释词法）。

用法：
    python3 tools/ci/check_hardcoded_style.py [--root <目录>] [--baseline <文件>]                   # 检查（默认仓库根与正式基线）
    python3 tools/ci/check_hardcoded_style.py [--root <目录>] [--baseline <文件>] --write-baseline  # 按现状写基线，不做判定
    python3 tools/ci/check_hardcoded_style.py --self-test                                           # 内嵌参照件 + 错误实现逐个打红

退出码：0 通过 / 写基线成功 / 自测通过；1 有违反（超出基线、少于基线、基线里的文件不存在、基线外新增；自测有错误实现没被
打红或参照件不过）；2 参数不对、基线文件缺失或非法（不是 JSON、不是对象、计数不是正整数、未知规则 key）；3 解析工具链不可用
（复用 lint.hm10_toolchain：COULI_HM_NODE / COULI_HM_TYPESCRIPT 等）；4 无法保证扫完（解析器报语法错误、范围内目录无法列举、
条目类型无法确认、符号链接或特殊文件、源码读不出、本脚本的记号切分与解析器给出的字符串不一致）。--write-baseline 遇 4 不写文件。

范围（任务书 §1.3、D10-734 ④）：features/*/src/main/**、entry/src/main/**、entry/src/release/** 的 .ets；逐层显式列举
（FU-HM-0718 口径），范围内任意层目录都扫、不套 lint.SKIP_DIRS（mock/、build/ 等同样照扫，评审 r1 S1-1；与 HM-LINT-10 同口径）；
范围内（含 features/* 模块目录与 src、src/main、src/release 本身）出现符号链接以 4 失败。entry/src/staging、common/*、src/test、
src/ohosTest、tools/ 不在范围内。

规则（ID 与 web F1-01w lint/style 同名，前缀 couli-style/；每个字面量计 1）：
    couli-style/no-hex-color      字符串值整串是 #RGB / #RGBA / #RRGGBB / #AARRGGBB 或 rgb( / rgba( 开头；数字色 0x + 6～8 位十六进制；
                                  Color.<枚举>（Color.Transparent 除外，D10-734 ②）。'#/route'、'#section-1'、0x1F 不算
    couli-style/no-numeric-style  非 0 数字或纯长度字符串（'14vp' / '2fp' / '8px' / '4lpx' / '14'，可带负号；百分比不算）直接写在：
                                  .fontSize(…) 与对象属性 fontSize:；.borderRadius(…) 及角对象（topLeft / topRight / bottomLeft /
                                  bottomRight / topStart / topEnd / bottomStart / bottomEnd）；.border({ radius }) 及其角对象；
                                  .padding(…) / .margin(…) 及 top / bottom / left / right / start / end 对象；Row / Column / Flex /
                                  List / Grid 构造参数的 space:。只拦字面量（D10-734 ③）：令牌、局部常量、函数调用（iconVp(…)、
                                  LengthMetrics.vp(8)）不算；shadow({ radius })、border({ width })、宽高不算（D10-734 ⑥）
    couli-style/exemption-reason  豁免注释没写理由（报在注释行；该豁免不生效）
    web 的 no-arbitrary-value / no-small-brand-text 是 Tailwind 专属，鸿蒙不设。
系统控件本身不计、不进基线（D10-901：D37 / ui-rules #295 系统控件是首选，对齐安卓 D10-830）；写在控件上的写死样式照上面的规则报。

豁免：`// couli-style-disable-next-line <规则ID>[ <规则ID>…] -- <理由>`，只管紧接的下一行、只管点名的规则，只对 no-hex-color /
no-numeric-style 生效。没有 `--` 或理由为空 → 报 couli-style/exemption-reason（行号 = 注释行），豁免不生效；点名其他规则（含已撤回
的 design-system-required/<控件>）且写了理由的，不报、也不豁免任何东西。不用 eslint-disable 前缀（codelinter 基于 ESLint，未知规则
可能报错或被误吞）。

基线 JSON：{"couli-style/<规则>": {"<相对路径>": 计数}}，规则键只许上面三条（已撤回的 couli-style/design-system-required 及其
/<控件> 按未知规则 key 以 2 退出）；json.dumps(indent=2, ensure_ascii=False, sort_keys=True) + 换行；不写 0 计数、不写空规则、
无时间戳。按文件计数（不按行号），页面改动行号不会误红。
"""

import argparse
import bisect
import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
BASELINE_REL = "tools/ci/hardcoded-style-baseline.json"

_spec = importlib.util.spec_from_file_location("couli_lint_for_style", os.path.join(HERE, "lint.py"))
lint = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lint)

HEX = "couli-style/no-hex-color"
NUM = "couli-style/no-numeric-style"
EXR = "couli-style/exemption-reason"
# D10-901：基线允许的规则键只这三条（couli-style/design-system-required 及其 /<控件> 已撤回，出现在基线里按未知规则以 2 退出）
KNOWN_RULES = [HEX, NUM, EXR]

# 范围：(顶层目录, 是否按 features/* 展开, 子路径)
SCOPES = [("features", True, ("src", "main")), ("entry", False, ("src", "main")), ("entry", False, ("src", "release"))]
# r2（评审 r1 S1-1）：页面范围内任意层目录都扫（mock/、build/ 等不跳过）——src/main、src/release 下的 .ets 不管目录叫什么都可被
# import 并编进 HAP，与 lint.py HM-LINT-10「范围内不套 SKIP_DIRS」同口径。src/test、src/ohosTest、staging、common 本来就不在范围里。
SKIP_DIR_NAMES = set()
SOURCE_SUFFIXES = (".ets",)
IGNORED_NAMES = {".DS_Store"}

HEX_STRING_RE = re.compile(r"#(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})")
RGB_STRING_RE = re.compile(r"\s*rgba?\s*\(", re.I)
HEX_NUMBER_RE = re.compile(r"0[xX][0-9A-Fa-f]{6,8}")
COLOR_ALLOWED = {"Transparent"}
LENGTH_STRING_RE = re.compile(r"-?(?:\d+(?:\.\d*)?|\.\d+)(?:vp|fp|px|lpx)?")

STYLE_CALLS = {"fontSize": (), "borderRadius": "corners", "padding": "edges", "margin": "edges", "border": "border",
               "font": "size", "placeholderFont": "size",  # r2（S1-2）：.font({ size }) / .placeholderFont({ size })
               # r3（测试 v5，间距类命名参数）：Grid / WaterFlow 行列间距、Swiper 项间距与前后露出边距、Select 文字与箭头间距
               # （整个参数是字面量才算）；safeAreaPadding 同 padding；List .lanes 只看第 2 参 gutter；Tabs .barGridAlign 只看 margin / gutter
               "columnsGap": (), "rowsGap": (), "itemSpace": (), "prevMargin": (), "nextMargin": (), "space": (),
               "safeAreaPadding": "edges", "lanes": "lanes", "barGridAlign": "barGrid"}
CORNER_KEYS = {"topLeft", "topRight", "bottomLeft", "bottomRight", "topStart", "topEnd", "bottomStart", "bottomEnd"}
EDGE_KEYS = {"top", "bottom", "left", "right", "start", "end"}
SPACE_CONTAINERS = {"Row", "Column", "Flex", "List", "Grid", "ListItemGroup"}
GUTTER_CONTAINERS = {"GridRow"}  # r3：GridRow({ gutter: N | { x, y } })
GUTTER_AXES = {"x", "y"}
BAR_GRID_KEYS = {"margin", "gutter"}
FONT_SIZE_PROPERTY = True
BORDER_RADIUS_CORNERS = True
STRING_CROSSCHECK = True
SYMLINK_FAILS = True
FONT_SIZE_PROPERTY_ANY_KEY = True

DISABLE_RE = re.compile(r"//\s*couli-style-disable-next-line\b(.*)$")


class Incomplete(Exception):
    pass


# ---------------------------------------------------------------------------------------------- 记号切分（输入已去注释）
PUNCT_BEFORE_REGEX = set("(,=:[!&|?{};+-*%<>~^")
KEYWORDS_BEFORE_REGEX = {"return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "yield", "await"}


def _decode(raw):
    """解码字符串字面量内容（与解析器的解码值比对用）。"""
    out = []
    i = 0
    n = len(raw)
    simple = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "v": "\v", "0": "\0"}
    while i < n:
        c = raw[i]
        if c != "\\" or i + 1 >= n:
            out.append(c)
            i += 1
            continue
        e = raw[i + 1]
        if e in simple and not (e == "0" and i + 2 < n and raw[i + 2].isdigit()):
            out.append(simple[e])
            i += 2
        elif e == "x" and re.match(r"[0-9A-Fa-f]{2}", raw[i + 2:i + 4]):
            out.append(chr(int(raw[i + 2:i + 4], 16)))
            i += 4
        elif e == "u" and raw[i + 2:i + 3] == "{":
            j = raw.find("}", i + 3)
            out.append(chr(int(raw[i + 3:j], 16)))
            i = j + 1
        elif e == "u" and re.match(r"[0-9A-Fa-f]{4}", raw[i + 2:i + 6]):
            out.append(chr(int(raw[i + 2:i + 6], 16)))
            i += 6
        elif e == "\n":
            i += 2
        else:
            out.append(e)
            i += 2
    # 代理对合并（😀）
    return "".join(out).encode("utf-16", "surrogatepass").decode("utf-16")


def tokenize(code):
    """把解析器给出的代码（注释已换成空格、字符串原样）切成记号：(kind, text, pos)。kind：str（text 为解码值）、num、id、p。"""
    toks = []
    stack = []  # "{" 或 "${"
    i = 0
    n = len(code)

    def prev_allows_regex():
        if not toks:
            return True
        k, t, pos = toks[-1]
        if k == "p":
            # 后缀 ++ / -- 之后只能是除号（a++ / b）
            if t in "+-" and len(toks) > 1 and toks[-2][:2] == ("p", t) and toks[-2][2] == pos - 1:
                return False
            return t in PUNCT_BEFORE_REGEX
        return k == "id" and t in KEYWORDS_BEFORE_REGEX

    def read_template(i):
        """从模板文本段开头读到 ` 或 ${；返回 (原文, 新位置, 是否以 ${ 结束)。"""
        start = i
        while i < n:
            c = code[i]
            if c == "\\":
                i += 2
                continue
            if c == "`":
                return code[start:i], i + 1, False
            if c == "$" and i + 1 < n and code[i + 1] == "{":
                return code[start:i], i + 2, True
            i += 1
        raise Incomplete("模板字面量未闭合")

    while i < n:
        c = code[i]
        if c in " \t\n\r\f\v ﻿":
            i += 1
        elif c in "'\"":
            j = i + 1
            while j < n and code[j] != c:
                if code[j] == "\\":
                    j += 1
                elif code[j] == "\n":
                    raise Incomplete("字符串字面量未闭合")
                j += 1
            if j >= n:
                raise Incomplete("字符串字面量未闭合")
            toks.append(("str", _decode(code[i + 1:j]), i))
            i = j + 1
        elif c == "`":
            raw, j, opened = read_template(i + 1)
            toks.append(("str", _decode(raw), i))
            if opened:
                stack.append("${")
            i = j
        elif c == "}" and stack and stack[-1] == "${":
            stack.pop()
            raw, j, opened = read_template(i + 1)
            toks.append(("str", _decode(raw), i))
            if opened:
                stack.append("${")
            i = j
        elif c.isdigit() or (c == "." and i + 1 < n and code[i + 1].isdigit()):
            m = re.match(r"0[xX][0-9A-Fa-f_]+n?|0[bB][01_]+n?|0[oO][0-7_]+n?|(?:\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d+)?n?",
                         code[i:])
            toks.append(("num", m.group(0), i))
            i += len(m.group(0))
        elif c.isalpha() or c in "_$" or ord(c) > 127:
            j = i + 1
            while j < n and (code[j].isalnum() or code[j] in "_$" or (ord(code[j]) > 127 and not code[j].isspace())):
                j += 1
            toks.append(("id", code[i:j], i))
            i = j
        elif c == "/" and prev_allows_regex():
            j = i + 1
            in_class = False
            while j < n:
                d = code[j]
                if d == "\\":
                    j += 2
                    continue
                if d == "\n":
                    raise Incomplete("正则字面量未闭合")
                if d == "[":
                    in_class = True
                elif d == "]":
                    in_class = False
                elif d == "/" and not in_class:
                    break
                j += 1
            j += 1
            while j < n and (code[j].isalnum() or code[j] == "_"):
                j += 1
            toks.append(("re", code[i:j], i))
            i = j
        else:
            if c == "{":
                stack.append("{")
            elif c == "}" and stack:
                stack.pop()
            toks.append(("p", c, i))
            i += 1
    if stack:
        raise Incomplete("括号或模板插值无法配对")
    return toks


# ---------------------------------------------------------------------------------------------- 规则
def is_hex_string(value):
    return bool(HEX_STRING_RE.fullmatch(value) or RGB_STRING_RE.match(value))


def numeric_literal_value(text):
    t = text.replace("_", "").rstrip("n")
    try:
        if t[:2].lower() == "0x":
            return int(t, 16)
        if t[:2].lower() == "0b":
            return int(t[2:], 2)
        if t[:2].lower() == "0o":
            return int(t[2:], 8)
        return float(t)
    except ValueError:
        return 1.0


def is_length_string(value):
    if not LENGTH_STRING_RE.fullmatch(value):
        return False
    return float(re.sub(r"[a-z]+$", "", value)) != 0


def match_close(toks, i):
    """toks[i] 是 ( [ {，返回配对的下标。"""
    pairs = {"(": ")", "[": "]", "{": "}"}
    depth = 0
    for j in range(i, len(toks)):
        k, t, _ = toks[j]
        if k != "p":
            continue
        if t in pairs:
            depth += 1
        elif t in ")]}":
            depth -= 1
            if depth == 0:
                return j
    raise Incomplete("括号无法配对")


def split_top(toks, lo, hi, sep=","):
    """[lo, hi) 内按顶层 sep 切段。"""
    out = []
    start = lo
    j = lo
    while j < hi:
        k, t, _ = toks[j]
        if k == "p" and t in "([{":
            j = match_close(toks, j) + 1
            continue
        if k == "p" and t == sep:
            out.append((start, j))
            start = j + 1
        j += 1
    out.append((start, hi))
    return [(a, b) for a, b in out if a < b]


def literal_hits(toks, lo, hi):
    """值表达式 [lo, hi) 整个就是一个非 0 数字字面量（可带一元正负号）或纯长度字符串时，返回 [该字面量下标]；否则 []。
    只拦字面量（D10-734 ③）：三元、算术（BULLET_DOT / 2、length - 1）、调用、令牌都是表达式，不算（与调研口径一致）。"""
    j = lo
    while j < hi and toks[j][0] == "p" and toks[j][1] in "+-" and SIGNED_LITERALS:
        j += 1
    if j != hi - 1:
        return []
    k, t, _ = toks[j]
    if k == "num" and numeric_literal_value(t) != 0:
        return [j]
    if k == "str" and is_length_string(t):
        return [j]
    return []


SIGNED_LITERALS = True


def object_entries(toks, open_idx):
    """对象字面量 { … } 的顶层条目：[(键, 值起点, 值终点)]。"""
    close = match_close(toks, open_idx)
    out = []
    for a, b in split_top(toks, open_idx + 1, close):
        if b - a >= 3 and toks[a][0] in ("id", "str") and toks[a + 1] == ("p", ":", toks[a + 1][2]):
            out.append((toks[a][1], a + 2, b))
    return out


def is_object_value(toks, lo, hi):
    return lo < hi and toks[lo][0] == "p" and toks[lo][1] == "{" and match_close(toks, lo) == hi - 1


def keyed_hits(toks, lo, hi, keys):
    """值是对象 → 只看 keys 里的键；否则看整个值。"""
    if is_object_value(toks, lo, hi):
        hits = []
        for key, a, b in object_entries(toks, lo):
            if key in keys:
                hits.extend(literal_hits(toks, a, b))
        return hits
    return literal_hits(toks, lo, hi)


def numeric_style_hits(toks):
    """返回 [(字面量下标, 位置说明)]，按下标排序。"""
    found = {}
    n = len(toks)

    class _Sink(list):
        def __init__(self, where):
            super().__init__()
            self.where = where

        def extend(self, idxs):
            for x in idxs:
                found.setdefault(x, self.where)
    for i, (k, t, _) in enumerate(toks):
        if k != "id":
            continue
        nxt = toks[i + 1] if i + 1 < n else None
        prev = toks[i - 1] if i > 0 else None
        prev_dot = prev is not None and prev[0] == "p" and prev[1] == "."
        # .fontSize(…) / .borderRadius(…) / .padding(…) / .margin(…) / .border({ radius })
        if prev_dot and t in STYLE_CALLS and nxt is not None and nxt[0] == "p" and nxt[1] == "(":
            close = match_close(toks, i + 1)
            args = split_top(toks, i + 2, close)
            if not args:
                continue
            lo, hi = args[0]
            kind = STYLE_CALLS[t]
            hits = _Sink("." + t + "(…)")
            if kind == "corners":
                hits.extend(keyed_hits(toks, lo, hi, CORNER_KEYS))
            elif kind == "edges":
                hits.extend(keyed_hits(toks, lo, hi, EDGE_KEYS))
            elif kind == "border":
                if is_object_value(toks, lo, hi):
                    for key, a, b in object_entries(toks, lo):
                        if key == "radius":
                            hits.extend(keyed_hits(toks, a, b, CORNER_KEYS if BORDER_RADIUS_CORNERS else set()))
            elif kind == "lanes":
                if len(args) > 1:
                    hits.extend(literal_hits(toks, *args[1]))
            elif kind == "barGrid":
                if is_object_value(toks, lo, hi):
                    for key, a, b in object_entries(toks, lo):
                        if key in BAR_GRID_KEYS:
                            hits.extend(literal_hits(toks, a, b))
            elif kind == "size":
                if is_object_value(toks, lo, hi):
                    for key, a, b in object_entries(toks, lo):
                        if key == "size":
                            hits.extend(literal_hits(toks, a, b))
            else:
                if not is_object_value(toks, lo, hi):
                    hits.extend(literal_hits(toks, lo, hi))
        # Row / Column / Flex / List / Grid({ space: … })
        elif (not prev_dot and t in SPACE_CONTAINERS and nxt is not None and nxt == ("p", "(", nxt[2])
              and i + 2 < n and toks[i + 2][0] == "p" and toks[i + 2][1] == "{"):
            for key, a, b in object_entries(toks, i + 2):
                if key == "space":
                    _Sink(t + "({ space })").extend(literal_hits(toks, a, b))
        # GridRow({ gutter: N | { x, y } })
        elif (not prev_dot and t in GUTTER_CONTAINERS and nxt is not None and nxt == ("p", "(", nxt[2])
              and i + 2 < n and toks[i + 2][0] == "p" and toks[i + 2][1] == "{"):
            for key, a, b in object_entries(toks, i + 2):
                if key == "gutter":
                    _Sink(t + "({ gutter })").extend(keyed_hits(toks, a, b, GUTTER_AXES))
        # 对象字面量属性 fontSize: 14（类型位置 fontSize: number 的值不是字面量，不算）
        elif (FONT_SIZE_PROPERTY and t == "fontSize" and not prev_dot and nxt is not None and nxt[0] == "p" and nxt[1] == ":"
              and prev is not None and prev[0] == "p" and prev[1] in ("{," if FONT_SIZE_PROPERTY_ANY_KEY else "{")):
            lo = i + 2
            j = lo
            while j < n:
                kk, tt, _ = toks[j]
                if kk == "p" and tt in "([{":
                    j = match_close(toks, j) + 1
                    continue
                if kk == "p" and tt in ",;)}]":
                    break
                if j > lo and kk == "id" and toks[j - 1][0] != "p":
                    break  # 换行分隔的类型成员：下一个成员名
                j += 1
            _Sink("fontSize:").extend(literal_hits(toks, lo, j))
    return sorted(found.items())


def hex_color_hits(toks):
    hits = []
    for i, (k, t, _) in enumerate(toks):
        if k == "str" and is_hex_string(t):
            hits.append((i, "色值字符串 %r；改用 CouliColors 令牌" % t))
        elif k == "num" and HEX_NUMBER_RE.fullmatch(t.replace("_", "")):
            hits.append((i, "数字色 %s；改用 CouliColors 令牌" % t))
        elif (k == "id" and t == "Color" and i + 2 < len(toks) and toks[i + 1][:2] == ("p", ".") and toks[i + 2][0] == "id"
              and toks[i + 2][1] not in COLOR_ALLOWED and not (i > 0 and toks[i - 1][:2] == ("p", "."))):
            hits.append((i, "颜色枚举 Color.%s；改用 CouliColors 令牌" % toks[i + 2][1]))
    return hits


def exemptable(rule):
    return rule in (HEX, NUM)


def parse_exemptions(source, code):
    """返回 ({下一行号: {规则}}, [(注释行号, 说明)] 的 exemption-reason 违反)。注释判定：源码行有指令、去注释后的代码行没有
    （字符串里的伪指令在代码里原样保留，因而不算）。"""
    allowed = {}
    bad = []
    src_lines = re.sub(r"\r\n?| | ", "\n", source).split("\n")
    code_lines = code.split("\n")
    for idx, line in enumerate(src_lines):
        m = DISABLE_RE.search(line)
        if not m:
            continue
        if idx < len(code_lines) and "couli-style-disable-next-line" in code_lines[idx]:
            continue  # 在字符串里
        lineno = idx + 1
        body = m.group(1)
        if "--" in body:
            rules_text, reason = body.split("--", 1)
        else:
            rules_text, reason = body, ""
        rules = [r for r in re.split(r"[\s,]+", rules_text.strip()) if r]
        if REASON_REQUIRED and not reason.strip():
            bad.append((lineno, "豁免注释缺少理由（写成 `-- <理由>`），该豁免不生效"))
            continue
        if not rules:
            bad.append((lineno, "豁免注释没有点名规则"))
            continue
        for r in rules:
            # 只有 no-hex-color / no-numeric-style 可豁免；点名其他规则（含 D10-901 撤回的 design-system-required/<控件>）且写了理由的：
            # 不报、也不豁免任何东西
            if exemptable(r):
                allowed.setdefault(lineno + 1, set()).add(r)
    return allowed, bad


REASON_REQUIRED = True


def analyze(rel, source, lexed):
    """单文件：返回 [(规则, 行号, 说明)]。"""
    code = lexed["code"]
    toks = tokenize(code)
    starts = [0] + [m.end() for m in re.finditer("\n", code)]

    def line(i):
        return bisect.bisect_right(starts, toks[i][2])

    # 与解析器核对字符串：记号切分错了（如把除号当正则）就不猜，以 4 失败。
    # 鸿蒙 SDK 解析器会把 @kit.* 的命名导入展开成底层模块（@kit.ArkUI → @ohos.arkui.node 等合成节点，quote 不是引号字符，原模块名
    # 不再出现）。所以模块名（from / import 之后的字符串）不参与核对：解析器那边去掉合成项与同行同值的模块名，其余逐段比「行号 + 值」。
    mine = []
    modules = []
    for i, (k, t, _) in enumerate(toks):
        if k != "str":
            continue
        if i > 0 and toks[i - 1][0] == "id" and toks[i - 1][1] in ("from", "import"):
            modules.append((line(i), t))
        else:
            mine.append((line(i), t))
    theirs = [(s["line"], s["value"]) for s in lexed["strings"] if s["quote"] in ("'", '"', "`", "}")]
    for m in modules:
        if m in theirs:
            theirs.remove(m)
    if STRING_CROSSCHECK and mine != theirs:
        diff = next(((a, b) for a, b in zip(mine, theirs) if a != b), (mine[len(theirs):] or None, theirs[len(mine):] or None))
        raise Incomplete("记号切分与解析器给出的字符串不一致（%d vs %d 段；首个不同：%r vs %r）" % (len(mine), len(theirs), diff[0], diff[1]))
    hits = []
    for i, msg in hex_color_hits(toks):
        hits.append((HEX, line(i), msg))
    for i, where in numeric_style_hits(toks):
        hits.append((NUM, line(i), "%s 写死字面量 %s；改用 CouliTypography / CouliRadius / CouliSpacing 令牌"
                     % (where, repr(toks[i][1]) if toks[i][0] == "str" else toks[i][1])))
    allowed, bad = parse_exemptions(source, code)
    out = [h for h in hits if h[0] not in allowed.get(h[1], set())]
    out.extend((EXR, ln, msg) for ln, msg in bad)
    return sorted(out, key=lambda h: (h[1], h[0]))


# ---------------------------------------------------------------------------------------------- 范围与扫描
def in_scope_skip(name):
    return name in SKIP_DIR_NAMES


def list_scope(root, incomplete):
    """逐层显式列举范围内的 .ets（相对路径，排序）。列举失败、类型不明、符号链接、特殊文件记 incomplete。"""
    out = []

    def fail(path, why):
        incomplete.append("%s: %s，无法保证扫完" % (os.path.relpath(path, root).replace(os.sep, "/"), why))

    def exists(path):
        try:
            os.lstat(path)
            return True
        except FileNotFoundError:
            return False
        except OSError as e:
            fail(path, "无法查询（%s）" % (e.strerror or e))
            return False

    def scandir(path):
        try:
            with os.scandir(path) as it:
                return sorted(it, key=lambda e: e.name)
        except OSError as e:
            fail(path, "目录无法列举（%s）" % (e.strerror or e))
            return []

    bases = []
    for top, expand, sub in SCOPES:
        topdir = os.path.join(root, top)
        if not exists(topdir):
            continue
        if expand:
            for e in scandir(topdir):
                try:
                    if e.is_symlink():
                        fail(e.path, "是符号链接（不跟随）")
                    elif e.is_dir(follow_symlinks=False):
                        bases.append(os.path.join(e.path, *sub))
                except OSError as err:
                    fail(e.path, "无法确认条目类型（%s）" % (err.strerror or err))
        else:
            bases.append(os.path.join(topdir, *sub))
    for base in bases:
        if not exists(base):
            continue
        # 范围根及其上一层（src）也不得是符号链接（顶层目录与 features/* 在上面已查）
        links = [d for d in (os.path.dirname(base), base) if os.path.islink(d)]
        if links:
            fail(links[0], "是符号链接（不跟随）")
            continue
        stack = [base]
        while stack:
            d = stack.pop()
            for e in scandir(d):
                try:
                    link = e.is_symlink()
                    is_dir = e.is_dir(follow_symlinks=False)
                    is_file = e.is_file(follow_symlinks=False)
                except OSError as err:
                    fail(e.path, "无法确认条目类型（%s）" % (err.strerror or err))
                    continue
                if link:
                    if SYMLINK_FAILS:
                        fail(e.path, "是符号链接（不跟随）")
                elif is_dir:
                    if not in_scope_skip(e.name):
                        stack.append(e.path)
                elif not is_file:
                    fail(e.path, "不是普通文件")
                elif e.name.endswith(SOURCE_SUFFIXES):
                    out.append(os.path.relpath(e.path, root).replace(os.sep, "/"))
    return sorted(set(out))


_LEX_CACHE = {}


def lex_files(items):
    """items: [(相对路径, 源码)]；复用 lint.lex_scan（同一条解析链），按内容缓存（自测反复跑同一批参照件）。"""
    todo = [(rel, src) for rel, src in items if (os.path.basename(rel), src) not in _LEX_CACHE]
    if todo:
        results = lint.lex_scan([(os.path.basename(rel), src) for rel, src in todo])
        for (rel, src), res in zip(todo, results):
            _LEX_CACHE[(os.path.basename(rel), src)] = res
    return [_LEX_CACHE[(os.path.basename(rel), src)] for rel, src in items]


def scan(root):
    """返回 (hits: {规则: {相对路径: [(行, 说明)]}}, 范围内文件集合, incomplete)。工具链不可用抛 lint.HM10ToolchainError。"""
    incomplete = []
    lint.hm10_toolchain()
    files = list_scope(root, incomplete)
    items = []
    for rel in files:
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as f:
                items.append((rel, f.read()))
        except (OSError, UnicodeDecodeError) as e:
            incomplete.append("%s: 源码文件读不出（%s），无法保证扫完" % (rel, e))
    hits = {}
    for (rel, src), res in zip(items, lex_files(items) if items else []):
        if res.get("incomplete"):
            incomplete.append("%s:%d: %s，无法保证扫完" % (rel, res["incomplete"]["line"], res["incomplete"]["reason"]))
            continue
        try:
            found = analyze(rel, src, res)
        except Incomplete as e:
            incomplete.append("%s: %s，无法保证扫完" % (rel, e))
            continue
        for rule, ln, msg in found:
            hits.setdefault(rule, {}).setdefault(rel, []).append((ln, msg))
    return hits, set(files), incomplete


def counts_of(hits):
    return {rule: {rel: len(v) for rel, v in sorted(files.items()) if v} for rule, files in sorted(hits.items()) if files}


def dump_baseline(counts):
    data = {rule: dict(sorted(files.items())) for rule, files in counts.items() if files}
    return json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n"


class BaselineError(Exception):
    pass


def load_baseline(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        raise BaselineError("基线文件不存在：%s（先运行 --write-baseline）" % path)
    except (OSError, UnicodeDecodeError) as e:
        raise BaselineError("基线文件读不出：%s（%s）" % (path, e))
    try:
        data = json.loads(text)
    except ValueError as e:
        raise BaselineError("基线不是合法 JSON：%s（%s）" % (path, e))
    if not isinstance(data, dict):
        raise BaselineError("基线顶层必须是对象：%s" % path)
    for rule, files in data.items():
        if rule not in KNOWN_RULES:
            raise BaselineError("基线里有未知规则 %r" % rule)
        if not isinstance(files, dict):
            raise BaselineError("基线 %s 的值必须是「路径 → 计数」对象" % rule)
        for rel, count in files.items():
            if not isinstance(rel, str) or type(count) is not int or count <= 0:
                raise BaselineError("基线 %s / %r 的计数必须是正整数（实为 %r）" % (rule, rel, count))
    return data


def judge(hits, files, baseline):
    """返回违反输出行。"""
    out = []
    counts = counts_of(hits)
    for rule in sorted(set(counts) | set(baseline)):
        actual = counts.get(rule, {})
        base = baseline.get(rule, {})
        for rel in sorted(set(actual) | set(base)):
            a = actual.get(rel, 0)
            b = base.get(rel, 0)
            if rel in base and rel not in files:
                if CHECK_MISSING:
                    out.append("%s:0: %s 基线里的文件不存在（或已不在范围内）；请从基线删除该条" % (rel, rule))
                continue
            if a > b and CHECK_EXCEED:
                for ln, msg in hits[rule][rel]:
                    out.append("%s:%d: %s %s" % (rel, ln, rule, msg))
                out.append("%s:0: %s 计数 %d 超出基线 %d（只减不增；新增写死样式改用令牌）" % (rel, rule, a, b))
            elif a < b and CHECK_DECREASE:
                if a > 0:
                    out.append("%s:0: %s 计数 %d 少于基线 %d；请把基线降到 %d" % (rel, rule, a, b, a))
                else:
                    out.append("%s:0: %s 计数 0 少于基线 %d；请从基线删除该条" % (rel, rule, b))
    return out


CHECK_EXCEED = True
CHECK_DECREASE = True
CHECK_MISSING = True


def run(root, baseline_path, write):
    """返回退出码；输出打印到 stdout / stderr。"""
    baseline = None
    if not write:
        try:
            baseline = load_baseline(baseline_path)
        except BaselineError as e:
            print("check_hardcoded_style.py：%s" % e, file=sys.stderr)
            return 2
    try:
        hits, files, incomplete = scan(root)
    except lint.HM10ToolchainError as e:
        print("check_hardcoded_style.py：解析工具链不可用（不退化为手写词法）：%s" % e, file=sys.stderr)
        return 3
    if incomplete:
        for line in dict.fromkeys(incomplete):
            print(line)
        print("check_hardcoded_style.py：%d 处无法保证扫完，失败（exit 4）%s" % (len(incomplete), "；未写基线" if write else ""),
              file=sys.stderr)
        return 4
    if write:
        text = dump_baseline(counts_of(hits))
        os.makedirs(os.path.dirname(os.path.abspath(baseline_path)), exist_ok=True)
        with open(baseline_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        total = sum(sum(v.values()) for v in counts_of(hits).values())
        print("check_hardcoded_style.py：已写基线 %s（%d 个文件、%d 处）" % (baseline_path, len(files), total))
        return 0
    problems = judge(hits, files, baseline)
    for p in problems:
        print(p)
    if problems:
        print("check_hardcoded_style.py：%d 行违反（基线 %s）" % (len(problems), baseline_path), file=sys.stderr)
        return 1
    print("check_hardcoded_style.py：0 处违反，计数与基线一致（%d 个文件，%s）" % (len(files), root))
    return 0


# ---------------------------------------------------------------------------------------------- 自测
def _page(body, top=""):
    return (top + "@Entry\n@ComponentV2\nstruct P {\n  build() {\n    Column() {\n"
            + "\n".join("      " + line for line in body.split("\n")) + "\n    }\n  }\n}\n")


_D = "// couli-style-disable-next-line "
_F = "features/home/src/main/ets/"
# 参照件：(相对路径, 源码, 期望计数)
SELF_FILES = [
    (_F + "Hex.ets", _page("Text('a').fontColor('#FF0000')\nText('b').backgroundColor('#CC000000')\nText('c').fontColor(0xFF112233)\n"
                           "Text('d').backgroundColor('rgba(0, 0, 0, 0.5)')\nText('e').fontColor(Color.White)"), {HEX: 5}),
    (_F + "HexClean.ets", _page("Text(R).backgroundColor(Color.Transparent)\n// .fontColor('#FF0000')\nText('Color.White')",
                                top="const R: string = '#/route';\nconst M: number = 0x1F;\n"), {}),
    (_F + "Font.ets", _page("Text('a').fontSize(14)\nText('b').fontSize('14vp')", top="const T: S = { fontSize: 14 };\n"), {NUM: 3}),
    (_F + "Radius.ets", _page("Text('a').borderRadius(8)\nText('b').borderRadius({ topLeft: 8, topRight: 0 })\n"
                              "Text('c').border({ width: 1, radius: 8 })"), {NUM: 3}),
    (_F + "Space.ets", _page("Text('a').padding(8)\nText('b').padding({ top: 6, left: CouliSpacing.space2 })\n"
                             "Text('c').margin({ top: -12 })\nText('d').margin('-4vp')\nRow({ space: 2 }) {\n}"), {NUM: 5}),
    (_F + "NumClean.ets", _page("Text('a').fontSize(0).padding('0vp').margin({ left: '5%' })\nText('b').padding(GAP).fontSize(iconVp(16))\n"
                                "Text('c').shadow({ radius: 8 }).border({ width: { top: 1 } }).width(100)\n"
                                "// .fontSize(14) .padding(8)\nText('.padding(8)')",
                                top="const GAP: number = 6;\ninterface S {\n  fontSize: number\n}\n"), {}),
    # D10-901：点名已撤回的 design-system-required/<控件> 且写了理由的豁免注释，不报、也不豁免任何东西（下一行的控件本身不计）
    (_F + "Ex.ets", _page(_D + "couli-style/no-hex-color -- 渐变端点\nText('a').fontColor('#00000000')\n"
                          + _D + "couli-style/no-hex-color\nText('b').fontColor('#CC000000')\n"
                          + _D + "couli-style/no-numeric-style -- 理由\nText('c')\nText('d').padding(6)\n"
                          + _D + "couli-style/design-system-required/Button -- 点名已撤回的规则\nButton('x')"),
     {HEX: 1, NUM: 1, EXR: 1}),
    # D10-901：系统控件本身不计、不进基线
    (_F + "Ctl.ets", _page("Button('a')\nCheckbox({ name: 'c' })\nLoadingProgress()\nDivider()\nTextInput({ placeholder: 'p' })"), {}),
    ("entry/src/main/ets/E.ets", _page("Text('a').fontSize(13)"), {NUM: 1}),
    ("entry/src/release/ets/R.ets", _page("Text('a').fontColor('#123456')"), {HEX: 1}),
    ("entry/src/staging/ets/S.ets", _page("Text('a').fontColor('#123456')"), {}),
    (_F + "mock/M.ets", _page("Text('a').fontColor('#123456')"), {HEX: 1}),
    ("entry/src/main/ets/build/B.ets", _page("Text('a').fontSize(13)"), {NUM: 1}),
    (_F + "FontObj.ets", _page("Text('a').font({ size: 14, weight: FontWeight.Bold })\nText('b').font({ size: CouliTypography.body.fontSize })\n"
                               "Search().placeholderFont({ size: '14fp' })"), {NUM: 2}),
    (_F + "R2.ets", _page("Text('a').borderRadius({ bottomLeft: 8, bottomRight: 8 })\n"
                          "Text('b').border({ width: 1, radius: { topLeft: 8, bottomRight: 6 } })\nListItemGroup({ space: 8 }) {\n}",
                          top="const T: S = { color: CouliColors.textPrimary, fontSize: 14 };\n"), {NUM: 6}),
    (_F + "Gap.ets", _page("Grid() {\n}\n.columnsGap(8)\n.rowsGap('12vp')\nSwiper() {\n}\n.itemSpace(-2)\n.prevMargin(16)\n.nextMargin(16)\n"
                           "List() {\n}\n.lanes(2, 8)\nGridRow({ columns: 4, gutter: { x: 8, y: 12 } }) {\n}\nGridRow({ gutter: 6 }) {\n}\n"
                           "Tabs() {\n}\n.barGridAlign({ sm: 4, margin: 12, gutter: 8 })\nText('a').safeAreaPadding({ top: 8, bottom: 0 })\n"
                           "Select([{ value: 'a' }])\n  .space(8)\nList() {\n}\n.lanes(3)"), {NUM: 13}),
    (_F + "Div.ets", _page("Text('a')", top="let i: number = 0;\nconst n: number = i++ / Number('#FF0000'.length) / 1;\n"), {HEX: 1}),
    ("common/designsystem/src/main/ets/C.ets", _page("Text('a').fontColor('#123456')"), {}),
]


def _expected_counts():
    out = {}
    for rel, _, want in SELF_FILES:
        for rule, n in want.items():
            out.setdefault(rule, {})[rel] = n
    return out


def _self_scenarios():
    """(说明, 改动的文件 {rel: 源码 | None}, 基线, 期望退出码)。"""
    base = _expected_counts()
    lower = json.loads(json.dumps(base))
    lower[HEX][_F + "Hex.ets"] = 4
    higher = json.loads(json.dumps(base))
    higher[HEX][_F + "Hex.ets"] = 6
    ghost = json.loads(json.dumps(base))
    ghost[NUM][_F + "Gone.ets"] = 1
    return [
        ("参照件 = 基线", {}, base, 0),
        ("超出基线", {}, lower, 1),
        ("少于基线须降", {}, higher, 1),
        ("基线里的文件不存在", {}, ghost, 1),
        ("新文件注入 #123456", {_F + "New.ets": _page("Text('a').fontColor('#123456')")}, base, 1),
        ("范围内符号链接 → 4", {_F + "Link.ets": ("->", "Hex.ets")}, base, 4),
        # 记号切分与解析器不一致（`)` 之后的正则被切成除号，正则里的引号被当成字符串）→ 核对出来以 4 失败，不静默
        ("记号切分不一致 → 4", {_F + "Re.ets": _page("Text('a')", top="function f(s: string): boolean {\n  if (s.length > 0) /'#FF0000'/.test(s);\n"
                                                                     "  return true;\n}\n")}, base, 4),
    ]


def _self_run(files, baseline):
    """在临时树里跑一遍；返回 (counts, 退出码)。"""
    tmp = tempfile.mkdtemp(prefix="couli-style-self-")
    try:
        for rel, src in files.items():
            if src is None:
                continue
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
        return counts_of(hits), (1 if judge(hits, scope, baseline) else 0)
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
    return bad


def _patch(name, value):
    def apply():
        old = globals()[name]
        globals()[name] = value(old) if callable(value) and not isinstance(value, (set, dict, bool)) else value
        return lambda: globals().__setitem__(name, old)
    return apply


# 错误实现：(规则类, 说明, 打补丁)
MUTANTS = [
    (HEX, "#AARRGGBB 漏判（只认 3 / 4 / 6 位）", _patch("HEX_STRING_RE", re.compile(r"#(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6})"))),
    (HEX, "rgba( 漏判", _patch("RGB_STRING_RE", re.compile(r"(?!)"))),
    (HEX, "数字色 0x 漏判", _patch("HEX_NUMBER_RE", re.compile(r"(?!)"))),
    (HEX, "Color.Transparent 也报", _patch("COLOR_ALLOWED", set())),
    (HEX, "Color.* 枚举全放行", _patch("COLOR_ALLOWED", type("All", (set,), {"__contains__": lambda self, x: True})())),
    (NUM, "fontSize 漏判", _patch("STYLE_CALLS", {k: v for k, v in STYLE_CALLS.items() if k != "fontSize"})),
    (NUM, "对象属性 fontSize: 漏判", _patch("FONT_SIZE_PROPERTY", False)),
    (NUM, "borderRadius 角对象漏判", _patch("CORNER_KEYS", set())),
    (NUM, "padding / margin 各边对象漏判", _patch("EDGE_KEYS", set())),
    (NUM, "space: 漏判", _patch("SPACE_CONTAINERS", set())),
    (NUM, "负数（一元负号）漏判", _patch("SIGNED_LITERALS", False)),
    (NUM, "负长度字符串漏判", _patch("LENGTH_STRING_RE", re.compile(r"(?:\d+(?:\.\d*)?|\.\d+)(?:vp|fp|px|lpx)?"))),
    (NUM, "0 也报", _patch("is_length_string", lambda old: (lambda v: bool(LENGTH_STRING_RE.fullmatch(v))))),
    (NUM, "shadow 的 radius 也报", _patch("STYLE_CALLS", dict(STYLE_CALLS, shadow="border"))),
    (EXR, "豁免不要求理由", _patch("REASON_REQUIRED", False)),
    (EXR, "注释里的指令被当成代码以外的整文件豁免",
     _patch("parse_exemptions", lambda old: (lambda s, c: ({ln: set(KNOWN_RULES) for ln in range(1, s.count("\n") + 2)}, [])))),
    ("基线", "超出不失败", _patch("CHECK_EXCEED", False)),
    ("基线", "变少不失败", _patch("CHECK_DECREASE", False)),
    ("基线", "基线里的文件消失不失败", _patch("CHECK_MISSING", False)),
    ("范围", "staging / common / mock 也扫", _patch("SCOPES", [("features", True, ("src", "main")), ("entry", False, ("src",)),
                                                             ("common", True, ("src", "main"))])),
    ("范围", "页面范围内 mock / build 目录被跳过", _patch("SKIP_DIR_NAMES", {"mock", "build"})),
    ("范围", "符号链接静默跳过", _patch("SYMLINK_FAILS", False)),
    (NUM, ".font({ size }) 漏判", _patch("STYLE_CALLS", {k: v for k, v in STYLE_CALLS.items() if k != "font"})),
    (NUM, ".placeholderFont({ size }) 漏判", _patch("STYLE_CALLS", {k: v for k, v in STYLE_CALLS.items() if k != "placeholderFont"})),
    (NUM, "ListItemGroup space 漏判", _patch("SPACE_CONTAINERS", SPACE_CONTAINERS - {"ListItemGroup"})),
    (NUM, "底部两角漏判", _patch("CORNER_KEYS", {"topLeft", "topRight", "topStart", "topEnd"})),
    (NUM, "对象属性 fontSize 只认第一个键", _patch("FONT_SIZE_PROPERTY_ANY_KEY", False)),
    (NUM, "border({ radius: {…} }) 角对象不看", _patch("BORDER_RADIUS_CORNERS", False)),
    ("解析", "去掉记号切分与解析器字符串核对", _patch("STRING_CROSSCHECK", False)),
    (NUM, "columnsGap / rowsGap 漏判", _patch("STYLE_CALLS", {k: v for k, v in STYLE_CALLS.items() if k not in ("columnsGap", "rowsGap")})),
    (NUM, "Swiper itemSpace 漏判", _patch("STYLE_CALLS", {k: v for k, v in STYLE_CALLS.items() if k != "itemSpace"})),
    (NUM, "Swiper prevMargin / nextMargin 漏判",
     _patch("STYLE_CALLS", {k: v for k, v in STYLE_CALLS.items() if k not in ("prevMargin", "nextMargin")})),
    (NUM, "List .lanes gutter 漏判", _patch("STYLE_CALLS", {k: v for k, v in STYLE_CALLS.items() if k != "lanes"})),
    (NUM, ".lanes 列数也报", _patch("STYLE_CALLS", dict(STYLE_CALLS, lanes=()))),
    (NUM, "GridRow gutter 漏判", _patch("GUTTER_CONTAINERS", set())),
    (NUM, "GridRow gutter x / y 漏判", _patch("GUTTER_AXES", set())),
    (NUM, "Tabs barGridAlign margin / gutter 漏判", _patch("BAR_GRID_KEYS", set())),
    (NUM, "safeAreaPadding 漏判", _patch("STYLE_CALLS", {k: v for k, v in STYLE_CALLS.items() if k != "safeAreaPadding"})),
    (NUM, "Select .space 漏判", _patch("STYLE_CALLS", {k: v for k, v in STYLE_CALLS.items() if k != "space"})),
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
    print("check_hardcoded_style.py 自测：参照件 + %d 个错误实现，%d 项失败" % (len(MUTANTS), failed))
    return 1 if failed else 0


# ---------------------------------------------------------------------------------------------- 入口
def main(argv):
    parser = argparse.ArgumentParser(prog="check_hardcoded_style.py", description="页面层写死样式基线检查（LINT-STYLE-harmony）")
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
        print("check_hardcoded_style.py：--root 不是目录：%s" % root, file=sys.stderr)
        return 2
    baseline = os.path.abspath(args.baseline or os.path.join(root, *BASELINE_REL.split("/")))
    return run(root, baseline, args.write_baseline)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
