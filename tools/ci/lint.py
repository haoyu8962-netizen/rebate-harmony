#!/usr/bin/env python3
"""项目自有静态规则（只用 Python 3 标准库）。codelinter 管通用规则，这里管凑狸自己的硬规则。

用法：
    python3 tools/ci/lint.py                 # 检查仓库
    python3 tools/ci/lint.py --root <目录>    # 检查另一个目录（verify.sh 用它证明 lint-fixtures 会被拦）

规则（命中任一即退出 1，每行输出带规则号）：
    HM-LINT-1 no-cjk-in-features   features/ 下 .ets 的字符串字面量含中日韩字符（BR-TEXT-12：文案经字典取键）
    HM-LINT-2 no-v1-decorators     出现 V1 状态管理装饰器（只用 V2：@ComponentV2、@Local、@Param、@ObservedV2、@Trace …）
    HM-LINT-3 no-router            import 了 @ohos.router，或从 @kit.ArkUI 导入 router（导航只用 Navigation + NavPathStack）
    HM-LINT-4 sdk-init-in-privacy  第三方 SDK 初始化调用出现在 PrivacyGate.ets 以外（03 §4.1）
    HM-LINT-5 no-feature-deps      feature 的 oh-package.json5 依赖或 import 了另一个 feature
    HM-LINT-6 webview-containers   CSB-10 / CSB-03：ExternalWebView.ets 出现注入脚本、样式或消息通道的调用；或在 features/web 的
                                   两个容器封装之外创建 Web 组件
    HM-LINT-7 webview-no-external  APP-04 R1-09：两类容器（features/web）与 App 的桥接线（entry/src/main/ets/web）里拉起外部
                                   应用或系统浏览器（openLink、startAbility*）。API 20 不能保证 https 只交给系统浏览器（已注册
                                   App Linking 的应用会被优先拉起），所以容器不提供「在浏览器打开」出口
    HM-LINT-8 webview-system-back  APP-04 R1-11：entry/src/main 里承载 TrustedWebView / ExternalWebView 的文件，每个容器都要有
                                   NavDestination.onBackPressed 把系统返回交给容器（网页有历史时先后退）
    HM-LINT-9 webview-navbar-size  APP-04 R4-01：TrustedWebView.ets 的标题栏 navBar() 里不得出现 Image 组件或百分比高度。
                                   标题栏只有最小高度，百分比高度会参照整页、把标题栏撑满并挤掉 layoutWeight(1) 的网页区域；
                                   背景图只能用 backgroundImage 等背景属性（不参与尺寸测量）
    HM-LINT-10 debug-mock-gate     F-X-02：entry/src/staging 里只有 DebugFakeServer.ets 能读 DebugFakeServer.enabled。其余调试替身
                                   一律经 DebugFakeServer.mockGate（假服务打开 且 当前环境允许 MOCK_DATA，每次使用时重新判断），
                                   切到 prod 后不给假数据。FU-HM-0711b R1-06、R2-03：按词法检查真实的属性访问（HM10Lexer 去掉注释、
                                   字符串内容与正则字面量，模板字符串 ${} 里的表达式按同一套规则递归扫描，其中的字符串、注释、
                                   嵌套模板与花括号都正确配对），认导入别名（import { DebugFakeServer as X }、import * as NS）、
                                   局部别名（const X = DebugFakeServer）、可选链、方括号取值与解构；`--self-test-hm10` 跑正反例
"""

import json
import os
import re
import sys

FEATURES = ["home", "search", "product", "agent", "orders", "wallet", "me", "auth", "web"]
SCAN_DIRS = ["entry", "common", "features"]
SKIP_DIRS = {"oh_modules", "node_modules", "build", ".hvigor", ".test", ".preview", "ohosTest", "mock"}

CJK = re.compile(r"[　-〿㐀-䶿一-鿿豈-﫿＀-￯]")
V1_DECORATORS = [
    "Component", "State", "Prop", "Link", "Observed", "ObjectLink", "Provide", "Consume",
    "StorageLink", "StorageProp", "LocalStorageLink", "LocalStorageProp", "Watch", "Track",
]
V1_RE = re.compile(r"@(%s)(?![A-Za-z0-9_])" % "|".join(V1_DECORATORS))
ROUTER_MODULE_RE = re.compile(r"""(?:from\s+|import\s*\(\s*|require\s*\(\s*|import\s+)['"]@ohos\.router['"]""")
KIT_ARKUI_IMPORT_RE = re.compile(r"""import\s*\{([^}]*)\}\s*from\s*['"]@kit\.ArkUI['"]""", re.S)
SDK_INIT_RE = re.compile(
    r"\b(MobPush\w*|AGConnect\w*|WXApi\w*|AlibcTrade\w*|Alibc\w*Sdk|Sentry\w*|JPush\w*|UMConfigure|UMeng\w*)"
    r"\s*\.\s*(init\w*|register\w*|setup\w*|start\w*|asyncInit\w*|configure\w*)\s*\(")
EXTERNAL_INJECTION_RE = re.compile(
    r"\b(javaScriptProxy|registerJavaScriptProxy|javaScriptOnDocumentStart|javaScriptOnDocumentEnd|"
    r"runJavaScriptOnDocumentStart|runJavaScriptOnDocumentEnd|runJavaScriptOnHeadEnd|runJavaScript|runJavaScriptExt|"
    r"createWebMessagePorts|postMessage|injectOfflineResources|setStyle)\s*\(")
WEB_COMPONENT_RE = re.compile(r"(?<![A-Za-z0-9_.])Web\s*\(\s*\{")
WEB_CONTAINER_FILES = {"features/web/src/main/ets/TrustedWebView.ets", "features/web/src/main/ets/ExternalWebView.ets"}
EXTERNAL_LAUNCH_RE = re.compile(r"\b(openLink|startAbility\w*)\s*\(")
WEB_CONTAINER_USE_RE = re.compile(r"(?<![A-Za-z0-9_.])(TrustedWebView|ExternalWebView)\s*\(\s*\{")
BACK_PRESSED_RE = re.compile(r"\.onBackPressed\s*\(")
NAVBAR_BUILDER_RE = re.compile(r"(?<![A-Za-z0-9_.])navBar\s*\(\s*\)\s*\{")
NAVBAR_FORBIDDEN_RE = re.compile(
    r"(?<![A-Za-z0-9_.])(Image\s*\(|\.\s*height\s*\(\s*['\"]\s*[0-9.]+\s*%\s*['\"]\s*\))")
FAKE_FLAG_CLASS = "DebugFakeServer"
FAKE_FLAG_OWNER = "entry/src/staging/ets/variant/DebugFakeServer.ets"
IDENT = r"[A-Za-z_$][A-Za-z0-9_$]*"
NAMED_IMPORT_RE = re.compile(r"\bimport\s+(?:type\s+)?\{([^}]*)\}\s*from\s*(['\"])([^'\"]*)\2")
NAMESPACE_IMPORT_RE = re.compile(r"\bimport\s+\*\s+as\s+(" + IDENT + r")\s+from\s*(['\"])([^'\"]*)\2")
IMPORT_FROM_RE = re.compile(r"""\bfrom\s*['"]([^'"]+)['"]|\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)""")


def strip_comments_keep_strings(src):
    """去掉 // 与 /* */ 注释，保留字符串字面量；返回 (代码, [(行号, 引号, 内容)])。"""
    out = []
    strings = []
    i, n, line = 0, len(src), 1
    while i < n:
        ch = src[i]
        if ch == "\n":
            line += 1
            out.append(ch)
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            line += src.count("\n", i, j)
            out.append("\n" * src.count("\n", i, j))
            i = j
        elif ch in ("'", '"', "`"):
            start_line = line
            j = i + 1
            buf = []
            while j < n and src[j] != ch:
                if src[j] == "\\" and j + 1 < n:
                    buf.append(src[j:j + 2])
                    j += 2
                    continue
                if src[j] == "\n":
                    line += 1
                buf.append(src[j])
                j += 1
            content = "".join(buf)
            strings.append((start_line, ch, content))
            out.append(ch + content + ch)
            i = j + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out), strings


REGEX_PREV_KEYWORDS = {"return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do",
                       "else", "yield", "await"}
# 控制语句关键字：其后括号配对的右括号之后是语句开头，`/` 是正则（F-HM-29）。
CONTROL_PAREN_KEYWORDS = {"if", "while", "for", "with"}
# 记号之后 `/` 开始正则的多字符记号：控制语句右括号、块结束右花括号、箭头、case / default 标签的冒号（F-HM-29）。
REGEX_PREV_MARKS = {"ctrl)", "block}", "=>", "label:"}
# 记号之后的 `{` 是语句块（不是对象字面量）：开头、语句边界、右括号、箭头、标识符 / 关键字（class X {、try {、else {）、
# case / default 标签的冒号（F-HM-29 第 1 轮修复）、返回类型结尾的 `]` / `>`（`): number[] {`、`): Promise<void> {`；表达式里
# `]` / `>` 之后不会紧跟对象字面量）。
BLOCK_BRACE_PREV = {"", ";", "{", "}", "block}", ")", "ctrl)", "=>", "id", "else", "do", "label:", "]", ">"}


class HM10Lexer:
    """HM-LINT-10 用的词法扫描（FU-HM-0711b R2-03）：在原始源码上一次扫完，输出两份与源码逐字对齐的视图——
    plain：注释、字符串内容、正则字面量内容、模板字符串文本都换成空格（换行保留），模板 `${}` 里的表达式按同一套规则
    递归扫描（其中的字符串、注释、正则、嵌套模板与花括号都正确配对）；kept：同上但保留字符串内容（找导入路径用）。
    另记下内容恰好是 enabled 的字符串字面量起点（方括号取值 X['enabled']）。正则与除号按前一个有效记号区分。"""

    def __init__(self, src):
        self.src = src
        self.n = len(src)
        self.plain = list(src)
        self.kept = list(src)
        self.enabled_strings = set()

    def blank(self, a, b, keep=False):
        for k in range(a, min(b, self.n)):
            if self.src[k] != "\n":
                self.plain[k] = " "
                if not keep:
                    self.kept[k] = " "

    def run(self):
        self.code(0, top=True)
        return "".join(self.plain), "".join(self.kept), self.enabled_strings

    def code(self, i, top=False):
        """扫一段代码，直到与入口配对的 `}`（模板表达式）或源码结束；返回结束位置（`}` 之后）。
        F-HM-29（FU-HM-0711b R3-02）：补齐三种词法状态——控制语句（if / while / for / with）括号配对的右括号之后、
        语句块结束的 `}` 之后是语句开头，`/` 开始正则；后缀 `++` / `--` 之后是操作数结束，`/` 是除号。
        F-HM-29 第 1 轮修复（R1-02）：`.` / `?.` 之后的关键字是成员名（obj.if(a) 不是控制语句）；模板 `${` 入口之后是表达式
        上下文（其中的 `{` 是对象字面量）；case / default 标签冒号之后是语句开头（其后的 `{` 是语句块）。"""
        src, n = self.src, self.n
        parens = []  # 每层圆括号是否属于控制语句
        braces = []  # 每层花括号是否是语句块（False：对象字面量等表达式）
        # 前一个有效记号：""（开头）、标点字符、"id"（标识符 / 数字 / 字面量）、关键字本身或 REGEX_PREV_MARKS。
        # 模板表达式入口（top=False）按左圆括号之后处理：表达式开头，`/` 是正则，`{` 是对象字面量。
        prev = "" if top else "("
        case_label = False  # 读到 case / default，等它的标签冒号
        ternary = 0  # case 表达式里未配对的 `?`（其 `:` 不是标签冒号）
        while i < n:
            ch = src[i]
            if ch in " \t\r\n":
                i += 1
            elif src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j < 0 else j
                self.blank(i, j)
                i = j
            elif src.startswith("/*", i):
                j = src.find("*/", i + 2)
                j = n if j < 0 else j + 2
                self.blank(i, j)
                i = j
            elif ch in ("'", '"'):
                i = self.string(i)
                prev = "id"
            elif ch == "`":
                i = self.template(i)
                prev = "id"
            elif ch == "/":
                if prev == "" or prev in REGEX_PREV_KEYWORDS or prev in REGEX_PREV_MARKS \
                        or (len(prev) == 1 and prev not in ")]}"):
                    i = self.regex(i)
                    prev = "id"
                else:
                    i += 1
                    prev = "/"
            elif ch == "(":
                parens.append(prev in CONTROL_PAREN_KEYWORDS)
                i += 1
                prev = "("
            elif ch == ")":
                control = parens.pop() if parens else False
                i += 1
                prev = "ctrl)" if control else ")"
            elif ch == "{":
                braces.append(prev in BLOCK_BRACE_PREV)
                i += 1
                prev = "{"
            elif ch == "}":
                if not braces and not top:
                    return i + 1
                block = braces.pop() if braces else True
                i += 1
                prev = "block}" if block else "}"
            elif src.startswith("++", i) or src.startswith("--", i):
                # 前面是操作数（标识符、字面量、右括号 / 右方括号）：后缀，之后的 `/` 是除号；否则是前缀运算符。
                i += 2
                prev = "id" if prev in ("id", ")", "]") else ch
            elif src.startswith("=>", i):
                i += 2
                prev = "=>"
            elif ch.isalnum() or ch in "_$" or ord(ch) > 127:
                j = i
                while j < n and (src[j].isalnum() or src[j] in "_$" or ord(src[j]) > 127):
                    j += 1
                word = src[i:j]
                if prev == ".":
                    # 成员名（obj.if、a?.case）：不是关键字。
                    prev = "id"
                else:
                    prev = word if word in REGEX_PREV_KEYWORDS or word in CONTROL_PAREN_KEYWORDS else "id"
                    if word == "case" or (word == "default" and src[j:].lstrip(" \t\r\n").startswith(":")):
                        case_label = True
                        ternary = 0
                i = j
            elif case_label and ch == "?" and not src.startswith("?.", i) and not src.startswith("??", i):
                ternary += 1
                prev = ch
                i += 1
            elif case_label and ch == ":":
                if ternary > 0:
                    ternary -= 1
                    prev = ch
                else:
                    case_label = False
                    prev = "label:"
                i += 1
            elif src.startswith("?.", i) and not src[i + 2:i + 3].isdigit():
                # 可选链：之后是成员名（a?.if）或调用 / 下标。
                i += 2
                prev = "."
            else:
                prev = ch
                i += 1
        return n

    def string(self, i):
        src, n, q = self.src, self.n, self.src[i]
        j = i + 1
        escaped = False
        while j < n and src[j] != q and src[j] != "\n":
            if src[j] == "\\":
                escaped = True
                j += 2
                continue
            j += 1
        if not escaped and src[i + 1:j] == "enabled":
            self.enabled_strings.add(i)
        self.blank(i + 1, j, keep=True)
        return j + 1 if j < n and src[j] == q else j

    def template(self, i):
        src, n = self.src, self.n
        j = i + 1
        text_start = j
        simple = True
        while j < n and src[j] != "`":
            if src[j] == "\\":
                simple = False
                j += 2
            elif src.startswith("${", j):
                simple = False
                self.blank(text_start, j, keep=True)
                j = self.code(j + 2)
                text_start = j
            else:
                j += 1
        if simple and src[i + 1:j] == "enabled":
            self.enabled_strings.add(i)
        self.blank(text_start, j, keep=True)
        return j + 1

    def regex(self, i):
        src, n = self.src, self.n
        j = i + 1
        in_class = False
        while j < n and src[j] != "\n":
            c = src[j]
            if c == "\\":
                j += 2
                continue
            if c == "[":
                in_class = True
            elif c == "]":
                in_class = False
            elif c == "/" and not in_class:
                break
            j += 1
        self.blank(i + 1, j)
        j += 1
        while j < n and (src[j].isalnum() or src[j] in "_$"):
            j += 1
        return j


def fake_flag_reads(src):
    """HM-LINT-10：返回读 DebugFakeServer.enabled 的位置（src 为原始源码；位置与 src 对齐）。"""
    plain, kept, enabled_strings = HM10Lexer(src).run()
    names = {FAKE_FLAG_CLASS}
    spaces = set()
    for m in NAMED_IMPORT_RE.finditer(kept):
        if not m.group(3).rstrip("/").endswith(FAKE_FLAG_CLASS):
            continue
        for part in m.group(1).split(","):
            bits = part.strip().split()
            if len(bits) == 3 and bits[0] == FAKE_FLAG_CLASS and bits[1] == "as":
                names.add(bits[2])
    for m in NAMESPACE_IMPORT_RE.finditer(kept):
        if m.group(3).rstrip("/").endswith(FAKE_FLAG_CLASS):
            spaces.add(m.group(1))
    # 局部别名：const X = DebugFakeServer; / const X: typeof DebugFakeServer = NS.DebugFakeServer;（可连锁）
    changed = True
    while changed:
        changed = False
        refs = "|".join([re.escape(x) for x in sorted(names)]
                        + [re.escape(x) + r"\s*\.\s*" + FAKE_FLAG_CLASS for x in sorted(spaces)])
        for m in re.finditer(r"\b(?:const|let|var)\s+(" + IDENT + r")\s*(?::[^=;]+)?=\s*(?:" + refs + r")\s*[;\n)]",
                             plain):
            if m.group(1) not in names:
                names.add(m.group(1))
                changed = True
    refs = "|".join([re.escape(x) for x in sorted(names)]
                    + [re.escape(x) + r"\s*\.\s*" + FAKE_FLAG_CLASS for x in sorted(spaces)])
    hits = []
    access = re.compile(r"(?<![A-Za-z0-9_$.])(?:" + refs + r")\s*(?:\?\.|\.)\s*enabled(?![A-Za-z0-9_$])")
    hits.extend(m.start() for m in access.finditer(plain))
    # 方括号取值：X['enabled'] / X?.["enabled"] / X[`enabled`]（键名必须是内容恰好为 enabled 的字符串字面量）
    bracket = re.compile(r"(?<![A-Za-z0-9_$.])(?:" + refs + r")\s*(?:\?\.)?\s*\[\s*(['\"`]) {7}\1\s*\]")
    hits.extend(m.start() for m in bracket.finditer(plain) if m.start(1) in enabled_strings)
    # 解构：const { enabled } = X; / const { enabled: on } = X;
    destructure = re.compile(r"\{[^{}]*(?<![A-Za-z0-9_$])enabled(?![A-Za-z0-9_$])[^{}]*\}\s*=\s*(?:" + refs
                             + r")(?![A-Za-z0-9_$])")
    hits.extend(m.start() for m in destructure.finditer(plain))
    return sorted(set(hits))


HM10_CASES = [
    # (说明, 源码, 应报的个数)
    ("直接读", "const a = DebugFakeServer.enabled;", 1),
    ("可选链", "const a = DebugFakeServer?.enabled;", 1),
    ("跨行", "const a = DebugFakeServer\n  .enabled;", 1),
    ("导入别名", "import { DebugFakeServer as Fake } from './DebugFakeServer';\nconst a = Fake.enabled;", 1),
    ("多个导入里的别名", "import { DEBUG_FAKE_SERVER_KEY, DebugFakeServer as F } from 'entry/ets/variant/DebugFakeServer';\n"
                  "if (F.enabled) {}", 1),
    ("命名空间导入", "import * as S from './DebugFakeServer';\nconst a = S.DebugFakeServer.enabled;", 1),
    ("局部别名", "const Srv = DebugFakeServer;\nconst a = Srv.enabled;", 1),
    ("方括号取值", "const a = DebugFakeServer['enabled'];", 1),
    ("解构", "const { enabled } = DebugFakeServer;", 1),
    ("模板字符串里的表达式", "const a = `x${DebugFakeServer.enabled ? 1 : 0}`;", 1),
    ("普通字符串（反例）", "const a = 'DebugFakeServer.enabled';", 0),
    ("双引号字符串（反例）", 'log("see DebugFakeServer.enabled");', 0),
    ("模板字符串文本（反例）", "const a = `DebugFakeServer.enabled`;", 0),
    ("行注释（反例）", "// DebugFakeServer.enabled\nconst a = 1;", 0),
    ("块注释（反例）", "/* DebugFakeServer.enabled */ const a = 1;", 0),
    ("mockGate（反例）", "const a = DebugFakeServer.mockGate();", 0),
    ("别的类的 enabled（反例）", "const a = this.enabled; const b = other.enabled; const c = Fake.enabled;", 0),
    ("别名来自别的模块（反例）", "import { DebugFakeServer as Fake } from './Elsewhere';\nconst a = Fake.enabled;", 0),
    ("前缀相近的名字（反例）", "const a = MyDebugFakeServer.enabled; const b = x.DebugFakeServer.enabled;", 0),
    ("组件属性（反例）", "Button('x').enabled(true)", 0),
    # FU-HM-0711b R2-03：评审给出的三例与同类情形
    ("正则字面量（反例）", "const r = /DebugFakeServer.enabled/;", 0),
    ("模板表达式里的块注释（反例）", "const a = `${ /* DebugFakeServer.enabled */ 1 }`;", 0),
    ("模板表达式里字符串含右花括号", "const a = `${ '}' + DebugFakeServer.enabled }`;", 1),
    ("return 之后的正则（反例）", "function f(s: string) { return /DebugFakeServer.enabled/.test(s); }", 0),
    ("字符类里有斜杠的正则（反例）", "const r = /[/]DebugFakeServer.enabled/g;", 0),
    ("除号不是正则", "const a = x / DebugFakeServer.enabled / 2;", 1),
    ("模板表达式里的行注释（反例）", "const a = `${ 1 // DebugFakeServer.enabled\n}`;", 0),
    ("嵌套模板", "const a = `${ `${DebugFakeServer.enabled}` }`;", 1),
    ("模板表达式里的花括号嵌套", "const a = `${ ({ k: 1 }).k + (DebugFakeServer.enabled ? 1 : 0) }`;", 1),
    ("模板表达式结束后的文本（反例）", "const a = `${ '${' } DebugFakeServer.enabled`;", 0),
    ("模板文本里有引号", "const a = `it's ${DebugFakeServer.enabled}`;", 1),
    ("模板字符串键名的方括号取值", "const a = DebugFakeServer[`enabled`];", 1),
    ("字符串里的方括号形式（反例）", "const a = \"DebugFakeServer['enabled']\";", 0),
    # F-HM-29（FU-HM-0711b R3-02）：评审给出的两例与同类情形
    ("if 右括号之后的正则（反例）", "if (ready) /DebugFakeServer.enabled/.test(s);", 0),
    ("后缀 ++ 之后的除号", "const x = count++ / (DebugFakeServer.enabled ? 1 : 2) / 2;", 1),
    ("后缀 -- 之后的除号", "const x = count-- / (DebugFakeServer.enabled ? 1 : 2);", 1),
    ("while 右括号之后的正则（反例）", "while (more()) /DebugFakeServer.enabled/g.exec(s);", 0),
    ("for 右括号之后的正则（反例）", "for (const s of list) /DebugFakeServer.enabled/.test(s);", 0),
    ("with 右括号之后的正则（反例）", "with (o) /DebugFakeServer.enabled/.test(s);", 0),
    ("块结束之后的正则（反例）", "if (a) { b(); }\n/DebugFakeServer.enabled/.test(s);", 0),
    ("函数体结束之后的正则（反例）", "function f() {}\n/DebugFakeServer.enabled/.test(s);", 0),
    ("对象字面量结束之后的除号", "const a = { k: 1 } / DebugFakeServer.enabled / 2;", 1),
    ("普通调用右括号之后的除号", "const a = f(x) / DebugFakeServer.enabled / 2;", 1),
    ("if 条件里调用的右括号之后的除号", "if (f(x) / DebugFakeServer.enabled) {}", 1),
    ("前缀 ++ 之后仍是操作数开头", "const a = ++i / DebugFakeServer.enabled;", 1),
    ("箭头之后的正则（反例）", "const t = (s: string) => /DebugFakeServer.enabled/.test(s);", 0),
    # F-HM-29 第 1 轮修复（R1-02）：评审给出的四例（前两例是真实读取，必须报出；后两例是正则，不得误报）与同类情形
    ("成员名 if 的调用之后的除号", "const x = obj.if(a) / (DebugFakeServer.enabled ? 1 : 2) / 2;", 1),
    ("模板表达式里对象字面量之后的除号", "const x = `${{a: 1} / DebugFakeServer.enabled / 2}`;", 1),
    ("case 标签之后语句块结束的正则（反例）", "switch (a) { case 1: {} /DebugFakeServer.enabled/.test(b); }", 0),
    ("数组返回类型的函数体结束之后的正则（反例）",
     "function f(): number[] { return []; }\n/DebugFakeServer.enabled/.test(s);", 0),
    ("可选链成员名 while 的调用之后的除号", "const x = obj?.while(a) / DebugFakeServer.enabled / 2;", 1),
    ("模板入口直接是正则（反例）", "const x = `${/DebugFakeServer.enabled/.test(s)}`;", 0),
    ("default 标签之后语句块结束的正则（反例）", "switch (a) { default: {} /DebugFakeServer.enabled/.test(b); }", 0),
    ("case 表达式含三元之后的块（反例）", "switch (a) { case b ? 1 : 2: {} /DebugFakeServer.enabled/.test(b); }", 0),
    ("case 里对象字面量之后的除号", "switch (a) { case 1: x = {k: 1} / DebugFakeServer.enabled; }", 1),
    ("泛型返回类型的函数体结束之后的正则（反例）",
     "function f(): Promise<void> { return p; }\n/DebugFakeServer.enabled/.test(s);", 0),
    ("模板表达式里调用之后的除号", "const x = `${f(a) / DebugFakeServer.enabled}`;", 1),
]


def self_test_hm10():
    failed = 0
    for title, src, want in HM10_CASES:
        got = len(fake_flag_reads(src))
        ok = got == want
        failed += 0 if ok else 1
        print("  %s %s：应报 %d，实报 %d" % ("PASS" if ok else "FAIL", title, want, got))
    print("HM-LINT-10 自测：%d 例，%d 例失败" % (len(HM10_CASES), failed))
    return 1 if failed else 0


def ets_files(root):
    for top in SCAN_DIRS:
        base = os.path.join(root, top)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, names in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in names:
                if name.endswith(".ets") or name.endswith(".ts"):
                    yield os.path.join(dirpath, name)


def line_of(code, pos):
    return code.count("\n", 0, pos) + 1


def block_end(code, start):
    """start 是某个 { 之后的位置；返回与之配对的 } 的位置（字符串字面量里的括号不计，注释已去掉）。"""
    depth, i, n = 1, start, len(code)
    while i < n:
        ch = code[i]
        if ch in ("'", '"', "`"):
            j = i + 1
            while j < n and code[j] != ch:
                j += 2 if code[j] == "\\" else 1
            i = j + 1
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def load_json5(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    code, _ = strip_comments_keep_strings(text)
    code = re.sub(r",(\s*[}\]])", r"\1", code)
    return json.loads(code)


def lint(root):
    problems = []

    def report(rule, path, line, msg):
        problems.append("%s:%d: %s %s" % (os.path.relpath(path, root), line, rule, msg))

    for path in ets_files(root):
        with open(path, encoding="utf-8") as f:
            src = f.read()
        code, strings = strip_comments_keep_strings(src)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        in_feature = rel.startswith("features/")

        if in_feature:
            for line, _, content in strings:
                if CJK.search(content):
                    report("HM-LINT-1", path, line, "features/ 的字符串字面量含中文，文案经字典取键（BR-TEXT-12）")

        for m in V1_RE.finditer(code):
            report("HM-LINT-2", path, line_of(code, m.start()), "V1 装饰器 @%s；只用状态管理 V2" % m.group(1))

        for m in ROUTER_MODULE_RE.finditer(code):
            report("HM-LINT-3", path, line_of(code, m.start()), "使用 @ohos.router；导航只用 Navigation + NavPathStack")
        for m in KIT_ARKUI_IMPORT_RE.finditer(code):
            names = [x.strip().split(" as ")[0].strip() for x in m.group(1).split(",")]
            if "router" in names:
                report("HM-LINT-3", path, line_of(code, m.start()), "从 @kit.ArkUI 导入 router；导航只用 Navigation + NavPathStack")

        if os.path.basename(path) != "PrivacyGate.ets":
            for m in SDK_INIT_RE.finditer(code):
                report("HM-LINT-4", path, line_of(code, m.start()),
                       "第三方 SDK 初始化 %s.%s 只能写在 PrivacyGate.onConsented()" % (m.group(1), m.group(2)))

        if os.path.basename(path) == "ExternalWebView.ets":
            for m in EXTERNAL_INJECTION_RE.finditer(code):
                report("HM-LINT-6", path, line_of(code, m.start()),
                       "ExternalWebView 不得注入脚本、样式或消息通道：%s（CSB-10）" % m.group(1))
        if rel not in WEB_CONTAINER_FILES:
            for m in WEB_COMPONENT_RE.finditer(code):
                report("HM-LINT-6", path, line_of(code, m.start()),
                       "Web 组件只能在 features/web 的 TrustedWebView / ExternalWebView 封装里创建（CSB-03）")

        if rel.startswith("features/web/") or rel.startswith("entry/src/main/ets/web/"):
            for m in EXTERNAL_LAUNCH_RE.finditer(code):
                report("HM-LINT-7", path, line_of(code, m.start()),
                       "WebView 容器与桥接线不得拉起外部应用或系统浏览器：%s（R1-09）" % m.group(1))

        if rel == "features/web/src/main/ets/TrustedWebView.ets":
            m = NAVBAR_BUILDER_RE.search(code)
            if m is None:
                report("HM-LINT-9", path, 1, "找不到标题栏 navBar() 构建函数，无法检查标题栏尺寸（R4-01）")
            else:
                body_start = m.end()
                end = block_end(code, body_start)
                for hit in NAVBAR_FORBIDDEN_RE.finditer(code, body_start, end):
                    report("HM-LINT-9", path, line_of(code, hit.start()),
                           "标题栏 navBar() 里出现 %s：百分比高度或 Image 会把标题栏撑满整页、挤掉网页；背景图用 backgroundImage（R4-01）"
                           % hit.group(1).strip())

        if rel.startswith("entry/src/main/"):
            uses = len(WEB_CONTAINER_USE_RE.findall(code))
            backs = len(BACK_PRESSED_RE.findall(code))
            if uses > backs:
                report("HM-LINT-8", path, 1,
                       "承载 WebView 容器的页面要用 NavDestination.onBackPressed 把系统返回交给容器（%d 个容器、%d 处 onBackPressed，R1-11）"
                       % (uses, backs))

        if rel.startswith("entry/src/staging/") and rel != FAKE_FLAG_OWNER:
            for pos in fake_flag_reads(src):
                report("HM-LINT-10", path, line_of(src, pos),
                       "调试替身直接读了 DebugFakeServer.enabled；改用 DebugFakeServer.mockGate（含当前环境 MOCK_DATA 闸门，F-X-02）")

        if in_feature:
            own = rel.split("/")[1]
            for m in IMPORT_FROM_RE.finditer(code):
                spec = m.group(1) or m.group(2)
                pkg = spec.split("/")[0]
                if pkg in FEATURES and pkg != own:
                    report("HM-LINT-5", path, line_of(code, m.start()), "feature %s import 了 feature %s" % (own, pkg))

    for feature in FEATURES:
        pkg = os.path.join(root, "features", feature, "oh-package.json5")
        if not os.path.isfile(pkg):
            continue
        data = load_json5(pkg)
        for section in ("dependencies", "devDependencies", "dynamicDependencies"):
            for dep, value in (data.get(section) or {}).items():
                target = str(value)
                hits = [f for f in FEATURES if f != feature and
                        (dep == f or re.search(r"(^|[/\\])features[/\\]%s([/\\]|$)" % re.escape(f), target))]
                for other in hits:
                    report("HM-LINT-5", pkg, 1, "feature %s 的 %s 依赖了 feature %s（%s）" % (feature, section, other, dep))
    return problems


def main(argv):
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    args = argv[1:]
    if args == ["--self-test-hm10"]:
        return self_test_hm10()
    if args[:1] == ["--root"] and len(args) == 2:
        root = os.path.abspath(args[1])
    elif args:
        print("用法：lint.py [--root <目录>] | --self-test-hm10", file=sys.stderr)
        return 2
    problems = lint(root)
    for p in problems:
        print(p)
    if problems:
        print("lint.py：%d 处违反项目规则" % len(problems), file=sys.stderr)
        return 1
    print("lint.py：0 处违反（%s）" % root)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
