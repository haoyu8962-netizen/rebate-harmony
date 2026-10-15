#!/usr/bin/env python3
"""项目自有静态规则（Python 3 标准库；HM-LINT-10 另用 node + typescript，见下）。codelinter 管通用规则，这里管凑狸自己的硬规则。

用法：
    python3 tools/ci/lint.py                 # 检查仓库
    python3 tools/ci/lint.py --root <目录>    # 检查另一个目录（verify.sh 用它证明 lint-fixtures 会被拦）
    python3 tools/ci/lint.py --self-test-hm10 # HM-LINT-10 正反例自测
    python3 tools/ci/lint.py --hm10-toolchain # 打印 HM-LINT-10 扫描器所用的 node 与 typescript（找不到以 3 退出）

退出码：0 = 无违反；1 = 有违反；2 = 参数不对（自测：失败用例 1、扫描器不可用 2）；3 = HM-LINT-10 找不到 node / typescript
（或扫描器出错）；4 = 无法保证扫完（fail-closed）：① HM-LINT-10 某个文件有语法错误，且退回扫描时遇到未闭合的模板 /
字符串 / 正则 / 块注释，或模板插值的花括号无法配对（FU-HM-0716 R3-01；修好该文件的语法错误后重跑）；② 扫描范围里某个目录
无法列举、某个条目无法确认类型、某个源码文件读不出（FU-HM-0718 第 3 项 ①：不静默跳过子树）；③ HM-LINT-10 的范围
（entry/src/staging）里出现不支持的文件——除 .ets / .ts 源码与资源数据文件（.json / .json5 / 图片）以外的任何文件（.js、.c 等
其他语言不套 TS 词法）、符号链接或特殊文件（FU-HM-0718 第 3 项 ②）。

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
                                   切到 prod 后不给假数据。FU-HM-0711b R1-06、R2-03：检查真实的属性访问，认导入别名
                                   （import { DebugFakeServer as X }、import * as NS）、局部别名（const X = DebugFakeServer）、可选链、
                                   方括号取值与解构；注释、字符串、正则字面量与模板文本不算。F-HM-33（FU-HM-0716）：用真正的
                                   TypeScript 解析器判定（tools/ci/hm10-scan.js，node + 鸿蒙 SDK 的 ohos-typescript，推导顺序见
                                   hm10_toolchain），代替原来手写的 HM10Lexer；找不到 node / typescript 时 lint 以 3 退出，不退化。
                                   文件有语法错误时退回扫描器逐记号判定；扫描器无法保证扫完该文件时 lint 以 4 退出（R3-01）。
                                   FU-HM-0718：范围内逐层显式列举（不套 SKIP_DIRS，staging 下名为 mock 的目录照扫），目录列举
                                   失败、不支持的文件类型、符号链接都以 4 退出。
                                   `--self-test-hm10` 跑正反例，`--hm10-toolchain` 打印所用的 node 与 typescript
"""

import json
import os
import re
import subprocess
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
FAKE_FLAG_OWNER = "entry/src/staging/ets/variant/DebugFakeServer.ets"
# HM-LINT-10 的范围（FU-HM-0718 第 3 项）：这个目录下每个文件都要有归属——源码交给 TypeScript 解析器（.ets 按 ArkTS、.ts 按 TS，
# hm10-scan.js 按扩展名选 ScriptKind），资源数据文件不含可执行代码、不扫描，其余一律「不支持」→ exit 4。
HM10_SCOPE = "entry/src/staging"
HM10_SOURCE_SUFFIXES = (".ets", ".ts")
HM10_DATA_SUFFIXES = (".json", ".json5", ".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg")
# Finder 元数据（不含代码；镜像同步也排除它），不算不支持的文件。
HM10_IGNORED_NAMES = {".DS_Store"}
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


HM10_SCANNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hm10-scan.js")
# 鸿蒙 SDK 的 ets-loader 自带 ohos-typescript（能解析 ArkTS 的 struct、装饰器与组件尾随闭包）；相对 SDK 目录的位置。
SDK_TYPESCRIPT = os.path.join("default", "openharmony", "ets", "build-tools", "ets-loader", "node_modules", "typescript")


class HM10ToolchainError(Exception):
    pass


def _version_key(name):
    return [int(x) if x.isdigit() else 0 for x in re.split(r"[.]", name.lstrip("v"))]


def hm10_toolchain():
    """HM-LINT-10 扫描器用的 node 与 typescript 包（F-HM-33）。推导顺序：
    node：① COULI_HM_NODE（显式指定；不存在即失败，不往下找）② $DEVECO_HOME/tools/node/bin/node（DevEco Studio 自带，
          DEVECO_HOME 默认 /Applications/DevEco-Studio.app/Contents，与 verify.sh 同口径）③ $NVM_BIN/node
          ④ ~/.nvm/versions/node/ 下版本最高的 bin/node ⑤ PATH 里的 node。
    typescript：① COULI_HM_TYPESCRIPT（显式指定；不存在即失败）② $DEVECO_SDK_HOME/default/openharmony/ets/build-tools/
          ets-loader/node_modules/typescript（鸿蒙 SDK 的 ohos-typescript，带 ets 编译选项；DEVECO_SDK_HOME 默认 $DEVECO_HOME/sdk）
          ③ $DEVECO_HOME/tools/hvigor/hvigor/node_modules/typescript ④ $DEVECO_HOME/tools/ohpm/node_modules/typescript
          （③④ 是普通 typescript，解析不了 ArkTS 组件语法的文件按「扫描器 + AST 可用部分」判定）。
    都找不到就抛 HM10ToolchainError：lint 以非零退出并提示，不退化为旧的手写词法启发式。不装依赖、不改 package 清单。"""
    deveco = os.environ.get("DEVECO_HOME") or "/Applications/DevEco-Studio.app/Contents"
    sdk = os.environ.get("DEVECO_SDK_HOME") or os.path.join(deveco, "sdk")

    def pick(env, candidates, what, ok):
        explicit = os.environ.get(env)
        if explicit:
            if ok(explicit):
                return explicit, env
            raise HM10ToolchainError("%s=%s 不是可用的 %s" % (env, explicit, what))
        for path, source in candidates:
            if path and ok(path):
                return path, source
        raise HM10ToolchainError("找不到 %s（依次找过：%s；可设 %s 或 DEVECO_HOME）"
                                 % (what, "、".join(p or s for p, s in candidates), env))

    nvm_root = os.path.expanduser("~/.nvm/versions/node")
    nvm_latest = None
    if os.path.isdir(nvm_root):
        versions = sorted(os.listdir(nvm_root), key=_version_key)
        if versions:
            nvm_latest = os.path.join(nvm_root, versions[-1], "bin", "node")
    nvm_bin = os.environ.get("NVM_BIN")
    which = None
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if d and os.access(os.path.join(d, "node"), os.X_OK):
            which = os.path.join(d, "node")
            break
    node, node_src = pick("COULI_HM_NODE", [
        (os.path.join(deveco, "tools", "node", "bin", "node"), "DevEco 自带 node"),
        (os.path.join(nvm_bin, "node") if nvm_bin else None, "NVM_BIN"),
        (nvm_latest, "nvm 最高版本"),
        (which, "PATH"),
    ], "node", lambda p: os.path.isfile(p) and os.access(p, os.X_OK))
    typescript, ts_src = pick("COULI_HM_TYPESCRIPT", [
        (os.path.join(sdk, SDK_TYPESCRIPT), "鸿蒙 SDK ets-loader 的 ohos-typescript"),
        (os.path.join(deveco, "tools", "hvigor", "hvigor", "node_modules", "typescript"), "DevEco hvigor 的 typescript"),
        (os.path.join(deveco, "tools", "ohpm", "node_modules", "typescript"), "DevEco ohpm 的 typescript"),
    ], "typescript 包", lambda p: os.path.isfile(os.path.join(p, "package.json")))
    return {"node": node, "node_source": node_src, "typescript": typescript, "typescript_source": ts_src}


def fake_flag_scan(sources):
    """HM-LINT-10：sources 为 [(文件名, 原始源码)]；一次调用 node + typescript 解析全部文件（hm10-scan.js），返回
    (工具链信息, [每个文件的 {"hits": [{"pos", "line"}], "diagnostics": n, "mode": "ast" | "ast+scanner",
    "incomplete": None | {"line", "reason"}}])。incomplete 非空表示退回扫描无法保证扫完该文件（lint 据此以 4 失败）。
    认导入别名、命名空间导入、局部别名（可连锁）、可选链、方括号取值与解构（FU-HM-0711b 的规则口径）；注释、字符串、正则与模板
    文本由解析器排除。工具链不可用或扫描器出错时抛 HM10ToolchainError。"""
    tool = hm10_toolchain()
    payload = json.dumps({"sources": [{"name": name, "text": text} for name, text in sources]}, ensure_ascii=False)
    try:
        proc = subprocess.run([tool["node"], HM10_SCANNER, tool["typescript"]], input=payload.encode("utf-8"),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
    except (OSError, subprocess.SubprocessError) as e:
        raise HM10ToolchainError("运行 %s 失败：%s" % (tool["node"], e))
    if proc.returncode != 0:
        raise HM10ToolchainError("hm10-scan.js 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
        results = out["results"]
    except (ValueError, KeyError) as e:
        raise HM10ToolchainError("hm10-scan.js 输出无法解析：%s" % e)
    if len(results) != len(sources):
        raise HM10ToolchainError("hm10-scan.js 返回 %d 份结果，应为 %d" % (len(results), len(sources)))
    if any(not isinstance(r, dict) or "incomplete" not in r for r in results):
        raise HM10ToolchainError("hm10-scan.js 的结果缺少 incomplete 字段（扫描器与 lint.py 版本不一致）")
    tool.update(out.get("typescript") or {})
    return tool, results


def describe_toolchain(tool):
    return "node %s（%s）+ %s %s（%s%s）" % (
        tool["node"], tool["node_source"], tool.get("name", "typescript"), tool.get("version", "?"), tool["typescript"],
        "，带 ets 编译选项" if tool.get("etsOptions") else "，无 ets 编译选项")


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
    # F-HM-30（FU-HM-0711c R2-01）：评审给出的两例（比较运算符 > 之后的对象字面量、case 里的 ??）与同类情形
    ("比较运算符之后对象字面量的除号", "const x = a > { k: 1 } / (DebugFakeServer.enabled ? 1 : 2) / 2;", 1),
    ("模板表达式里比较运算符之后对象字面量的除号",
     "const x = `${a > { k: 1 } / (DebugFakeServer.enabled ? 1 : 2) / 2}`;", 1),
    ("case 表达式含 ?? 之后的块（反例）", "switch(a) { case b ?? 1: {} /DebugFakeServer.enabled/.test(s); }", 0),
    ("case 表达式含 ??= 之后的块（反例）", "switch(a) { case (b ??= 1): {} /DebugFakeServer.enabled/.test(s); }", 0),
    ("?? 之后的正则（反例）", "const x = a ?? /DebugFakeServer.enabled/.test(s);", 0),
    ("?? 之后的真实读取", "const x = a ?? b / DebugFakeServer.enabled;", 1),
    ("case 含 ?? 与三元之后的块（反例）",
     "switch (a) { case b ?? (c ? 1 : 2): {} /DebugFakeServer.enabled/.test(s); }", 0),
    ("比较之后再比较对象字面量的除号",
     "for (let i = 0; i < n; i++) {}\nconst x = a > { k: 1 } / DebugFakeServer.enabled;", 1),
    ("if 条件里 < 比较之后 > 对象字面量的除号", "if (a < b) {}\nconst x = c > { k: 1 } / DebugFakeServer.enabled;", 1),
    ("嵌套泛型返回类型的函数体结束之后的正则（反例）",
     "function f(): Map<string, Array<number>> { return m; }\n/DebugFakeServer.enabled/.test(s);", 0),
    ("对象类型泛型返回类型的函数体结束之后的正则（反例）",
     "function f(): Promise<{ a: number }> { return p; }\n/DebugFakeServer.enabled/.test(s);", 0),
    ("泛型类声明体结束之后的正则（反例）",
     "class A<T> extends B<T> { x: T; }\n/DebugFakeServer.enabled/.test(s);", 0),
    ("函数类型泛型返回类型的函数体结束之后的正则（反例）",
     "function f(): Array<() => void> { return []; }\n/DebugFakeServer.enabled/.test(s);", 0),
    (">= 之后对象字面量的除号", "const x = a >= { k: 1 } / DebugFakeServer.enabled;", 1),
    # F-HM-33（FU-HM-0714 R1-01 / R1-02）：改用 TypeScript 解析器后，评审构造例与同类组合（FU-HM-0716）
    ("同一表达式里 < 与 > 比较之后对象字面量的除号",
     "const x = a < b && c > { k: 1 } / (DebugFakeServer.enabled ? 1 : 2) / 2;", 1),
    ("模板表达式里 < 与 > 比较之后对象字面量的除号",
     "const x = `${a < b && c > { k: 1 } / (DebugFakeServer.enabled ? 1 : 2) / 2}`;", 1),
    ("三元分支里 < 与 > 比较之后对象字面量的除号",
     "const x = t ? a < b && c > { k: 1 } / (DebugFakeServer.enabled ? 1 : 2) : 0;", 1),
    ("成员名 if 调用与 < > 比较组合的除号", "const x = obj.if(a < b) && c > { k: 1 } / DebugFakeServer.enabled;", 1),
    ("后缀 ++ 与 < > 比较组合的除号", "const x = i++ < b && c > { k: 1 } / DebugFakeServer.enabled;", 1),
    ("case 表达式含 ?? 与对象字面量之后的块（反例）",
     "switch(a) { case b ?? { k: 1 }: {} /DebugFakeServer.enabled/.test(s); }", 0),
    ("case 表达式含括号里的 ?? 与对象字面量之后的块（反例）",
     "switch(a) { case (b ?? { k: 1 }): {} /DebugFakeServer.enabled/.test(s); }", 0),
    ("case 表达式含 ??= 与对象字面量之后的块（反例）",
     "switch(a) { case (b ??= { k: 1 }): {} /DebugFakeServer.enabled/.test(s); }", 0),
    ("case 表达式含对象字面量与三元之后的块（反例）",
     "switch(a) { case t ? { k: 1 } : { k: 2 }: {} /DebugFakeServer.enabled/.test(s); }", 0),
    ("case 里对象字面量之后读取", "switch(a) { case b ?? { k: 1 }: x = DebugFakeServer.enabled; }", 1),
    ("泛型函数声明之后的正则（反例）",
     "function f<T>(x: T): T { return x; }\n/DebugFakeServer.enabled/.test(s);", 0),
    ("泛型类声明之后的正则（反例）", "class A<T> {}\n/DebugFakeServer.enabled/.test(s);", 0),
    ("泛型调用之后的除号", "const x = f<number>(a) / DebugFakeServer.enabled;", 1),
    ("无分号：换行之后的 / 仍是除号（不插分号）", "const a = b\n/DebugFakeServer.enabled/ 2", 1),
    ("无分号：return 换行之后的正则（反例）", "function f(s: string) { return\n/DebugFakeServer.enabled/.test(s) }", 0),
    ("无分号：换行之后的前缀 ++", "const a = x\n++DebugFakeServer.enabled", 1),
    ("无分号：换行之后的括号是调用", "const a = f\n(DebugFakeServer.enabled)", 1),
    ("无分号：语句块之后换行的正则（反例）", "if (a) {}\n/DebugFakeServer.enabled/.test(s)", 0),
    ("模板表达式里的正则与读取", "const x = `${/DebugFakeServer.enabled/.test(s) && DebugFakeServer.enabled}`;", 1),
    ("括号包住的引用", "const a = (DebugFakeServer).enabled;", 1),
    ("非空断言的引用", "const a = DebugFakeServer!.enabled;", 1),
    ("可选链方括号取值", "const a = DebugFakeServer?.['enabled'];", 1),
    ("改名解构", "const { enabled: on } = DebugFakeServer;", 1),
    ("赋值解构", "let on = false;\n({ enabled: on } = DebugFakeServer);", 1),
    ("命名空间导入的局部别名连锁",
     "import * as S from './DebugFakeServer';\nconst A = S.DebugFakeServer;\nconst B = A;\nconst x = B.enabled;", 1),
    ("ArkTS 组件里的读取",
     "@ComponentV2\nstruct P {\n  build() {\n    Column() {\n      Text(DebugFakeServer.enabled ? 'a' : 'b')\n    }\n  }\n}", 1),
    ("ArkTS 组件里的字符串与正则（反例）",
     "@ComponentV2\nstruct P {\n  @Local s: string = 'DebugFakeServer.enabled';\n  build() {\n    Column() {\n"
     "      Text(/DebugFakeServer.enabled/.test(this.s) ? 'a' : 'b')\n    }\n  }\n}", 0),
    # FU-HM-0716 R1-01：解构右侧剥掉类型断言（as / satisfies / ! / 括号）并认 ?? || &&（右值）三元 逗号 赋值可能返回的
    # 假服务引用；覆盖声明、参数默认值、赋值解构、嵌套与改名、模板内解构（正例均转成 JS 实际执行确认 getter 被调用）
    ('解构右侧 as 类型断言', 'const { enabled } = DebugFakeServer as typeof DebugFakeServer;', 1),
    ('解构右侧 ?? 回退', 'const { enabled } = DebugFakeServer ?? other;', 1),
    ('解构右侧 || 回退', 'const { enabled } = DebugFakeServer || other;', 1),
    ('参数默认值解构右侧 as', 'function f({ enabled }: Fake = DebugFakeServer as Fake) { return enabled; }\nf();', 1),
    ('赋值解构右侧 ??（改名）', 'let e = false;\n({ enabled: e } = DebugFakeServer ?? other);', 1),
    ('改名解构右侧括号里的 as 加非空断言', 'const { enabled: on } = (DebugFakeServer as Fake)!;', 1),
    ('模板表达式里的解构右侧 as', 'const s = `${(() => { const { enabled } = DebugFakeServer as Fake; return enabled; })()}`;', 1),
    ('解构右侧尖括号类型断言', 'const { enabled } = <Fake>DebugFakeServer;', 1),
    ('解构右侧 satisfies', 'const { enabled } = DebugFakeServer satisfies Fake;', 1),
    ('解构右侧 && 的右值', 'const { enabled } = other && DebugFakeServer;', 1),
    ('解构右侧三元的一支', 'const { enabled } = no ? other : DebugFakeServer;', 1),
    ('解构右侧逗号表达式的右值', 'const { enabled } = (0, DebugFakeServer);', 1),
    ('解构右侧 ??= 的右值', 'let v: Fake | null = nil;\nconst { enabled } = (v ??= DebugFakeServer);', 1),
    ('箭头函数参数默认值解构右侧 ??', 'const g = ({ enabled }: Fake = DebugFakeServer ?? nil) => enabled;\ng();', 1),
    ('嵌套赋值解构（改名）', 'let e = false;\n({ a: { enabled: e } } = { a: DebugFakeServer as Fake });', 1),
    ('嵌套声明解构', 'const { a: { enabled } } = { a: DebugFakeServer ?? other };', 1),
    ('嵌套解构默认值 as', 'const { a: { enabled } = DebugFakeServer as Fake } = {};', 1),
    ('嵌套赋值解构默认值 as', 'let e = false;\n({ a: { enabled: e } = DebugFakeServer as Fake } = {});', 1),
    ('简写属性的嵌套解构', 'const { DebugFakeServer: { enabled } } = { DebugFakeServer };', 1),
    ('数组解构里的对象解构', 'const [{ enabled }] = [DebugFakeServer as Fake];', 1),
    ('for…of 解构', 'for (const { enabled } of [DebugFakeServer as Fake]) {}', 1),
    ('计算键名解构右侧 as', "const { ['enabled']: on } = DebugFakeServer as Fake;", 1),
    ('as 断言的局部别名', 'const X = DebugFakeServer as Fake;\nconst a = X.enabled;', 1),
    ('?? 回退的局部别名', 'const X = nil ?? DebugFakeServer;\nconst a = X.enabled;', 1),
    ('as 断言之后点取值', 'const a = (DebugFakeServer as Fake).enabled;', 1),
    ('?? 回退之后方括号取值', "const a = (nil ?? DebugFakeServer)['enabled'];", 1),
    ('解构右侧是无关对象的 as（反例）', 'const { enabled } = other as Fake;', 0),
    ('解构右侧是无关对象的 ??（反例）', 'const { enabled } = other ?? nil;', 0),
    ('解构右侧 && 的左值（反例）', 'const { enabled } = DebugFakeServer && other;', 0),
    ('解构右侧逗号表达式的左值（反例）', 'const { enabled } = (DebugFakeServer, other);', 0),
    ("解构右侧字符串 'DebugFakeServer'（反例）",
     "const { length } = 'DebugFakeServer' as string;\nconst { enabled } = 'DebugFakeServer' as Fake;", 0),
    ('解构别的键（反例）', 'const { mockGate } = DebugFakeServer as Fake;', 0),
    ('嵌套解构取的是别的键（反例）', 'const { a: { enabled } } = { a: other, b: DebugFakeServer };', 0),
    ('数组解构取的是别的下标（反例）', 'const [, { enabled }] = [DebugFakeServer, other];', 0),
    ('调用结果的解构（反例）', 'const { enabled } = h(DebugFakeServer as Fake);', 0),
    ('调用 mockGate 的回退（反例）', 'const { enabled } = DebugFakeServer.mockGate() ?? other;', 0),
    # FU-HM-0716 R2-01：短路赋值 ??= ||= &&= 不赋值时返回左值，左右两侧都算候选；普通 = 只算右值（正例转成 JS 执行确认）
    ('解构右侧 ??= 的左值', 'let X = DebugFakeServer;\nconst { enabled } = X ??= other;', 1),
    ('??= 的左值之后点取值', 'let X = DebugFakeServer;\nconst a = (X ??= other).enabled;', 1),
    ('??= 的左值之后方括号取值', "let X = DebugFakeServer;\nconst a = (X ??= other)['enabled'];", 1),
    ('??= 的左值作局部别名', 'let X = DebugFakeServer;\nconst Y = X ??= other;\nconst a = Y.enabled;', 1),
    ('参数默认值解构右侧 ??= 的左值', 'let X = DebugFakeServer;\nfunction f({ enabled }: Fake = X ??= other) { return enabled; }\nf();', 1),
    ('解构右侧 ||= 的左值', 'let X = DebugFakeServer;\nconst { enabled } = X ||= other;', 1),
    ('||= 的左值之后点取值', 'let X = DebugFakeServer;\nconst a = (X ||= other).enabled;', 1),
    ('||= 的左值之后方括号取值', "let X = DebugFakeServer;\nconst a = (X ||= other)['enabled'];", 1),
    ('||= 的左值作局部别名', 'let X = DebugFakeServer;\nconst Y = X ||= other;\nconst a = Y.enabled;', 1),
    ('参数默认值解构右侧 ||= 的左值', 'let X = DebugFakeServer;\nfunction f({ enabled }: Fake = X ||= other) { return enabled; }\nf();', 1),
    ('解构右侧 &&= 的左值（按同一口径保守多报）', 'let X = DebugFakeServer;\nconst { enabled } = X &&= other;', 1),
    ('解构右侧 ??= 两侧都无关（反例）', 'let Y = other;\nconst { enabled } = Y ??= nil;', 0),
    ('||= 两侧都无关之后点取值（反例）', 'let Y = other;\nconst a = (Y ||= nil).enabled;', 0),
    ('&&= 两侧都无关之后方括号取值（反例）', "let Y = other;\nconst a = (Y &&= other)['enabled'];", 0),
    ('解构右侧普通赋值 = 的左值（反例，只算右值）', 'let X = DebugFakeServer;\nconst { enabled } = (X = other);', 0),
    # 解析出错时退回扫描器 + AST 可用部分（宁可多报，不漏报）
    ("语法错误的文件里的读取（扫描器退回）", "const = ;\nconst a = DebugFakeServer.enabled;", 1, "ast+scanner"),
    ("语法错误的文件里的字符串与正则（扫描器退回，反例）",
     "const = ;\nconst a = 'DebugFakeServer.enabled'; const r = /DebugFakeServer.enabled/;", 0, "ast+scanner"),
    ("语法错误的文件里的方括号与解构（扫描器退回）",
     "const = ;\nconst a = DebugFakeServer['enabled'];\nconst { enabled } = DebugFakeServer;", 2, "ast+scanner"),
    # R3-01：退回扫描不依赖错误 AST 的模板边界，自己配对 ${ 与 }；扫不完全文时判 incomplete（lint 以 4 失败）
    ("模板插值误加分号之后的读取（R3-01 复现）", "const s = `${value;}`;\nconst a = DebugFakeServer.enabled;", 1, "ast+scanner"),
    ("模板插值误加分号之后的方括号、解构与可选链",
     "const s = `${value;}`;\nconst a = DebugFakeServer['enabled'];\nconst { enabled } = DebugFakeServer;\n"
     "const b = DebugFakeServer?.enabled;", 3, "ast+scanner"),
    ("嵌套模板插值误加分号之后的读取", "const s = `a${`b${v;}`;}c`;\nconst a = DebugFakeServer.enabled;", 1, "ast+scanner"),
    ("模板续段之前的插值误加分号", "const s = `${a;}x${b}`;\nconst a = DebugFakeServer.enabled;", 1, "ast+scanner"),
    ("语法错误的文件里插值含对象字面量", "const = ;\nconst s = `${ {k: 1}.k }`;\nconst a = DebugFakeServer.enabled;", 1,
     "ast+scanner"),
    ("语法错误的文件里正常的嵌套模板", "const = ;\nconst s = `${a}`;\nconst t = `b${ `c${d}` }`;\n"
     "const a = DebugFakeServer.enabled;", 1, "ast+scanner"),
    ("语法错误的文件里嵌套模板文本（反例）",
     "const = ;\nconst s = `x ${`DebugFakeServer.enabled ${v}`} DebugFakeServer.enabled`;", 0, "ast+scanner"),
    ("正常的多层嵌套模板（AST）", "const s = `a${`b${ {k: `c${v}`}.k }`}d`;\nconst a = DebugFakeServer.enabled;", 1),
    ("未闭合的反引号（扫不完全文）", "const s = `abc;\nconst a = DebugFakeServer.enabled;", None, "incomplete"),
    ("未闭合的字符串（扫不完全文）", "const s = 'abc; const a = DebugFakeServer.enabled;\n", None, "incomplete"),
    ("未闭合的块注释（扫不完全文）", "const a = 1; /* abc\nconst b = DebugFakeServer.enabled;", None, "incomplete"),
    ("模板插值到文件末尾仍未闭合（扫不完全文）", "const s = `${ {k: 1}.k ;\nconst a = DebugFakeServer.enabled;", None,
     "incomplete"),
    ("未闭合的正则（扫不完全文）", "const = ;\nconst r = /abc\nconst a = DebugFakeServer.enabled;", None, "incomplete"),
]

# R3-01：整条 lint 的退出码（把源码放进临时目录的 entry/src/staging 下跑 main）。复现例只要报出或非零失败二者之一，
# 这里按实现要求更严：复现例必须报出（1），未闭合例必须以 4 失败。
HM10_LINT_CASES = [
    ("模板插值误加分号之后的读取 → 报出", "const s = `${value;}`;\nconst a = DebugFakeServer.enabled;", 1),
    ("未闭合的反引号 → 4", "const s = `abc;\nconst a = DebugFakeServer.enabled;", 4),
    ("未闭合的字符串 → 4", "const s = 'abc; const a = DebugFakeServer.enabled;\n", 4),
    ("未闭合的块注释 → 4", "const a = 1; /* abc\nconst b = DebugFakeServer.enabled;", 4),
    ("语法错误但能扫完的文件没有读取 → 0", "const = ;\nconst s = `${a}`;", 0),
]

# FU-HM-0718 第 3 项：整条 lint 在一棵目录树上的退出码。(说明, {相对路径: 内容}, 不可列举的子目录, [(符号链接, 指向)], 应有退出码)。
# 不可列举用 chmod 000 造（以 root 运行时列举照样成功，这几例会失败——本机 CI 不以 root 跑）。
HM10_READ = "const a = DebugFakeServer.enabled;\n"
HM10_OK = "const a = 1;\n"
HM10_TREE_CASES = [
    ("一个正常源码 + 一个不可列举的 staging 源码子目录 → 4（不静默跳过子树）",
     {"entry/src/staging/ets/Ok.ets": HM10_OK, "entry/src/staging/ets/hidden/Bad.ets": HM10_READ},
     ["entry/src/staging/ets/hidden"], [], 4),
    ("不可列举的子目录在 HM-LINT-1…9 的范围（common）→ 4",
     {"entry/src/staging/ets/Ok.ets": HM10_OK, "common/core/src/main/ets/Ok.ets": HM10_OK,
      "common/core/src/main/ets/locked/X.ets": HM10_OK},
     ["common/core/src/main/ets/locked"], [], 4),
    ("staging 里的 .js 读取 → 4（其他语言不套 TS 词法）",
     {"entry/src/staging/ets/Ok.ets": HM10_OK, "entry/src/staging/ets/Legacy.js": HM10_READ}, [], [], 4),
    ("staging 里的 .js 不含读取也 → 4（不支持即失败）",
     {"entry/src/staging/ets/Ok.ets": HM10_OK, "entry/src/staging/ets/util.mjs": HM10_OK}, [], [], 4),
    ("staging 里的 .c → 4", {"entry/src/staging/ets/Ok.ets": HM10_OK,
                            "entry/src/staging/cpp/native.c": "int f(void) { return 0; }\n"}, [], [], 4),
    ("staging 里的源码子目录是符号链接 → 4（不跟随）",
     {"entry/src/staging/ets/Ok.ets": HM10_OK, "outside/Bad.ets": HM10_READ}, [],
     [("entry/src/staging/ets/linked", "outside")], 4),
    ("staging 资源 json / json5 / png 与正常源码 → 0",
     {"entry/src/staging/ets/Ok.ets": HM10_OK, "entry/src/staging/resources/base/element/string.json": '{"string": []}\n',
      "entry/src/staging/resources/base/profile/x.json5": "{}\n", "entry/src/staging/resources/base/media/i.png": "png"},
     [], [], 0),
    ("staging/ets/mock 目录里的读取 → 1（HM-LINT-10 不套 SKIP_DIRS）",
     {"entry/src/staging/ets/mock/Fake.ets": HM10_READ}, [], [], 1),
    ("staging 里的 .ts 读取 → 1（.ts 按 TS 解析）", {"entry/src/staging/ets/Plain.ts": HM10_READ}, [], [], 1),
]


def run_tree_case(files, unreadable, links):
    """在临时目录里搭一棵树跑整条 lint，返回退出码（跑完恢复权限再删）。"""
    import tempfile
    with tempfile.TemporaryDirectory(prefix="hm10-tree-") as tmp:
        for rel, text in files.items():
            path = os.path.join(tmp, *rel.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        for rel, target in links:
            os.symlink(os.path.join(tmp, *target.split("/")), os.path.join(tmp, *rel.split("/")))
        locked = [os.path.join(tmp, *rel.split("/")) for rel in unreadable]
        try:
            for path in locked:
                os.chmod(path, 0)
            return main(["lint.py", "--root", tmp])
        finally:
            for path in locked:
                os.chmod(path, 0o755)


def self_test_hm10():
    """HM-LINT-10 正反例：(说明, 源码, 应报个数[, 应有的判定方式])。没给判定方式的用例必须由 AST 完整解析（语法诊断为 0）；
    带 "ast+scanner" 的用例故意含语法错误，验证扫描器退回路径。"""
    try:
        tool, results = fake_flag_scan([("Case%d.ets" % k, case[1]) for k, case in enumerate(HM10_CASES)])
    except HM10ToolchainError as e:
        print("HM-LINT-10 自测：扫描器不可用：%s" % e, file=sys.stderr)
        return 2
    print("HM-LINT-10 扫描器：" + describe_toolchain(tool))
    failed = 0
    for case, res in zip(HM10_CASES, results):
        title, want = case[0], case[2]
        want_mode = case[3] if len(case) > 3 else "ast"
        got = len(res["hits"])
        if want_mode == "incomplete":
            # 扫不完全文：必须由扫描器退回路径判出 incomplete（lint 据此以 4 失败），报几处不计。
            ok = res["mode"] == "ast+scanner" and bool(res["incomplete"])
            print("  %s %s：应判扫不完全文，实际 %s（%s，语法诊断 %d，实报 %d）"
                  % ("PASS" if ok else "FAIL", title, res["incomplete"], res["mode"], res["diagnostics"], got))
        else:
            ok = got == want and res["mode"] == want_mode and not res["incomplete"]
            print("  %s %s：应报 %d，实报 %d（%s，语法诊断 %d%s）"
                  % ("PASS" if ok else "FAIL", title, want, got, res["mode"], res["diagnostics"],
                     "，扫不完全文 %s" % res["incomplete"] if res["incomplete"] else ""))
        failed += 0 if ok else 1
    import tempfile
    for title, src, want_exit in HM10_LINT_CASES:
        with tempfile.TemporaryDirectory(prefix="hm10-selftest-") as tmp:
            staging = os.path.join(tmp, "entry", "src", "staging")
            os.makedirs(staging)
            with open(os.path.join(staging, "Case.ets"), "w", encoding="utf-8") as f:
                f.write(src)
            got_exit = main(["lint.py", "--root", tmp])
        ok = got_exit == want_exit
        failed += 0 if ok else 1
        print("  %s lint 退出码：%s：应为 %d，实为 %d" % ("PASS" if ok else "FAIL", title, want_exit, got_exit))
    for title, files, unreadable, links, want_exit in HM10_TREE_CASES:
        got_exit = run_tree_case(files, unreadable, links)
        ok = got_exit == want_exit
        failed += 0 if ok else 1
        print("  %s lint 目录树：%s：应为 %d，实为 %d" % ("PASS" if ok else "FAIL", title, want_exit, got_exit))
    total = len(HM10_CASES) + len(HM10_LINT_CASES) + len(HM10_TREE_CASES)
    print("HM-LINT-10 自测：%d 例（扫描 %d 例 + lint 退出码 %d 例 + 目录树 %d 例），%d 例失败"
          % (total, len(HM10_CASES), len(HM10_LINT_CASES), len(HM10_TREE_CASES), failed))
    return 1 if failed else 0


def ets_files(root, incomplete):
    """HM-LINT-1…9 的扫描范围（SCAN_DIRS 下的 .ets / .ts，跳过 SKIP_DIRS）。FU-HM-0718 第 3 项 ①：某个子目录无法列举时
    os.walk 默认静默跳过整棵子树——现在经 onerror 记进 incomplete（lint 以 4 退出），不再当成扫完。"""
    def walk_failed(err):
        incomplete.append("%s: 扫描目录无法列举（%s），该子树没有扫到，无法保证扫完"
                          % (os.path.relpath(err.filename or root, root), err.strerror or err))

    for top in SCAN_DIRS:
        base = os.path.join(root, top)
        try:
            os.lstat(base)
        except FileNotFoundError:
            continue
        except OSError as e:
            incomplete.append("%s: 扫描目录无法查询（%s），无法保证扫完" % (top, e.strerror or e))
            continue
        for dirpath, dirnames, names in os.walk(base, onerror=walk_failed):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in names:
                if name.endswith(".ets") or name.endswith(".ts"):
                    yield os.path.join(dirpath, name)


def hm10_scope_files(root, incomplete):
    """HM-LINT-10 范围（entry/src/staging）里要交给解析器的源码文件（FU-HM-0718 第 3 项）。逐层用 scandir 显式列举，不套
    SKIP_DIRS（staging 下的 mock / build 目录同样是会进 Debug / Staging 制品的源码），也不跟随符号链接。以下情形记进 incomplete
    （lint 以 4 退出），不静默跳过：范围目录或其中任一子目录无法列举；某个条目无法确认类型；符号链接、特殊文件；
    不支持的文件类型（只认 .ets / .ts 源码与资源数据文件，.js / .c 等其他语言不套 TS 词法）。范围目录明确不存在时没有要查的文件。"""
    base = os.path.join(root, *HM10_SCOPE.split("/"))

    def fail(path, why):
        incomplete.append("%s: HM-LINT-10 %s，无法保证扫完" % (os.path.relpath(path, root), why))

    try:
        os.lstat(base)
    except FileNotFoundError:
        return []
    except OSError as e:
        fail(base, "范围目录无法查询（%s）" % (e.strerror or e))
        return []
    out = []
    stack = [base]
    while stack:
        directory = stack.pop()
        try:
            with os.scandir(directory) as it:
                entries = sorted(it, key=lambda entry: entry.name)
        except OSError as e:
            fail(directory, "目录无法列举（%s），该子树没有扫到" % (e.strerror or e))
            continue
        for entry in entries:
            try:
                link = entry.is_symlink()
                is_dir = entry.is_dir(follow_symlinks=False)
                is_file = entry.is_file(follow_symlinks=False)
            except OSError as e:
                fail(entry.path, "无法确认条目类型（%s）" % (e.strerror or e))
                continue
            if link:
                fail(entry.path, "是符号链接（不跟随；按不支持处理）")
            elif is_dir:
                stack.append(entry.path)
            elif not is_file:
                fail(entry.path, "不是普通文件（按不支持处理）")
            elif entry.name.endswith(HM10_SOURCE_SUFFIXES):
                out.append(entry.path)
            elif entry.name.lower().endswith(HM10_DATA_SUFFIXES) or entry.name in HM10_IGNORED_NAMES:
                continue
            else:
                fail(entry.path, "是不支持的文件类型（只认 .ets / .ts 源码与资源数据文件；其他语言不套 TS 词法）")
    return sorted(out)


def read_source(path, root, incomplete):
    """读源码；读不出（权限、I/O、不是 UTF-8）记进 incomplete 并返回 None（FU-HM-0718：不以 Python 崩溃的 1 冒充「有违反」）。"""
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError) as e:
        incomplete.append("%s: 源码文件读不出（%s），无法保证扫完" % (os.path.relpath(path, root), e))
        return None


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

    # HM-LINT-10：entry/src/staging 下除 DebugFakeServer.ets 外的文件，一次交给 TypeScript 解析器（F-HM-33）。
    # 范围单独显式列举（FU-HM-0718 第 3 项）：列举失败、不支持的文件都进 incomplete（exit 4）。
    hm10_incomplete = []
    hm10_files = []
    for path in hm10_scope_files(root, hm10_incomplete):
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        if rel != FAKE_FLAG_OWNER:
            text = read_source(path, root, hm10_incomplete)
            if text is not None:
                hm10_files.append((path, text))
    hm10_hits = {}
    hm10_toolchain()  # 没有要查的文件也先确认工具链可用：找不到就失败，不因目录里碰巧没有 staging 源码而放行
    if hm10_files:
        _, results = fake_flag_scan([(os.path.basename(p), text) for p, text in hm10_files])
        for (p, _), res in zip(hm10_files, results):
            hm10_hits[p] = res["hits"]
            if res["incomplete"]:
                # R3-01：未闭合记号吞掉了其后的源码，判不了有没有读取 → 该文件判失败（fail-closed），不只打印提示。
                hm10_incomplete.append("%s:%d: HM-LINT-10 有 %d 处语法诊断，退回扫描遇到%s，无法保证扫完全文；先修好语法错误"
                                       % (os.path.relpath(p, root), res["incomplete"]["line"], res["diagnostics"],
                                          res["incomplete"]["reason"]))
            elif res["diagnostics"]:
                print("lint.py：HM-LINT-10 提示：%s 有 %d 处语法诊断，按扫描器 + AST 可用部分判定"
                      % (os.path.relpath(p, root), res["diagnostics"]), file=sys.stderr)
    # 命中按 HM-LINT-10 自己的范围报（FU-HM-0718：不经 ets_files，SKIP_DIRS 里的 mock 等目录也报）。
    for path, _ in hm10_files:
        for h in hm10_hits.get(path, []):
            report("HM-LINT-10", path, h["line"],
                   "调试替身直接读了 DebugFakeServer.enabled；改用 DebugFakeServer.mockGate（含当前环境 MOCK_DATA 闸门，F-X-02）")

    for path in ets_files(root, hm10_incomplete):
        src = read_source(path, root, hm10_incomplete)
        if src is None:
            continue
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
    return problems, hm10_incomplete


def main(argv):
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    args = argv[1:]
    if args == ["--self-test-hm10"]:
        return self_test_hm10()
    if args == ["--hm10-toolchain"]:
        try:
            print("HM-LINT-10 扫描器：" + describe_toolchain(fake_flag_scan([("Probe.ets", "")])[0]))
            return 0
        except HM10ToolchainError as e:
            print("HM-LINT-10 扫描器不可用：%s" % e, file=sys.stderr)
            return 3
    if args[:1] == ["--root"] and len(args) == 2:
        root = os.path.abspath(args[1])
    elif args:
        print("用法：lint.py [--root <目录>] | --self-test-hm10 | --hm10-toolchain", file=sys.stderr)
        return 2
    try:
        problems, incomplete = lint(root)
    except HM10ToolchainError as e:
        # 1 留给「有违规」；工具链不可用是另一种失败（verify.sh 的 lint-fixtures 不会把它当成「拦下」）。
        print("lint.py：HM-LINT-10 的 TypeScript 扫描器不可用，lint 失败（不退化为手写词法启发式）：%s" % e, file=sys.stderr)
        return 3
    for p in problems:
        print(p)
    if incomplete:
        for p in dict.fromkeys(incomplete):
            print(p)
        print("lint.py：有 %d 处无法保证扫完（语法错误的文件、无法列举的目录、读不出的文件或 HM-LINT-10 范围内不支持的文件），"
              "lint 失败（exit 4）；处理后重跑" % len(incomplete), file=sys.stderr)
        return 4
    if problems:
        print("lint.py：%d 处违反项目规则" % len(problems), file=sys.stderr)
        return 1
    print("lint.py：0 处违反（%s）" % root)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
