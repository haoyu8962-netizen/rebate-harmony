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
