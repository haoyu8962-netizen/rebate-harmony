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
    if args[:1] == ["--root"] and len(args) == 2:
        root = os.path.abspath(args[1])
    elif args:
        print("用法：lint.py [--root <目录>]", file=sys.stderr)
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
