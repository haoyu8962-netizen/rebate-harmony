#!/usr/bin/env python3
"""FU-HM-ROOTSHOWN-CHAIN（编排 D10-1652，rootcause-r3 agent_01 / 02 / 03）宿主守卫：ShellState.onRootShown 只能按模块名登记。

背景：AppOrders.compose 曾直接赋值 ShellState.onRootShown（不链上原回调、compose 无重入保护），Ability 在同一进程里重建后「我的」
G36 autoLoad 与 Agent 启动参数自动发送两层都被冲掉。现改为与 onTabWillChange 同口径的 RootShownRegistry（同名替换、按名注销）。

用法：
    python3 tools/ci/rootshown/check_root_shown.py [--root <目录>]    # 检查（默认仓库根）
    python3 tools/ci/rootshown/check_root_shown.py --self-test        # 合成参照件 0 违反 + 每个反例被打红 + 良性改写不误报；
                                                                      # 另在本仓库真实文件副本上打入原缺陷，必须被打红
退出码：0 通过；1 有违反（自测：有反例没被杀、参照件不过或良性改写被误报）；2 参数不对；4 必需文件缺失 / 找不到方法（无法判定）。

规则（注释与字符串内容不参与匹配）：
    R1 common / entry / features 的 .ets / .ts 里不得对 onRootShown 赋值（= / ??= / ||= 等，含 ['onRootShown'] 写法），不得把它当函数调用
    R2 ShellState 声明 static readonly onRootShown: RootShownRegistry = new RootShownRegistry()；rootShown 里经 .dispatch(destination) 分发
    R3 RootShownRegistry：同名 register 替换原项（indexOf + 下标赋值）、有 unregister、dispatch 逐个 try/catch
    R4 订阅方各恰一处 ShellState.onRootShown.register(RootShownRegistry.<KEY>, …)，键全仓唯一，回调体按路由做自己的事：
         AppOrders → ORDERS（ORDER_LIST_ROUTE → this.showTab）、AppMe → ME（'Me' → this.tab().autoLoad()）、
         AppAgent → AGENT（AGENT_ROUTE → AgentVariant.onAgentShown）
    R5 重入保护：AppOrders / AppMe 的 compose 第一句是 if (this.context !== null) { … return; }，且该分支重登（registerRootShown()
       或直接 register）、不新建对象；AppAgent 的 register 在 if (this.composed) 之前
    R6 AgentTabRoot 的页面标题（.id(ID_TITLE)）不在 ForEach 里（同意后按状态键重建会换掉标题节点、焦点丢，agent_03）
  第二部分（编排 D10-1668，探针 2 定性）：
    R7 提现 / 收款账号 / 换号 / 注销页不直接覆盖执行器单槽 onChange，aboutToAppear 按页 subscribe、aboutToDisappear 注销
    R8 上述四页二次验证半屏分两步关：hideStepUp 只置 model.stepUp=false（不摘内容），releaseStepUp 在 bindSheet onDisappear 里摘内容；
       apply 关闭分支在本页同步 hideStepUp()；releaseStepUp / aboutToDisappear 之外不许摘面板内容
    R9 四个执行器有 subscribe，每处 this.onChange(x) 之后紧跟 this.pages.notify(x)
    R10 钱包问号 / 眼睛、提现手续费问号是 SymbolGlyph + CouliGlyphTap（不是 Button(){CouliIcon}）；SearchChip 根节点是 Text 叶子
    R12 CouliButton 内部 Text 有 .focusable(true)（D10-1680 方案 (b)，探针 3）
    R11 价格半屏 keyboardAvoidMode NONE、打开订阅 / 关闭退订键盘高度、按钮行在中段 Scroll 之外、中段高按 priceMiddleHeight、有键盘占位
    R13 钱包 / 提现页（features/wallet 下全部页面 + designsystem Wallet.ets）的问号 / 眼睛不得再是 Button(){CouliIcon} 旧写法；
        钱包「暂缓入账」问号（.id(ID_HELP_PAUSED)）是 SymbolGlyph + CouliGlyphTap（D10-1894 裁定 2，rootcause-r6 §1：R10 漏管 WalletView）；
        .id 必须挂在这个 SymbolGlyph 叶子本身，不许挂在包住它的 Button / Column / Stack 等外层容器上（评审 S2-1）
        （D10-1943 (c)：R10 / R13 的 Button 参数按括号配平，原正则 Button\\([^)]*\\) 遇到 stateEffect: !this.busy() 漏判）
    R14 common / entry / features（含 entry/src/staging）全部 .ets：带子组件的系统 Button（Button(…){…}，不含 CouliButton / ToggleType.Button /
        只用文字构造的 Button(label)）子树里必须有可获焦叶子——Text / SymbolGlyph / Image 自己的属性链上有 .focusable(true)；写在 Button 链或
        Row / Column / Stack 容器上的不算，子块只有 CouliIcon 等自定义组件或 builder 调用也不算；if / else 每个分支都要有（只含 LoadingProgress
        的分支在 Button 链有 .enabled( 时放行）；Button 链 .focusable(false) 或纯装饰（accessibilityLevel('no') 且无 onClick）放行。
        后续单的 17 处列在 R14_EXEMPT（文件 + 键 + FU 号，每条恰好放一处；条目没有对应命中也判红）（编排 D10-1943，扫描
        button-child-focus-sweep.md §6；rootcause-r8 §2 agent_04）
"""

import argparse
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

SHELL = "entry/src/main/ets/shell/ShellState.ets"
REGISTRY = "common/core/src/main/ets/router/RootShownRegistry.ets"
ORDERS = "entry/src/main/ets/orders/AppOrders.ets"
ME = "entry/src/main/ets/me/AppMe.ets"
AGENT = "entry/src/main/ets/agent/AppAgent.ets"
AGENT_ROOT = "features/agent/src/main/ets/AgentTabRoot.ets"
SCAN_DIRS = ("common", "entry", "features")
# 单测 / 设备测试不扫：core 单测里按 entry 复刻的替身（RootShownChain.test.ets 的 legacy 对照）本来就要写旧写法。
SKIP_DIRS = {"build", "oh_modules", "node_modules", ".hvigor", ".test", ".preview", "test", "ohosTest"}

SUBSCRIBERS = [
    # (文件, 键, 回调体必须出现的片段)
    (ORDERS, "ORDERS", ["destination.route === ORDER_LIST_ROUTE", "this.showTab(destination)"]),
    (ME, "ME", ["destination.route === 'Me'", "this.tab().autoLoad()"]),
    (AGENT, "AGENT", ["destination.route === AGENT_ROUTE", "AgentVariant.onAgentShown("]),
]


class Incomplete(Exception):
    pass


def read(root, rel):
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        raise Incomplete(rel + "：文件缺失，无法判定")


def strip(src, keep_strings=True):
    """去掉 // 与 /* */ 注释；keep_strings=False 时把字符串内容换成空格（保留引号与长度）。模板串按普通串处理（不进 ${}）。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
        elif c in "'\"`":
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    j += 1
                elif src[j] == "\n" and c != "`":
                    break
                j += 1
            body = src[i + 1:j]
            out.append(c + (body if keep_strings else re.sub(r"[^\n]", " ", body)) + (c if j < n else ""))
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def block_at(src, open_idx):
    """src[open_idx] 是 '{'：返回与之配对的 '}' 下标（src 已去注释、字符串内容已抹空）。"""
    depth = 0
    for k in range(open_idx, len(src)):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    raise Incomplete("大括号不配对")


def close_paren(code, open_idx):
    depth = 0
    for k in range(open_idx, len(code)):
        if code[k] == "(":
            depth += 1
        elif code[k] == ")":
            depth -= 1
            if depth == 0:
                return k
    return -1


def method_body(code, name, rel):
    """类成员方法（行首缩进 + 可选修饰 + 名字 + 形参表 + 可选返回类型 + {）的方法体。"""
    for m in re.finditer(r"\n[ \t]+(?:(?:private|public|protected|static|async)\s+)*" + re.escape(name) + r"\s*\(", code):
        end = close_paren(code, m.end() - 1)
        if end < 0:
            continue
        rest = re.match(r"\s*(?::[^{;]*)?\{", code[end + 1:])
        if rest:
            start = end + 1 + rest.end()
            return code[start:block_at(code, start - 1)]
    raise Incomplete(rel + "：找不到方法 " + name)


def product_files(root):
    out = []
    for top in SCAN_DIRS:
        base = os.path.join(root, top)
        for cur, dirs, files in os.walk(base):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for f in sorted(files):
                if f.endswith(".ets") or f.endswith(".ts"):
                    out.append(os.path.relpath(os.path.join(cur, f), root))
    return out


ASSIGN = re.compile(r"\bonRootShown\s*(?:\?\?|\|\||&&|[-+*/%])?=(?![=>])")
ASSIGN_INDEX = re.compile(r"\[\s*['\"]onRootShown['\"]\s*\]\s*(?:\?\?|\|\||&&|[-+*/%])?=(?![=>])")
CALL = re.compile(r"\.\s*onRootShown\s*\(")


def check_chain(root):
    v = []
    # R1
    for rel in product_files(root):
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
            raw = f.read()
        code = strip(raw, keep_strings=False)
        kept = strip(raw)
        hits = [m.start() for m in ASSIGN.finditer(code)] + [m.start() for m in ASSIGN_INDEX.finditer(kept)]
        for at in sorted(hits):
            line = code.count("\n", 0, at) + 1
            v.append("R1 %s:%d 对 onRootShown 直接赋值（只许 ShellState.onRootShown.register(名, 回调)）" % (rel, line))
        for m in CALL.finditer(code):
            line = code.count("\n", 0, m.start()) + 1
            v.append("R1 %s:%d 把 onRootShown 当函数调用（应 .dispatch / .register）" % (rel, line))
    # R2
    shell = strip(read(root, SHELL))
    if not re.search(r"static\s+readonly\s+onRootShown\s*:\s*RootShownRegistry\s*=\s*new\s+RootShownRegistry\s*\(\s*\)", shell):
        v.append("R2 ShellState.onRootShown 应为 static readonly onRootShown: RootShownRegistry = new RootShownRegistry()")
    body = method_body(shell, "rootShown", SHELL)
    if not re.search(r"ShellState\.onRootShown\.dispatch\(\s*destination\s*\)", body):
        v.append("R2 ShellState.rootShown 没经 ShellState.onRootShown.dispatch(destination) 分发")
    # R3
    reg = strip(read(root, REGISTRY))
    rb = method_body(reg, "register", REGISTRY)
    if not (re.search(r"this\.keys\.indexOf\(\s*key\s*\)", rb) and re.search(r"this\.listeners\[\s*i\s*\]\s*=\s*listener", rb)):
        v.append("R3 RootShownRegistry.register 同名登记必须替换原项（indexOf + 下标赋值），不能叠加")
    try:
        method_body(reg, "unregister", REGISTRY)
    except Incomplete:
        v.append("R3 RootShownRegistry 没有按名注销 unregister(key)")
    db = method_body(reg, "dispatch", REGISTRY)
    loop = re.search(r"\bfor\s*\(", db)
    after = db[close_paren(db, loop.end() - 1) + 1:] if loop else ""
    if not re.match(r"\s*\{\s*try\s*\{", after):
        v.append("R3 RootShownRegistry.dispatch 必须逐个 try/catch（一个监听方出错不影响其他）")
    # R4
    keys_seen = {}
    for rel in product_files(root):
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
            code = strip(f.read())
        for m in re.finditer(r"onRootShown\.register\(\s*([^,]+),", code):
            keys_seen.setdefault(m.group(1).strip(), []).append(rel)
    for key, rels in sorted(keys_seen.items()):
        if len(rels) > 1:
            v.append("R4 登记名 %s 出现 %d 处（%s）：同名会互相替换" % (key, len(rels), ", ".join(sorted(rels))))
    for rel, key, needles in SUBSCRIBERS:
        code = strip(read(root, rel))
        hits = list(re.finditer(r"ShellState\.onRootShown\.register\(\s*RootShownRegistry\." + key + r"\s*,", code))
        if len(hits) != 1:
            v.append("R4 %s 应恰一处 ShellState.onRootShown.register(RootShownRegistry.%s, …)（实际 %d）" % (rel, key, len(hits)))
            continue
        brace = code.find("{", hits[0].end())
        cb = code[brace:block_at(code, brace) + 1] if brace >= 0 else ""
        for needle in needles:
            if needle not in cb:
                v.append("R4 %s 登记的回调里缺「%s」" % (rel, needle))
    # R5
    for rel in (ORDERS, ME):
        code = strip(read(root, rel), keep_strings=False)
        cb = method_body(code, "compose", rel)
        m = re.match(r"\s*if\s*\(\s*this\.context\s*!==\s*null\s*\)\s*\{", cb)
        if not m:
            v.append("R5 %s compose 第一句应是重入保护 if (this.context !== null) { … return; }" % rel)
            continue
        guard = cb[m.end():block_at(cb, m.end() - 1)]
        if not re.search(r"\breturn\s*;", guard):
            v.append("R5 %s compose 重入分支没有 return（重建时会重复装配）" % rel)
        if not (re.search(r"this\.registerRootShown\(\s*\)", guard) or "onRootShown.register(" in guard):
            v.append("R5 %s compose 重入分支没按名重登 onRootShown" % rel)
        if re.search(r"\bnew\s+[A-Z]", guard):
            v.append("R5 %s compose 重入分支新建了对象（进程级装配不应重建）" % rel)
    code = strip(read(root, AGENT), keep_strings=False)
    cb = method_body(code, "compose", AGENT)
    reg_at = cb.find("ShellState.onRootShown.register(")
    guard_at = cb.find("if (this.composed)")
    if reg_at < 0 or guard_at < 0 or reg_at > guard_at:
        v.append("R5 %s compose 里 onRootShown 登记应在 if (this.composed) 之前（重建时仍按名重登）" % AGENT)
    # R6
    code = strip(read(root, AGENT_ROOT), keep_strings=False)
    titles = [m.start() for m in re.finditer(r"\.id\(\s*ID_TITLE\s*\)", code)]
    if not titles:
        v.append("R6 %s 没有 .id(ID_TITLE) 的页面标题" % AGENT_ROOT)
    else:
        for m in re.finditer(r"\bForEach\s*\(", code):
            open_paren = m.end() - 1
            k = close_paren(code, open_paren)
            if any(open_paren < t < k for t in titles):
                v.append("R6 %s 页面标题 ID_TITLE 在 ForEach 里（按状态键重建会换掉标题节点，同意后焦点丢）" % AGENT_ROOT)
            # 标题在 ForEach 项里调用的 @Builder 里也算
            seg = code[open_paren:k]
            for b in re.findall(r"this\.(\w+)\(", seg):
                try:
                    bb = method_body(code, b, AGENT_ROOT)
                except Incomplete:
                    continue
                if ".id(ID_TITLE)" in bb:
                    v.append("R6 %s 页面标题 ID_TITLE 所在的 @Builder %s 在 ForEach 里调用" % (AGENT_ROOT, b))
    return v


# ---------------------------------------------------------------- D10-1668（第二部分）：关闭链、按页订阅、不带子组件的可获焦控件、价格半屏键盘

STEPUP_VIEWS = [
    "features/wallet/src/main/ets/WithdrawView.ets",
    "features/wallet/src/main/ets/PayoutAccountView.ets",
    "features/me/src/main/ets/PhoneChangeView.ets",
    "features/me/src/main/ets/DeleteAccountView.ets",
]
STEPUP_CONTROLLERS = [
    "common/core/src/main/ets/wallet/WithdrawController.ets",
    "common/core/src/main/ets/wallet/PayoutAccountController.ets",
    "common/core/src/main/ets/me/account/PhoneChangeController.ets",
    "common/core/src/main/ets/me/account/DeleteAccountController.ets",
]
WALLET_DS = "common/designsystem/src/main/ets/components/Wallet.ets"
WITHDRAW_VIEW = STEPUP_VIEWS[0]
SEARCH_VIEW = "features/search/src/main/ets/SearchView.ets"
BASICS = "common/designsystem/src/main/ets/components/Basics.ets"
WALLET_VIEW = "features/wallet/src/main/ets/WalletView.ets"
WALLET_PAGES_DIR = "features/wallet/src/main/ets"
UI_FILES = STEPUP_VIEWS + STEPUP_CONTROLLERS + [WALLET_DS, SEARCH_VIEW, BASICS, WALLET_VIEW]
# R13：Button 构造（任意参数）的子组件就是问号 / 眼睛图标 = 旧写法（带子组件的 Button 在设备上不可获焦，探针 2）。
# D10-1943 (c)：参数按括号配平（原正则 Button\([^)]*\) 遇到 stateEffect: !this.busy() 这类带括号的参数直接漏判）；只留子组件开头的认法。
OLD_ICON_CHILD_R13 = re.compile(r"\s*CouliIcon\(\{\s*name:\s*('help'|'eye'|'eye-off'|this\.amountHidden)")
OLD_ICON_CHILD_R10 = re.compile(r"\s*CouliIcon\(\{\s*name:\s*('help'|this\.amountHidden)")
BUTTON_HEAD = re.compile(r"(?<![\w.$])Button\s*\(")


def button_blocks(blank):
    """blank（已去注释、字符串内容抹空）里带子组件的系统 Button：[(构造起点, 子块 '{' 下标, 子块 '}' 下标)]。
    token Button 前面不是标识符字符或 '.'（排除 CouliButton、ToggleType.Button）；参数按括号配平；收口 ')' 后第一个非空白是 '{' 才算带子组件。"""
    out = []
    n = len(blank)
    for m in BUTTON_HEAD.finditer(blank):
        end = close_paren(blank, m.end() - 1)
        if end < 0:
            continue
        k = end + 1
        while k < n and blank[k] in " \t\r\n":
            k += 1
        if k < n and blank[k] == "{":
            out.append((m.start(), k, block_at(blank, k)))
    return out


def old_icon_buttons(raw, child_re):
    """带子组件的 Button、子块开头就是 child_re 认的 CouliIcon：返回构造起点下标列表（下标对齐 strip 后的文本）。"""
    kept = strip(raw)
    blank = strip(raw, keep_strings=False)
    return [s for s, o, _c in button_blocks(blank) if child_re.match(kept, o + 1)]


def unbalanced_close(seg):
    """seg（已去注释、字符串抹空）里收口的 } 多于开口的 {：说明从 seg 起点所在组件出发，到 seg 末尾已退回到外层（评审 S2-1）。"""
    return seg.count("}") > seg.count("{")


def wallet_pages(root):
    """钱包 / 提现页：features/wallet 主源集下全部 .ets（新加页面自动纳入）。目录缺失 = 无法判定。"""
    base = os.path.join(root, WALLET_PAGES_DIR)
    if not os.path.isdir(base):
        raise Incomplete(WALLET_PAGES_DIR + "：目录缺失，无法判定")
    return [WALLET_PAGES_DIR + "/" + f for f in sorted(os.listdir(base)) if f.endswith(".ets")]


def struct_body(code, name, rel):
    m = re.search(r"\bstruct\s+" + re.escape(name) + r"\b[^{]*\{", code)
    if not m:
        raise Incomplete(rel + "：找不到 struct " + name)
    return code[m.end():block_at(code, m.end() - 1)]


def check_ui(root):
    v = []
    # R7 / R8：二次验证发起页按页订阅、半屏分两步关闭
    for rel in STEPUP_VIEWS:
        code = strip(read(root, rel), keep_strings=False)
        if re.search(r"\.onChange\s*=(?![=>])", code):
            v.append("R7 %s 仍直接覆盖执行器单槽 onChange（应 subscribe / 注销）" % rel)
        appear = method_body(code, "aboutToAppear", rel)
        if not re.search(r"this\.unsubscribeChange\s*=\s*[\w.]+\.subscribe\(", appear):
            v.append("R7 %s aboutToAppear 没有按页订阅（this.unsubscribeChange = ….subscribe(…)）" % rel)
        gone = method_body(code, "aboutToDisappear", rel)
        if "this.unsubscribeChange?.()" not in gone:
            v.append("R7 %s aboutToDisappear 没有注销订阅" % rel)
        try:
            hide = method_body(code, "hideStepUp", rel)
            release = method_body(code, "releaseStepUp", rel)
        except Incomplete:
            v.append("R8 %s 缺 hideStepUp / releaseStepUp（半屏两步关闭）" % rel)
            continue
        if not re.search(r"this\.model\.stepUp\s*=\s*false", hide):
            v.append("R8 %s hideStepUp 没有置 model.stepUp = false" % rel)
        if "this.stepUpController = null" in hide:
            v.append("R8 %s hideStepUp 里摘了面板内容（应留到 onDisappear，否则 token 路径留下空壳半屏）" % rel)
        if "this.stepUpController = null" not in release:
            v.append("R8 %s releaseStepUp 没有摘面板内容" % rel)
        allowed = [release, gone]
        nulls = len(re.findall(r"this\.stepUpController\s*=\s*null", code))
        ok_nulls = sum(len(re.findall(r"this\.stepUpController\s*=\s*null", b)) for b in allowed)
        if nulls != ok_nulls:
            v.append("R8 %s 在 releaseStepUp / aboutToDisappear 之外摘了面板内容（%d 处）" % (rel, nulls - ok_nulls))
        apply_b = method_body(code, "apply", rel)
        m = re.search(r"else\s+if\s*\(\s*s\.stepUpAction\s*===\s*null[^{]*\{", apply_b)
        if not m or "this.hideStepUp()" not in apply_b[m.end():block_at(apply_b, m.end() - 1)]:
            v.append("R8 %s apply 的关闭分支没有在本页同步 hideStepUp()" % rel)
        dm = re.search(r"onDisappear\s*:\s*\(\s*\)\s*=>\s*\{", code)
        if not dm or "this.releaseStepUp()" not in code[dm.end():block_at(code, dm.end() - 1)]:
            v.append("R8 %s bindSheet onDisappear 没有 releaseStepUp()" % rel)
    # R9：执行器提供按页订阅，每个 onChange 通知点同时通知订阅页
    for rel in STEPUP_CONTROLLERS:
        code = strip(read(root, rel))
        try:
            method_body(code, "subscribe", rel)
        except Incomplete:
            v.append("R9 %s 没有 subscribe(listener)（按页订阅）" % rel)
        calls = re.findall(r"this\.onChange\(([^)]*)\);", code)
        for arg in calls:
            if not re.search(r"this\.onChange\(" + re.escape(arg) + r"\);\s*this\.pages\.notify\(" + re.escape(arg) + r"\);", code):
                v.append("R9 %s this.onChange(%s) 之后没有 this.pages.notify(%s)" % (rel, arg, arg))
    # R10：问号、眼睛、价格胶囊是不带子组件的叶子（设备上带子组件的 Button / 容器不可获焦，tabStop 无效，探针 2）
    for rel in (WALLET_DS, WITHDRAW_VIEW):
        raw = read(root, rel)
        code = strip(raw)
        if old_icon_buttons(raw, OLD_ICON_CHILD_R10):
            v.append("R10 %s 问号 / 眼睛仍是 Button(){CouliIcon}（设备上不可获焦）" % rel)
        if "new CouliGlyphTap(" not in code:
            v.append("R10 %s 问号 / 眼睛没有用 SymbolGlyph + CouliGlyphTap" % rel)
    code = strip(read(root, SEARCH_VIEW))
    chip = struct_body(code, "SearchChip", SEARCH_VIEW)
    build = method_body(chip, "build", SEARCH_VIEW)
    if not re.match(r"\s*Text\(\s*\)\s*\{", build):
        v.append("R10 SearchChip 的根节点不是 Text 叶子（容器 + focusable(true) 在设备上不可获焦）")
    # R11：价格半屏按键盘自布局（标题与按钮行固定、只中段滚动）
    m = re.search(r"\.bindSheet\(\s*this\.model\.sheetOpen\s*,\s*this\.priceSheet\(\)\s*,\s*\{", code)
    if not m:
        v.append("R11 找不到价格半屏 bindSheet")
    else:
        opts = code[m.end():block_at(code, m.end() - 1)]
        if "keyboardAvoidMode: SheetKeyboardAvoidMode.NONE" not in opts:
            v.append("R11 价格半屏没有 keyboardAvoidMode: SheetKeyboardAvoidMode.NONE")
        if "this.attachPriceKeyboard()" not in opts or "this.detachPriceKeyboard()" not in opts:
            v.append("R11 价格半屏打开 / 关闭没有订阅 / 退订键盘高度")
    sheet = method_body(code, "priceSheet", SEARCH_VIEW)
    sm = re.search(r"Scroll\(this\.priceMiddleScroller\)\s*\{", sheet)
    if not sm:
        v.append("R11 价格半屏中段不是 Scroll(this.priceMiddleScroller)")
    else:
        inner = sheet[sm.end():block_at(sheet, sm.end() - 1)]
        if "search_price_confirm" in inner or "search_price_actions" in inner:
            v.append("R11 价格半屏按钮行在中段 Scroll 里（应固定在中段之外）")
        if "search_price_actions" not in sheet[block_at(sheet, sm.end() - 1):]:
            v.append("R11 价格半屏按钮行（search_price_actions）不在中段之后")
        if "this.priceMiddleHeight()" not in sheet:
            v.append("R11 价格半屏中段高没按键盘后可用高（priceMiddleHeight）")
    if "StepUpPanelFit.spacer(this.priceKeyboardVp)" not in sheet:
        v.append("R11 价格半屏没有与键盘等高的占位")
    # R12：CouliButton 内部 Text 可获焦（D10-1680 方案 (b)，探针 3：否则带子组件的 Button 整棵不可获焦，回焦落空）
    bcode = strip(read(root, BASICS), keep_strings=False)
    bbuild = method_body(struct_body(bcode, "CouliButton", BASICS), "build", BASICS)
    tm = re.search(r"\bText\(\s*this\.text\s*\)", bbuild)
    if not tm:
        v.append("R12 CouliButton.build 里找不到内部 Text(this.text)")
    else:
        rest = bbuild[tm.end():]
        nxt = re.search(r"\n\s*[A-Z]\w*\(|\n\s*\}", rest)
        chain = rest[:nxt.start()] if nxt else rest
        if not re.search(r"\.focusable\(\s*true\s*\)", chain):
            v.append("R12 CouliButton 内部 Text 没有 .focusable(true)（整按钮在设备上不可获焦，提现【提交】等回焦落空）")
    # R13（D10-1894 裁定 2）：钱包 / 提现页的问号、眼睛不得回到 Button(){CouliIcon}；暂缓入账问号是 SymbolGlyph + CouliGlyphTap
    pages = wallet_pages(root)
    if WALLET_VIEW not in pages:
        raise Incomplete(WALLET_VIEW + "：文件缺失，无法判定")
    for rel in pages + [WALLET_DS]:
        raw = read(root, rel)
        code = strip(raw)
        for at in old_icon_buttons(raw, OLD_ICON_CHILD_R13):
            v.append("R13 %s:%d 问号 / 眼睛仍是 Button(){CouliIcon} 旧写法（设备上不可获焦，键盘走焦与回焦落空）"
                     % (rel, code.count("\n", 0, at) + 1))
    wcode = strip(read(root, WALLET_VIEW))
    wblank = strip(read(root, WALLET_VIEW), keep_strings=False)  # 字符串内容抹空、长度不变，下标与 wcode 对齐
    ids = [m.start() for m in re.finditer(r"\.id\(\s*ID_HELP_PAUSED\s*\)", wcode)]
    if len(ids) != 1:
        v.append("R13 %s .id(ID_HELP_PAUSED) 应恰一处（实际 %d 处）" % (WALLET_VIEW, len(ids)))
    else:
        heads = list(re.finditer(r"\n[ \t]*([A-Z]\w*)\(", wcode[:ids[0]]))
        head = heads[-1] if heads else None
        if head is None or head.group(1) != "SymbolGlyph" or not re.match(r"\s*couliSymbol\(\s*'help'\s*\)\s*\)", wcode[head.end():]):
            v.append("R13 %s 暂缓入账问号（ID_HELP_PAUSED）不是 SymbolGlyph(couliSymbol('help')) 叶子（实际 %s）"
                     % (WALLET_VIEW, head.group(1) if head else "找不到组件"))
        elif unbalanced_close(wblank[head.end():ids[0]]):
            # 评审 S2-1：SymbolGlyph 与 .id 之间收口的 } 多于开口的 {，说明 .id 挂在包住 SymbolGlyph 的外层容器上（带子组件的容器不可获焦，探针 2）
            v.append("R13 %s 暂缓入账问号的 .id(ID_HELP_PAUSED) 挂在包住 SymbolGlyph 的外层容器上（应挂在 SymbolGlyph 叶子本身）" % WALLET_VIEW)
        elif "new CouliGlyphTap(" not in wcode[head.start():ids[0]]:
            v.append("R13 %s 暂缓入账问号没有用 CouliGlyphTap（布局框 / 48vp 命中区 / 按压反馈）" % WALLET_VIEW)
    return v


# ---------------------------------------------------------------- R14（编排 D10-1943 (b)(c)）：带子组件的 Button 子树里必须有可获焦叶子

R14_DIRS = ("common", "entry", "features")  # 含 entry/src/staging（只按豁免表放行那 1 处，不整目录豁免）
LEAF_HEAD = re.compile(r"(?<![\w.$])(Text|SymbolGlyph|Image)\s*\(")
COMPONENT_HEAD = re.compile(r"(?<![\w.$])([A-Z]\w*)\s*\(")
FOCUSABLE_TRUE = re.compile(r"\.\s*focusable\(\s*true\s*\)")
R14_FU = "FU-HM-BUTTON-CHILD-FOCUS-SWEEP"
# 显式豁免表（D10-1943 (c)）：button-child-focus-sweep.md §2.2 / §2.3 的 16 处后续单 + §4 staging 1 处。每条 = 文件 + 键 + FU 号；
# 键是 Button 属性链里 .id(…) 的实参原文（没有 id 时用 .accessibilityText(…) 实参，再没有时用「noid:子组件序列#序号」）。
# 每条恰好放行一处命中：修好后命中消失、条目还在 → 判红（基线只减不增）；同文件同键多出一处 → 多出的那处判红。不许通配。
R14_EXEMPT = [
    # (文件, 键, FU 号, 说明)
    ("features/me/src/main/ets/MeTabView.ets", "id:'me_bell'", R14_FU, "扫描 #23 我的 · 消息铃"),
    ("features/me/src/main/ets/MeTabView.ets", "id:'me_guide_bar_close'", R14_FU, "扫描 #24 我的 · 引导条关闭"),
    ("features/me/src/main/ets/MeTabView.ets", "id:'me_copy_invite'", R14_FU, "扫描 #25 我的 · 复制邀请码"),
    ("features/me/src/main/ets/MeTabView.ets", "id:'me_amount_mask'", R14_FU, "扫描 #26 我的 · 余额卡眼睛"),
    ("features/me/src/main/ets/PrivacyAboutCsParts.ets", "id:this.buttonId", R14_FU, "扫描 #27 关于页复制按钮 AboutCopyButton"),
    ("features/me/src/main/ets/PrivacyAboutCsParts.ets", "id:this.closeId", R14_FU, "扫描 #28 客服半屏 CsSheetPanel 关闭"),
    ("features/me/src/main/ets/MeKit.ets", "label:this.closeLabel", R14_FU, "扫描 #29 设置页 MeSheetPanel 关闭（无 id）"),
    ("features/me/src/main/ets/SettingsView.ets", "id:'nickname_clear'", R14_FU, "扫描 #30 设置 · 昵称清空"),
    ("features/web/src/main/ets/TrustedWebView.ets", "noid:CouliIcon>navTextColor#1", R14_FU, "扫描 #31 可信 Web 页返回（无 id、无读屏名）"),
    ("features/web/src/main/ets/TrustedWebView.ets", "label:DefaultTexts.text(CLOSE_KEY) ?? ''", R14_FU, "扫描 #32 可信 Web 页关闭"),
    ("features/web/src/main/ets/ExternalWebView.ets", "noid:CouliIcon>titleColors#1", R14_FU, "扫描 #33 外部 Web 页返回（无 id、无读屏名）"),
    ("features/web/src/main/ets/ExternalWebView.ets", "label:DefaultTexts.text(CLOSE_KEY) ?? ''", R14_FU, "扫描 #34 外部 Web 页关闭"),
    ("entry/src/main/ets/shell/AppShell.ets", "label:ShellDraftTexts.SETTINGS", R14_FU, "扫描 #35 基本模式顶栏设置（无 id）"),
    ("common/designsystem/src/main/ets/components/Controls.ets", "id:this.controlId.length > 0 ? this.controlId : undefined", R14_FU, "扫描 #36 CouliIconButton（只有 staging 组件目录在用）"),
    ("common/designsystem/src/main/ets/components/Login.ets", "id:this.controlId.length > 0 ? this.controlId : undefined", R14_FU, "扫描 #37 OAuthButton（只有 staging 组件目录在用）"),
    ("common/designsystem/src/main/ets/components/Inputs.ets", "label:this.accessibilityName.length > 0 ? this.accessibilityName : this.placeholder", R14_FU, "扫描 #38 SearchEntry（只有 staging 组件目录在用）"),
    ("entry/src/staging/ets/catalog/CatalogDetail.ets", "id:'catalog-sheet-close'", R14_FU, "扫描 §4 staging 组件目录详情半屏关闭（调试页，Release 不含）"),
]


def r14_files(root):
    out = {}
    for top in R14_DIRS:
        base = os.path.join(root, top)
        if not os.path.isdir(base):
            raise Incomplete(top + "：目录缺失，无法判定")
        for cur, dirs, files in os.walk(base):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for f in sorted(files):
                if f.endswith(".ets"):
                    p = os.path.join(cur, f)
                    with open(p, encoding="utf-8", errors="replace") as fh:
                        out[os.path.relpath(p, root).replace(os.sep, "/")] = fh.read()
    return out


def chain_end(blank, k):
    """blank[k:] 起连续的属性链 .name(…)（括号配平，可跨行）的结束下标。"""
    n = len(blank)
    j = k
    while True:
        p = j
        while p < n and blank[p] in " \t\r\n":
            p += 1
        m = re.compile(r"\.\s*\w+\s*\(").match(blank, p)
        if not m:
            return j
        cp = close_paren(blank, m.end() - 1)
        if cp < 0:
            return j
        j = cp + 1


def branch_groups(blank, lo, hi):
    """[lo, hi) 里最外层的 if / else if / else 组：[(各分支 [(lo, hi)], 有没有收尾 else)]。"""
    groups = []
    k = lo
    rx = re.compile(r"(?<![\w.$])if\s*\(")
    while True:
        m = rx.search(blank, k, hi)
        if not m:
            return groups
        cp = close_paren(blank, m.end() - 1)
        o = blank.find("{", cp)
        if cp < 0 or o < 0 or o >= hi:
            return groups
        c = block_at(blank, o)
        branches = [(o + 1, c)]
        final_else = False
        k = c + 1
        while True:
            em = re.compile(r"\s*else\b").match(blank, k)
            if not em:
                break
            im = re.compile(r"\s*if\s*\(").match(blank, em.end())
            if im:
                cp2 = close_paren(blank, im.end() - 1)
                o2 = blank.find("{", cp2)
                c2 = block_at(blank, o2)
                branches.append((o2 + 1, c2))
                k = c2 + 1
                continue
            o2 = blank.find("{", em.end())
            c2 = block_at(blank, o2)
            branches.append((o2 + 1, c2))
            final_else = True
            k = c2 + 1
            break
        groups.append((branches, final_else))


def focusable_leaf(blank, lo, hi, holes):
    """[lo, hi) 里（不含 holes 区间）有没有叶子 Text / SymbolGlyph / Image，且这个叶子自己的属性链里有 .focusable(true)。
    容器（Row / Column / Stack 等）上的 .focusable(true) 不算（probe_col），Button 自己链上的也不算（探针 1）。"""
    for m in LEAF_HEAD.finditer(blank, lo, hi):
        if any(a <= m.start() < b for a, b in holes):
            continue
        cp = close_paren(blank, m.end() - 1)
        if cp < 0:
            continue
        k = cp + 1
        p = k
        while p < len(blank) and blank[p] in " \t\r\n":
            p += 1
        if p < len(blank) and blank[p] == "{":  # Text() { Span(…) }
            k = block_at(blank, p) + 1
        if FOCUSABLE_TRUE.search(blank[k:chain_end(blank, k)]):
            return True
    return False


def loading_only(blank, lo, hi):
    heads = [m.group(1) for m in COMPONENT_HEAD.finditer(blank, lo, hi)]
    return bool(heads) and all(h == "LoadingProgress" for h in heads)


def subtree_ok(blank, lo, hi, enabled):
    """子块 [lo, hi) 在任何分支下都有可获焦叶子；只含 LoadingProgress 的分支在 Button 链有 .enabled( 时放行（§6.1 5b）。"""
    groups = branch_groups(blank, lo, hi)
    holes = [b for g, _e in groups for b in g]
    if focusable_leaf(blank, lo, hi, holes):
        return True
    for branches, final_else in groups:
        if not final_else:
            continue
        oks = [subtree_ok(blank, a, b, enabled) for a, b in branches]
        if any(oks) and all(ok or (enabled and loading_only(blank, a, b)) for ok, (a, b) in zip(oks, branches)):
            return True
    return False


def call_arg(kept, blank, chain_lo, chain_hi, name):
    m = re.compile(r"\.\s*" + name + r"\s*\(").search(blank, chain_lo, chain_hi)
    if not m:
        return None
    cp = close_paren(blank, m.end() - 1)
    return " ".join(kept[m.end():cp].split())


def r14_hits(rel, raw):
    """一个文件里 R14 命中：[(行号, 键, 子组件序列)]。"""
    kept = strip(raw)
    blank = strip(raw, keep_strings=False)
    out = []
    noid = {}
    for s, o, c in button_blocks(blank):
        chain_hi = chain_end(blank, c + 1)
        chain = blank[c + 1:chain_hi]
        kchain = kept[c + 1:chain_hi]
        if re.search(r"\.\s*focusable\(\s*false\s*\)", chain):
            continue  # 有意不进键盘路径（§6.1 5c）
        if re.search(r"\.\s*accessibilityLevel\(\s*'(no|no-hide-descendants)'\s*\)", kchain) and not re.search(r"\.\s*onClick\s*\(", chain):
            continue  # 纯装饰（§6.1 5c）
        enabled = re.search(r"\.\s*enabled\s*\(", chain) is not None
        if subtree_ok(blank, o + 1, c, enabled):
            continue
        sig = ">".join([m.group(1) for m in COMPONENT_HEAD.finditer(blank, o + 1, c)][:4]
                       + re.findall(r"this\.(\w+)\(", blank[o + 1:c])[:2]) or "空"
        ident = call_arg(kept, blank, c + 1, chain_hi, "id")
        label = call_arg(kept, blank, c + 1, chain_hi, "accessibilityText")
        if ident is not None:
            key = "id:" + ident
        elif label is not None:
            key = "label:" + label
        else:
            noid[sig] = noid.get(sig, 0) + 1
            key = "noid:%s#%d" % (sig, noid[sig])
        out.append((blank.count("\n", 0, s) + 1, key, sig))
    return out


def r14_judge(files, exempt):
    v = []
    table = {}
    for rel, key, fu, why in exempt:
        if "*" in rel + key or key.strip() in ("", "id:", "label:") or not rel.endswith(".ets") or not re.match(r"^FU-[A-Z0-9-]+$", fu) or not why:
            v.append("R14 豁免表条目不合格（必须是具体 .ets 文件 + 具体键 + FU 号 + 理由，不许通配）：%s %s" % (rel, key))
            continue
        if (rel, key) in table:
            v.append("R14 豁免表重复条目：%s %s" % (rel, key))
            continue
        table[(rel, key)] = False
    for rel in sorted(files):
        for line, key, sig in r14_hits(rel, files[rel]):
            if (rel, key) in table and not table[(rel, key)]:
                table[(rel, key)] = True
                continue
            v.append("R14 %s:%d Button(){%s} 子树里没有可获焦叶子（设备上整按钮不可获焦，键盘走焦与回焦落空；"
                     "改 SymbolGlyph + CouliGlyphTap 或内部叶子 .focusable(true)）[键 %s]" % (rel, line, sig, key))
    for (rel, key), used in sorted(table.items()):
        if not used:
            v.append("R14 豁免表条目已无对应命中（已修或已删，请从 R14_EXEMPT 删掉，基线只减不增）：%s %s" % (rel, key))
    return v


def check_button_focus(root):
    return r14_judge(r14_files(root), R14_EXEMPT)


def check(root):
    return check_chain(root) + check_ui(root) + check_button_focus(root)


# 暂缓入账问号在真实 WalletView 里的现写法（R13 反例 / 良性改写的锚点）
PAUSED_TAP = "          .attributeModifier(new CouliGlyphTap(16, CouliColors.textSecondary, -CouliSpacing.space3, -14, -CouliSpacing.space3, -14))\n"
PAUSED_A11Y = "          .accessibilityLevel('yes')\n          .accessibilityRole(AccessibilityRoleType.BUTTON)\n"
PAUSED_GLYPH = "          SymbolGlyph(couliSymbol('help'))\n" + PAUSED_TAP + PAUSED_A11Y

# 真实文件副本上的 D10-1668 反例（每条打回原写法，必须被对应规则打红）
UI_MUTANTS = [
    ("提现页覆盖单槽 onChange（原写法）", WITHDRAW_VIEW,
     "this.unsubscribeChange = this.config.controller.subscribe((s: WithdrawSnapshot): void => this.apply(s));",
     "this.config.controller.onChange = (s: WithdrawSnapshot): void => this.apply(s);", "R7"),
    ("收款账号页离开不注销", "features/wallet/src/main/ets/PayoutAccountView.ets",
     "    this.unsubscribeChange?.();\n", "", "R7"),
    ("提现页关闭分支同帧清空内容（原缺陷）", WITHDRAW_VIEW, "      this.hideStepUp();\n    }",
     "      this.stepUpController.close();\n      this.stepUpController = null;\n      m.stepUp = false;\n      this.pageAvoid(true);\n    }", "R8"),
    ("注销页 hideStepUp 里摘内容", "features/me/src/main/ets/DeleteAccountView.ets",
     "  private hideStepUp(): void {\n", "  private hideStepUp(): void {\n    this.stepUpController = null;\n", "R8"),
    ("换号页 onDisappear 不摘内容", "features/me/src/main/ets/PhoneChangeView.ets", "        this.releaseStepUp();\n", "", "R8"),
    ("提现执行器不通知订阅页", STEPUP_CONTROLLERS[0], "      this.pages.notify(s);\n", "", "R9"),
    ("钱包问号打回 Button(){CouliIcon}", WALLET_DS, "          SymbolGlyph(couliSymbol('help'))\n",
     "          Button({ type: ButtonType.Normal, stateEffect: true }) {\n            CouliIcon({ name: 'help', iconSize: 16, color: this.labelColor(item) })\n          }\n", "R10"),
    ("价格胶囊打回 Column 容器", SEARCH_VIEW, "    Text() {\n      Span(this.label)", "    Column() {\n      Span(this.label)", "R10"),
    ("价格半屏不写 keyboardAvoidMode", SEARCH_VIEW, "      keyboardAvoidMode: SheetKeyboardAvoidMode.NONE,\n      onAppear: () => {\n        this.attachPriceKeyboard();",
     "      onAppear: () => {\n        this.attachPriceKeyboard();", "R11"),
    ("价格半屏中段不按键盘压缩", SEARCH_VIEW, "        .height(this.priceMiddleHeight())\n", "", "R11"),
    ("钱包暂缓入账问号打回 Button(){CouliIcon}（D10-1894 原漏改）", WALLET_VIEW,
     "          SymbolGlyph(couliSymbol('help'))\n          .attributeModifier(new CouliGlyphTap(16, CouliColors.textSecondary, -CouliSpacing.space3, -14, -CouliSpacing.space3, -14))\n"
     "          .accessibilityLevel('yes')\n          .accessibilityRole(AccessibilityRoleType.BUTTON)\n",
     "          Button({ type: ButtonType.Normal, stateEffect: true }) {\n            CouliIcon({ name: 'help', iconSize: 16, color: CouliColors.textSecondary })\n          }\n"
     "          .width(48)\n          .height(48)\n          .margin({ top: -12, bottom: -12, left: -14, right: -14 })\n          .backgroundColor(Color.Transparent)\n", "R13"),
    ("钱包暂缓入账问号去掉 CouliGlyphTap", WALLET_VIEW,
     "          .attributeModifier(new CouliGlyphTap(16, CouliColors.textSecondary, -CouliSpacing.space3, -14, -CouliSpacing.space3, -14))\n", "", "R13"),
    # 评审 S2-1 变异 B / E / F：外层容器包住 SymbolGlyph + CouliGlyphTap，.id 挂在外层（取「最近组件」会误认成里面的 SymbolGlyph）
    ("钱包暂缓入账问号外包 Button、id 挂外层（评审 S2-1 变异 B）", WALLET_VIEW, PAUSED_GLYPH,
     "          Button({ type: ButtonType.Normal, stateEffect: true }) {\n            SymbolGlyph(couliSymbol('help'))\n  " + PAUSED_TAP + "          }\n"
     + PAUSED_A11Y, "R13"),
    ("钱包暂缓入账问号外包 Button(){Stack(){…}}、id 挂外层（评审 S2-1 变异 E）", WALLET_VIEW, PAUSED_GLYPH,
     "          Button({ type: ButtonType.Normal }) {\n            Stack() {\n              SymbolGlyph(couliSymbol('help'))\n    " + PAUSED_TAP
     + "            }\n          }\n" + PAUSED_A11Y, "R13"),
    ("钱包暂缓入账问号外包 Column、id 挂外层（评审 S2-1 变异 F）", WALLET_VIEW, PAUSED_GLYPH,
     "          Column() {\n            SymbolGlyph(couliSymbol('help'))\n  " + PAUSED_TAP + "          }\n" + PAUSED_A11Y, "R13"),
    # D10-1943 (c)：Button 参数带括号（stateEffect: !this.busy()）时原正则 [^)]* 漏判；改括号配平后必须打红
    ("钱包问号打回 Button(){CouliIcon}、参数带括号（D10-1943 (c)）", WALLET_DS, "          SymbolGlyph(couliSymbol('help'))\n",
     "          Button({ type: ButtonType.Normal, stateEffect: !this.busy() }) {\n            CouliIcon({ name: 'help', iconSize: 16, color: this.labelColor(item) })\n          }\n", "R10"),
    ("提现页问号打回 Button(){CouliIcon}、参数带括号（D10-1943 (c)）", WITHDRAW_VIEW, "            SymbolGlyph(couliSymbol('help'))\n",
     "            Button({ type: ButtonType.Normal, stateEffect: this.enabledFor(this.model.phase) }) {\n              CouliIcon({ name: 'help', iconSize: 16, color: CouliColors.textSecondary })\n            }\n", "R10"),
    ("钱包暂缓入账问号打回 Button(){CouliIcon}、参数带括号（D10-1943 (c)）", WALLET_VIEW, PAUSED_GLYPH,
     "          Button({ type: ButtonType.Normal, stateEffect: !this.inactive() }) {\n            CouliIcon({ name: 'help', iconSize: 16, color: CouliColors.textSecondary })\n          }\n", "R13"),
    ("CouliButton 内部 Text 不可获焦（原写法）", BASICS, "          .focusable(true)\n      }\n      .justifyContent(FlexAlign.Center)",
     "      }\n      .justifyContent(FlexAlign.Center)", "R12"),
]


# ---------------------------------------------------------------- R14 自测件（button-child-focus-sweep.md §6.2）

def r14_page(body):
    return ("@ComponentV2\nstruct R14Probe {\n  @Local a: boolean = false;\n\n  @Builder\n  glyph() {\n    CouliIcon({ name: 'close' })\n  }\n\n"
            "  build() {\n    Column() {\n" + body + "\n    }\n  }\n}\n")


R14_SYN_RED = [
    ("Button(){CouliIcon}", "      Button({ type: ButtonType.Normal }) {\n        CouliIcon({ name: 'close', iconSize: 20 })\n      }\n      .id('x')\n      .onClick(() => {})"),
    ("Button(){CouliIcon} 外层 focusable(true)（探针 1 问号 / 眼睛）",
     "      Button({ type: ButtonType.Normal }) {\n        CouliIcon({ name: 'close' })\n      }\n      .focusable(true)\n      .id('x')"),
    ("Button(){Text}（AgentCards:630 原样）", "      Button({ type: ButtonType.Normal, stateEffect: false }) {\n        Text(this.t('a'))\n"
     "          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))\n      }\n"
     "      .position({ x: 0, y: 0 })\n      .hitTestBehavior(HitTestMode.None)\n      .id(AgentReportIds.entry(this.replyKey()))\n      .focusable(true)"),
    ("Button(){Row{SymbolGlyph, Text}}", "      Button() {\n        Row() {\n          SymbolGlyph($r('sys.symbol.xmark'))\n          Text('x')\n        }\n      }\n      .id('x')"),
    ("Button(){Row(){Text}.focusable(true)}（focusable 在容器上，probe_col）",
     "      Button() {\n        Row() {\n          Text('x')\n        }\n        .focusable(true)\n      }\n      .id('x')"),
    ("Button(){Stack(){CouliIcon}.focusable(true)}", "      Button() {\n        Stack() {\n          CouliIcon({ name: 'close' })\n        }\n        .focusable(true)\n      }"),
    ("Button(){this.glyph()}（builder 看不穿）", "      Button({ type: ButtonType.Circle }) {\n        this.glyph()\n      }\n      .id('x')"),
    ("Button({ stateEffect: !this.busy() }){CouliIcon}（参数带括号）",
     "      Button({ type: ButtonType.Normal, stateEffect: !this.busy() }) {\n        CouliIcon({ name: 'help' })\n      }\n      .id('x')"),
    ("Button(){if LoadingProgress else CouliIcon}", "      Button() {\n        if (this.a) {\n          LoadingProgress()\n        } else {\n"
     "          CouliIcon({ name: 'close' })\n        }\n      }\n      .enabled(!this.a)\n      .id('x')"),
    ("Button(){if (a) {Text.focusable(true)}}（没有 else：a 为假时子树为空）",
     "      Button() {\n        if (this.a) {\n          Text('x').focusable(true)\n        }\n      }\n      .id('x')"),
    ("Button(){if LoadingProgress else 可获焦 Text} 但没有 .enabled(（加载态可点却不可获焦）",
     "      Button() {\n        if (this.a) {\n          LoadingProgress()\n        } else {\n          Text('x').focusable(true)\n        }\n      }\n      .id('x')"),
    ("Button(){Text(){Span}}（Span 块后没有 focusable）", "      Button() {\n        Text() {\n          Span('x')\n        }\n      }\n      .id('x')"),
    ("Text 的 focusable 写在下一个兄弟组件上", "      Button() {\n        Row() {\n          Text('x')\n          Blank().focusable(true)\n        }\n      }"),
]

R14_SYN_OK = [
    ("CouliButton", "      CouliButton({ text: 'x', onTap: () => {} })\n        .id('x')"),
    ("Button('label')", "      Button('label')\n        .id('x')\n        .onClick(() => {})"),
    ("Button(label, options)", "      Button(this.t('a'), { type: ButtonType.Capsule })\n        .id('x')"),
    ("Button(){Row{Text.focusable(true)}}（CouliButton 结构）",
     "      Button({ type: ButtonType.Normal, stateEffect: !this.inactive() }) {\n        Row() {\n          if (this.a) {\n            LoadingProgress()\n          }\n"
     "          Text('x')\n            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold, true))\n"
     "            // 注释夹在链中间\n            .focusable(true)\n        }\n      }\n      .id('x')"),
    ("SymbolGlyph + CouliGlyphTap", "      SymbolGlyph(couliSymbol('help'))\n        .attributeModifier(new CouliGlyphTap(16, CouliColors.textSecondary))\n"
     "        .focusable(true)\n        .id('x')\n        .onClick(() => {})"),
    ("Toggle({ type: ToggleType.Button })", "      Toggle({ type: ToggleType.Button, isOn: this.a }) {\n        Text('x')\n      }\n      .id('x')"),
    ("注释里的旧写法", "      // Button() { CouliIcon({ name: 'close' }) }\n      /* Button() { Text('x') } */\n      Text('y')"),
    ("字符串里的旧写法", "      Text('Button() { CouliIcon({ name: 1 }) }')"),
    ("Button(){Stack{SymbolGlyph.focusable(true)}}（首页弹窗关闭修法）",
     "      Button({ type: ButtonType.Normal, stateEffect: false }) {\n        Stack() {\n          SymbolGlyph(couliSymbol('close'))\n            .fontSize(24 + 'vp')\n"
     "            .accessibilityLevel('no')\n            .focusable(true)\n        }\n        .width(40)\n      }\n      .id('home_popup_close')"),
    ("Button(){if LoadingProgress else SymbolGlyph.focusable(true)} + .enabled(（待跟单关闭修法）",
     "      Button() {\n        if (this.a) {\n          LoadingProgress().width(20)\n        } else {\n          SymbolGlyph(couliSymbol('close'))\n            .focusable(true)\n        }\n      }\n"
     "      .enabled(!this.a)\n      .id('x')"),
    ("Button(){if A else B} 两支都有可获焦叶子", "      Button() {\n        if (this.a) {\n          Text('a').focusable(true)\n        } else if (this.b) {\n"
     "          Text('b').focusable(true)\n        } else {\n          Image($r('app.media.x')).focusable(true)\n        }\n      }"),
    ("Button(){Text(){Span}.focusable(true)}", "      Button() {\n        Text() {\n          Span('x')\n        }\n        .focusable(true)\n      }"),
    ("Button(){CouliIcon}.focusable(false)（有意不进键盘路径）", "      Button() {\n        CouliIcon({ name: 'close' })\n      }\n      .focusable(false)\n      .onClick(() => {})"),
    ("Button(){CouliIcon} 纯装饰（accessibilityLevel('no')、无 onClick）", "      Button() {\n        CouliIcon({ name: 'close' })\n      }\n      .accessibilityLevel('no')"),
]

AGENT_CARDS = "features/agent/src/main/ets/AgentCards.ets"
FOCUS_CMT_T = ("// FU-HM-ROOTSHOWN-CHAIN（D10-1943 (b)，同 CouliButton）：带子组件的 Button 只有子树里有可获焦叶子时才可获焦；"
               "内部 Text 可获焦后整按钮进焦点链。\n")
GLYPH_CMT = "// FU-HM-ROOTSHOWN-CHAIN（D10-1943 (b)）：原 CouliIcon 根是 Stack（不可获焦），整按钮在设备上不可获焦；换成同尺寸、可获焦的 SymbolGlyph 叶子，外层 Button 不动。\n"


def glyph_src(ind, name, size, color):
    return (ind + GLYPH_CMT + ind + "SymbolGlyph(couliSymbol(" + name + "))\n" + ind + "  .fontSize(" + str(size) + " + 'vp')\n" + ind
            + "  .fontColor([" + color + "])\n" + ind + "  .width(" + str(size) + ")\n" + ind + "  .height(" + str(size) + ")\n" + ind
            + "  .accessibilityLevel('no')\n" + ind + "  .focusable(true)\n")


# 真实文件副本上的 R14 反例：把本批修好的入口打回原写法，必须被 R14 打红（D10-1943 (b) 防回退）
R14_REAL_MUTANTS = [
    ("读屏举报入口内部 Text 去掉 focusable(true)（D10-1943 (b) 原缺陷 AgentCards:630）", AGENT_CARDS,
     "            " + FOCUS_CMT_T + "            .focusable(true)\n        }\n        .height(CouliInteraction.minTouchTarget)\n        .position({ x: 0, y: 0 })",
     "        }\n        .height(CouliInteraction.minTouchTarget)\n        .position({ x: 0, y: 0 })"),
    ("读屏举报入口 focusable(true) 挪到 Button 链上", AGENT_CARDS,
     "            " + FOCUS_CMT_T + "            .focusable(true)\n        }\n", "        }\n        .focusable(true)\n"),
    ("游客价值卡【登录领返利】内部 Text 去掉 focusable(true)", "features/home/src/main/ets/HomeTiles.ets",
     "          " + FOCUS_CMT_T + "          .focusable(true)\n", ""),
    ("首页弹窗关闭打回 Stack{CouliIcon}", "features/home/src/main/ets/HomeCards.ets", glyph_src("          ", "'close'", 24, "CouliColors.textPrimary"),
     "          CouliIcon({ name: 'close', iconSize: 24, color: CouliColors.textPrimary })\n"),
    ("待跟单卡关闭 else 分支打回 CouliIcon", "entry/src/main/ets/orders/PendingTrackViews.ets",
     glyph_src("            ", "'close'", 22, "CouliColors.textSecondary"), "            CouliIcon({ name: 'close', iconSize: 22, color: CouliColors.textSecondary })\n"),
    ("二次验证半屏关闭里的叶子去掉 focusable(true)", "common/designsystem/src/main/ets/components/StepUpPanel.ets",
     "                .accessibilityLevel('no')\n                .focusable(true)\n", "                .accessibilityLevel('no')\n"),
    ("订单列表眼睛打回 Button(){CouliIcon}", "features/orders/src/main/ets/OrderListView.ets",
     "      SymbolGlyph(couliSymbol(this.config.mask.masked ? 'eye-off' : 'eye'))\n      .attributeModifier(new CouliGlyphTap(22, CouliColors.textSecondary))\n",
     "      Button({ type: ButtonType.Normal, stateEffect: true }) {\n        CouliIcon({ name: this.config.mask.masked ? 'eye-off' : 'eye', iconSize: 22, color: CouliColors.textSecondary })\n      }\n"),
    ("识别卡动作内部 Text 去掉 focusable(true)", "common/designsystem/src/main/ets/components/Clipboard.ets",
     "        " + FOCUS_CMT_T + "        .focusable(true)\n    }\n", "    }\n"),
    ("新文件里新写 Button(){CouliIcon}（不在豁免表）", "features/home/src/main/ets/R14New.ets", None,
     r14_page("      Button() {\n        CouliIcon({ name: 'close' })\n      }\n      .id('home_new_close')")),
    ("豁免过的文件里再多一处同键命中（每条只放一处）", "features/me/src/main/ets/SettingsView.ets", None, "APPEND:"
     + r14_page("      Button() {\n        CouliIcon({ name: 'close' })\n      }\n      .id('nickname_clear')")),
    ("staging 里新写 Button(){Text}（staging 不整目录豁免）", "entry/src/staging/ets/catalog/R14New.ets", None,
     r14_page("      Button() {\n        Text('x')\n      }\n      .id('catalog-new')")),
]

# 豁免表本身的反例
R14_EXEMPT_MUTANTS = [
    ("豁免条目已无对应命中（文件删了 / 已修）", "DROP", "features/me/src/main/ets/MeTabView.ets"),
    ("豁免条目用通配", "ADD", ("features/me/src/main/ets/*.ets", "id:*", R14_FU, "通配")),
    ("豁免条目没写 FU 号", "ADD", ("features/home/src/main/ets/R14New.ets", "id:'x'", "", "没有 FU")),
    ("豁免条目没写理由", "ADD", ("features/home/src/main/ets/R14New.ets", "id:'x'", R14_FU, "")),
    ("豁免条目重复", "ADD", R14_EXEMPT[0]),
]


def r14_self_test(real_files):
    bad = 0
    n_kill = n_ok = 0
    for name, body in R14_SYN_RED:
        got = r14_judge({"features/r14/Probe.ets": r14_page(body)}, [])
        if not any(x.startswith("R14") for x in got):
            print("SELFTEST R14 反例没被杀：%s" % name)
            bad += 1
        else:
            n_kill += 1
            print("  杀掉 [R14] 合成件：%s" % name)
    for name, body in R14_SYN_OK:
        got = r14_judge({"features/r14/Probe.ets": r14_page(body)}, [])
        if got:
            print("SELFTEST R14 良性写法被误报：%s：%s" % (name, got))
            bad += 1
        else:
            n_ok += 1
            print("  不误报 [R14] 合成件：%s" % name)
    got = r14_judge(real_files, R14_EXEMPT)
    if got:
        print("SELFTEST R14 真实副本不过：%s" % got)
        bad += 1
    for name, rel, old, new in R14_REAL_MUTANTS:
        files = dict(real_files)
        if old is None:
            files[rel] = (files.get(rel, "") + new[len("APPEND:"):]) if new.startswith("APPEND:") else new
            if new.startswith("APPEND:") and rel not in real_files:
                print("SELFTEST R14 反例目标文件不在真实副本里：" + name)
                bad += 1
                continue
        else:
            if files.get(rel, "").count(old) != 1:
                print("SELFTEST R14 反例原串不在真实文件里（锚点变了）：" + name)
                bad += 1
                continue
            files[rel] = files[rel].replace(old, new, 1)
        got = r14_judge(files, R14_EXEMPT)
        if not any(x.startswith("R14") for x in got):
            print("SELFTEST R14 真实副本反例没被杀：%s" % name)
            bad += 1
        else:
            n_kill += 1
            print("  杀掉 [R14] 真实副本：%s" % name)
    for name, kind, arg in R14_EXEMPT_MUTANTS:
        files = dict(real_files)
        exempt = list(R14_EXEMPT)
        if kind == "DROP":
            files.pop(arg, None)
        else:
            exempt.append(arg)
        got = r14_judge(files, exempt)
        if not any(x.startswith("R14") for x in got):
            print("SELFTEST R14 豁免表反例没被杀：%s" % name)
            bad += 1
        else:
            n_kill += 1
            print("  杀掉 [R14] 豁免表：%s" % name)
    return bad, n_kill, n_ok


# 真实文件副本上的良性改写（评审 S2-1 的 G / H / I：同一 SymbolGlyph 叶子换种排版，R13 不得误报）
UI_BENIGN = [
    ("暂缓入账问号链缩进 +2（Wallet.ets 风格，评审 G）", WALLET_VIEW, PAUSED_GLYPH,
     "          SymbolGlyph(couliSymbol('help'))\n  " + PAUSED_TAP + "            .accessibilityLevel('yes')\n            .accessibilityRole(AccessibilityRoleType.BUTTON)\n"),
    ("暂缓入账问号 CouliGlyphTap 参数换行（评审 H）", WALLET_VIEW, PAUSED_TAP,
     "          .attributeModifier(new CouliGlyphTap(16, CouliColors.textSecondary,\n            -CouliSpacing.space3, -14, -CouliSpacing.space3, -14))\n"),
    ("暂缓入账问号 SymbolGlyph 参数换行（评审 I）", WALLET_VIEW, "          SymbolGlyph(couliSymbol('help'))\n",
     "          SymbolGlyph(\n            couliSymbol('help'))\n"),
]


# ---------------------------------------------------------------- 自测（合成参照件 + 反例 + 良性改写）

REF = {
    SHELL: """import { RootShownRegistry, RouteDestination } from 'core';
export class ShellState {
  static readonly onRootShown: RootShownRegistry = new RootShownRegistry();

  static rootShown(destination: RouteDestination): void {
    if (destination.route === null) {
      return;
    }
    ShellState.onRootShown.dispatch(destination);
  }
}
""",
    REGISTRY: """export class RootShownRegistry {
  private keys: string[] = [];
  private listeners: ((destination: RouteDestination) => void)[] = [];

  register(key: string, listener: (destination: RouteDestination) => void): void {
    const i: number = this.keys.indexOf(key);
    if (i >= 0) {
      this.listeners[i] = listener;
      return;
    }
    this.keys.push(key);
    this.listeners.push(listener);
  }

  unregister(key: string): void {
    const i: number = this.keys.indexOf(key);
    if (i < 0) {
      return;
    }
    this.keys.splice(i, 1);
    this.listeners.splice(i, 1);
  }

  dispatch(destination: RouteDestination): void {
    for (const l of this.listeners.slice()) {
      try {
        l(destination);
      } catch (e) {
      }
    }
  }
}
""",
    ORDERS: """export class AppOrders {
  private context: common.Context | null = null;

  compose(context: common.Context): void {
    if (this.context !== null) {
      this.context = context;
      this.registerRootShown();
      return;
    }
    this.context = context;
    const cache: OrderStaleCache = new OrderStaleCache(store);
    this.registerRootShown();
  }

  private registerRootShown(): void {
    ShellState.onRootShown.register(RootShownRegistry.ORDERS, (destination: RouteDestination): void => {
      if (destination.route === ORDER_LIST_ROUTE) {
        this.showTab(destination);
      }
    });
  }
}
""",
    ME: """export class AppMe {
  private registerRootShown(): void {
    ShellState.onRootShown.register(RootShownRegistry.ME, (destination: RouteDestination): void => {
      if (destination.route === 'Me') {
        this.tab().autoLoad();
      }
    });
  }

  compose(context: common.UIAbilityContext): void {
    if (this.context !== null) {
      this.context = context;
      this.registerRootShown();
      return;
    }
    this.context = context;
    this.registerRootShown();
  }
}
""",
    AGENT: """export class AppAgent {
  compose(_context: common.Context): void {
    ShellState.onTabWillChange.register('agent', (route: string, _basic: boolean): void => {
      this.tabSelected = route === AGENT_ROUTE;
    });
    ShellState.onRootShown.register(RootShownRegistry.AGENT, (destination: RouteDestination): void => {
      if (destination.route === AGENT_ROUTE) {
        this.tabSelected = true;
        AgentVariant.onAgentShown((): AgentController | null => this.current);
      }
    });
    if (this.composed) {
      return;
    }
    this.composed = true;
  }
}
""",
    AGENT_ROOT: """export struct AgentTabRoot {
  @Builder
  header() {
    Column() {
      Row() {
        Text(this.t('agent.name'))
          .id(ID_TITLE)
          .focusable(true)
        ForEach([new ComposerState(this.model.snapshot, true)], (c: ComposerState) => {
          this.newChat(c.page, c.ready)
        }, (c: ComposerState) => 'header|' + c.key)
      }
    }
  }

  @Builder
  newChat(page: AgentPageTicket, ready: boolean) {
    if (ready) {
      Row() {}
    }
  }

  build() {
    Column() {
      this.header()
    }
  }
}
""",
}

ORIG_ORDERS_DEFECT = """    ShellState.onRootShown = (destination: RouteDestination): void => {
      if (destination.route === ORDER_LIST_ROUTE) {
        this.showTab(destination);
      }
    };
"""

MUTANTS = [
    # (名字, 文件, 原串, 新串, 期望命中的规则前缀)
    ("订单直接赋值（原缺陷 AppOrders.ets:211）", ORDERS,
     "    this.registerRootShown();\n  }\n\n  private", "    " + ORIG_ORDERS_DEFECT.strip() + "\n  }\n\n  private", "R1"),
    ("「我的」包 previous 直接赋值（原写法）", ME,
     "    this.registerRootShown();\n  }\n}",
     "    const previous: (destination: RouteDestination) => void = ShellState.onRootShown;\n"
     "    ShellState.onRootShown = (destination: RouteDestination): void => {\n      previous(destination);\n    };\n  }\n}", "R1"),
    ("用 ??= 赋值", AGENT, "    if (this.composed) {", "    ShellState.onRootShown ??= x;\n    if (this.composed) {", "R1"),
    ("下标写法赋值", AGENT, "    if (this.composed) {", "    ShellState['onRootShown'] = x;\n    if (this.composed) {", "R1"),
    ("当函数调用", SHELL, "ShellState.onRootShown.dispatch(destination);", "ShellState.onRootShown(destination);", "R1"),
    ("ShellState 字段不是 readonly", SHELL, "static readonly onRootShown", "static onRootShown", "R2"),
    ("rootShown 不分发", SHELL, "    ShellState.onRootShown.dispatch(destination);\n", "", "R2"),
    ("同名登记叠加", REGISTRY, "    if (i >= 0) {\n      this.listeners[i] = listener;\n      return;\n    }\n", "", "R3"),
    ("没有 unregister", REGISTRY, "  unregister(key: string): void {", "  drop(key: string): void {", "R3"),
    ("分发不隔离", REGISTRY, "      try {\n        l(destination);\n      } catch (e) {\n      }\n", "      l(destination);\n", "R3"),
    ("订单不登记", ORDERS, "ShellState.onRootShown.register(RootShownRegistry.ORDERS,", "ShellState.onTabWillChange.register('orders',", "R4"),
    ("「我的」登记成订单的名", ME, "RootShownRegistry.ME,", "RootShownRegistry.ORDERS,", "R4"),
    ("「我的」回调改 load", ME, "this.tab().autoLoad();", "this.tab().load();", "R4"),
    ("Agent 回调不发启动消息", AGENT, "        AgentVariant.onAgentShown((): AgentController | null => this.current);\n", "", "R4"),
    ("订单 compose 无重入保护（原缺陷 AppOrders.ets:185）", ORDERS,
     "    if (this.context !== null) {\n      this.context = context;\n      this.registerRootShown();\n      return;\n    }\n", "", "R5"),
    ("订单重入分支不 return", ORDERS, "      this.registerRootShown();\n      return;\n    }\n    this.context = context;\n    const cache",
     "      this.registerRootShown();\n    }\n    this.context = context;\n    const cache", "R5"),
    ("「我的」重入分支不重登", ME, "      this.context = context;\n      this.registerRootShown();\n      return;",
     "      this.context = context;\n      return;", "R5"),
    ("订单重入分支重建对象", ORDERS, "      this.registerRootShown();\n      return;",
     "      const c: OrderStaleCache = new OrderStaleCache(store);\n      this.registerRootShown();\n      return;", "R5"),
    ("Agent 登记挪到 composed 之后", AGENT,
     "    if (this.composed) {\n      return;\n    }\n    this.composed = true;\n",
     "    this.composed = true;\n", "R5"),
    ("页面标题回到 ForEach（原缺陷 AgentTabRoot.ets:529-532）", AGENT_ROOT,
     "    Column() {\n      this.header()\n    }",
     "    Column() {\n      ForEach([1], (c: number) => {\n        this.header()\n      }, (c: number) => 'header|' + c)\n    }", "R6"),
    ("标题直接写在 ForEach 项里", AGENT_ROOT,
     "        ForEach([new ComposerState(this.model.snapshot, true)], (c: ComposerState) => {\n          this.newChat(c.page, c.ready)\n",
     "        ForEach([new ComposerState(this.model.snapshot, true)], (c: ComposerState) => {\n          Text('x').id(ID_TITLE)\n          this.newChat(c.page, c.ready)\n", "R6"),
]

BENIGN = [
    ("注释里写着旧写法", ORDERS, "  private registerRootShown(): void {",
     "  // 旧：ShellState.onRootShown = (d) => {...}; 已废\n  /* ShellState.onRootShown(destination) */\n  private registerRootShown(): void {"),
    ("字符串里提到 onRootShown =", AGENT, "    if (this.composed) {", "    hilog.info(0, 'T', 'x.onRootShown = y');\n    if (this.composed) {"),
    ("比较不是赋值", SHELL, "    if (destination.route === null) {", "    if (destination.route === null || ShellState.onRootShown === null) {"),
    ("Agent 重入判断写成 return 早退的同义块", AGENT, "    if (this.composed) {\n      return;\n    }",
     "    if (this.composed) {\n      // 已装配\n      return;\n    }"),
]


def write_tree(dest, files):
    for rel, text in files.items():
        p = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)


def run_on(files):
    tmp = tempfile.mkdtemp(prefix="rootshown-")
    try:
        write_tree(tmp, files)
        return check_chain(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def self_test():
    bad = 0
    base = run_on(REF)
    if base:
        print("SELFTEST 参照件不过：")
        for x in base:
            print("  " + x)
        bad += 1
    for name, rel, old, new, rule in MUTANTS:
        if old not in REF[rel]:
            print("SELFTEST 反例原串不在参照件里：" + name)
            bad += 1
            continue
        files = dict(REF)
        files[rel] = REF[rel].replace(old, new, 1)
        try:
            got = run_on(files)
        except Incomplete as e:
            got = ["INCOMPLETE " + str(e)]
        if not any(x.startswith(rule) for x in got):
            print("SELFTEST 反例没被杀（期望 %s）：%s；实际 %s" % (rule, name, got))
            bad += 1
        else:
            print("  杀掉 [%s] %s" % (rule, name))
    for name, rel, old, new in BENIGN:
        if old not in REF[rel]:
            print("SELFTEST 良性改写原串不在参照件里：" + name)
            bad += 1
            continue
        files = dict(REF)
        files[rel] = REF[rel].replace(old, new, 1)
        got = run_on(files)
        if got:
            print("SELFTEST 良性改写被误报：%s：%s" % (name, got))
            bad += 1
        else:
            print("  不误报 %s" % name)
    # 真实文件副本：把原缺陷（订单直接赋值 + 去掉重入保护）打回本仓库的 AppOrders，必须被 R1 / R5 打红。
    real = {}
    try:
        for rel in (SHELL, REGISTRY, ORDERS, ME, AGENT, AGENT_ROOT):
            real[rel] = read(REPO_ROOT, rel)
    except Incomplete as e:
        print("SELFTEST 真实副本读不全：" + str(e))
        return 1
    o = real[ORDERS]
    if "    this.registerRootShown();\n    AppRouting.shared.syncOrders" in o:
        o2 = o.replace("    this.registerRootShown();\n    AppRouting.shared.syncOrders",
                       ORIG_ORDERS_DEFECT + "    AppRouting.shared.syncOrders", 1)
        o2 = re.sub(r"    if \(this\.context !== null\) \{\n      this\.context = context;\n      this\.registerRootShown\(\);\n      return;\n    \}\n",
                    "", o2, count=1)
        files = dict(real)
        files[ORDERS] = o2
        got = run_on(files)
        if not (any(x.startswith("R1") for x in got) and any(x.startswith("R5") for x in got)):
            print("SELFTEST 真实副本打回原缺陷没被 R1 + R5 打红：%s" % got)
            bad += 1
        else:
            print("  杀掉 [R1+R5] 真实副本：AppOrders 打回原缺陷")
    else:
        print("SELFTEST 真实副本：AppOrders 里找不到 registerRootShown 接线（锚点变了，更新自测）")
        bad += 1
    # D10-1668：本仓库真实文件副本整体须 0 违反；每条 UI 反例打回原写法须被对应规则打红。
    real_ui = {}
    try:
        for rel in (SHELL, REGISTRY, ORDERS, ME, AGENT, AGENT_ROOT) + tuple(UI_FILES) + tuple(wallet_pages(REPO_ROOT)):
            real_ui[rel] = read(REPO_ROOT, rel)
    except Incomplete as e:
        print("SELFTEST 真实副本读不全：" + str(e))
        return 1

    def run_full(files):
        tmp = tempfile.mkdtemp(prefix="rootshown-ui-")
        try:
            write_tree(tmp, files)
            return check_chain(tmp) + check_ui(tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    got = run_full(real_ui)
    if got:
        print("SELFTEST 真实副本（R1–R13）不过：%s" % got)
        bad += 1
    for name, rel, old, new, rule in UI_MUTANTS:
        if real_ui[rel].count(old) < 1:
            print("SELFTEST UI 反例原串不在真实文件里（锚点变了）：" + name)
            bad += 1
            continue
        files = dict(real_ui)
        files[rel] = real_ui[rel].replace(old, new, 1)
        try:
            got = run_full(files)
        except Incomplete as e:
            got = ["INCOMPLETE " + str(e)]
        if not any(x.startswith(rule) for x in got):
            print("SELFTEST UI 反例没被杀（期望 %s）：%s；实际 %s" % (rule, name, got))
            bad += 1
        else:
            print("  杀掉 [%s] 真实副本：%s" % (rule, name))
    for name, rel, old, new in UI_BENIGN:
        if real_ui[rel].count(old) < 1:
            print("SELFTEST UI 良性改写原串不在真实文件里（锚点变了）：" + name)
            bad += 1
            continue
        files = dict(real_ui)
        files[rel] = real_ui[rel].replace(old, new, 1)
        got = run_full(files)
        if got:
            print("SELFTEST UI 良性改写被误报：%s：%s" % (name, got))
            bad += 1
        else:
            print("  不误报 真实副本：%s" % name)
    try:
        r14_real = r14_files(REPO_ROOT)
    except Incomplete as e:
        print("SELFTEST R14 真实副本读不全：" + str(e))
        return 1
    r14_bad, r14_kill, r14_ok = r14_self_test(r14_real)
    bad += r14_bad
    if bad:
        print("ROOTSHOWN_SELFTEST_FAIL %d" % bad)
        return 1
    print("ROOTSHOWN_SELFTEST_OK（%d 反例全杀，%d 良性改写不误报；参照件不算产品通过）"
          % (len(MUTANTS) + 1 + len(UI_MUTANTS) + r14_kill, len(BENIGN) + len(UI_BENIGN) + r14_ok))
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
        v = check(os.path.abspath(args.root))
    except Incomplete as e:
        print("ROOTSHOWN_INCOMPLETE " + str(e))
        return 4
    if v:
        for x in v:
            print(x)
        print("ROOTSHOWN_HOST_FAIL %d" % len(v))
        return 1
    print("ROOTSHOWN_HOST_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
