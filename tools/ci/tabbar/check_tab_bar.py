#!/usr/bin/env python3
"""FU-HM-TAB-BAR-harmony（书 §3.1，D10-824 ③ / D10-909）：底栏改系统 BottomTabBarStyle + TabBarSymbol 的宿主守卫。

用法：
    python3 tools/ci/tabbar/check_tab_bar.py [--root <目录>]    # 检查（默认仓库根）
    python3 tools/ci/tabbar/check_tab_bar.py --self-test        # 合成 fixtures 跑每条规则的正反例与变异，全部要杀

退出码：0 通过；1 有违反（自测：有变异没被杀或正例不过）；2 参数不对；3 解析工具链不可用（复用 lint.hm10_toolchain，node + 鸿蒙 SDK ohos-typescript）；
4 无法保证判定完整（文件缺失、语法错误）。解析错误不算「红在断言」，一律 4。

解析与判定在 tools/ci/tabbar/tabbar_ast.cjs（AST，不用正则切块；注释与字符串里的字不算）。规则编号对应书 §3.1：
    T1 每个 TabContent.tabBar 实参来自返回 BottomTabBarStyle 的方法；图标 {normal, selected} 都是 SymbolGlyphModifier；符号表覆盖五个 icon，选中用 fill（search 除外）
    T2 TabBar 内无 CouliIcon、@Builder、Badge、badgeIndex、animationDuration、divider、barBackgroundColor、barBackgroundBlurStyle、三个 accessibility 属性、font:
    T3 labelStyle 恰含 selectedColor: textLink / unselectedColor: textSecondary；图标 fontColor 选中 brandPrimary、未选 textSecondary
    T4 TabBarItem 构造只有 label, icon；全仓（common / entry / features 的 .ets、.ts）无 tabPosition、badgeIndex
    T5 AppShell 底栏外层 Column 无 backgroundColor(surface)，有且仅一处 backgroundBlurStyle(BlurStyle.COMPONENT_THICK)，expandSafeArea 仍在
    T6 TabBar 不声明 @Local / @Trace / @Provider 下标，也不写 selectedIndex（选中只跟宿主）
    T7 CatalogManifest 的 TabBar 条目不含「只接图片」和 badge，变体为 symbol；inventory.tsv 的 TabBar 变体为 symbol
    T8（测试 v3，书外接线）List.test.ets 的 testsuite 直接调用 tabBarShellUiTest(); 恰好一次并有对应 import；device-test.sh 的 $DEVICE_SET 校验 case 认 tabbar
测试 v3 收紧 T1（T1-source：符号来自模块级符号表函数、按项的 icon 分支，防四项同一图标）与 T5（底栏外层、TabBar、Tabs 上不许有任何底色，不只 surface）。
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
AST_TOOL = os.path.join(HERE, "tabbar_ast.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")

NAV = "common/designsystem/src/main/ets/components/Navigation.ets"
SHELL = "entry/src/main/ets/shell/AppShell.ets"
CATALOG = "entry/src/staging/ets/catalog/CatalogManifest.ets"
INVENTORY = "tools/ci/ds02/fixtures/inventory.tsv"
LIST_TEST = "entry/src/ohosTest/ets/test/List.test.ets"
DEVICE_TEST = "tools/ci/device-test.sh"
SCAN_DIRS = ("common", "entry", "features")
SKIP_DIRS = {"build", "oh_modules", "node_modules", ".hvigor", ".test", ".preview"}
RESIDUE = ("tabPosition", "badgeIndex")
RULE_TITLES = {
    "T1": "TabContent.tabBar 用 BottomTabBarStyle + 符号表",
    "T2": "TabBar 内无自绘 / 禁用项",
    "T3": "选中色（labelStyle / 图标 fontColor）",
    "T4": "TabBarItem 只有 label, icon；全仓无残留",
    "T5": "外壳底栏单层系统材质 + expandSafeArea",
    "T6": "无本地选中态（选中只跟宿主）",
    "T7": "目录与 inventory 变体 symbol",
    "T8": "设备套件已注册、device-test.sh 认 tabbar",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_tabbar", os.path.join(HERE, "..", "lint.py"))
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


def residue_candidates(root):
    """全仓候选（子串预筛，再由 AST 判是否真是标识符）。"""
    out = {}
    for top in SCAN_DIRS:
        base = os.path.join(root, top)
        for cur, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in files:
                if not name.endswith((".ets", ".ts")) or name.endswith(".d.ts"):
                    continue
                path = os.path.join(cur, name)
                rel = os.path.relpath(path, root).replace(os.sep, "/")
                try:
                    with open(path, encoding="utf-8") as f:
                        text = f.read()
                except (OSError, UnicodeDecodeError) as e:
                    raise Incomplete("%s: 读不出（%s），全仓扫描无法保证完整" % (rel, e))
                if any(word in text for word in RESIDUE):
                    out[rel] = text
    return out


def check_inventory(root):
    text = read(root, INVENTORY)
    if text is None:
        raise Incomplete("%s: 文件不存在，无法判定" % INVENTORY)
    rows = [line.split("\t") for line in text.splitlines() if line.startswith("TabBar\t")]
    if len(rows) != 1:
        return [{"rule": "T7-inventory", "file": INVENTORY, "line": 0, "msg": "inventory 里 TabBar 行应恰好一条，实际 %d" % len(rows)}]
    if len(rows[0]) < 4 or rows[0][3] != "symbol":
        got = rows[0][3] if len(rows[0]) > 3 else "（缺列）"
        return [{"rule": "T7-inventory", "file": INVENTORY, "line": 0, "msg": "inventory 的 TabBar 变体必须是 symbol，实际 %s" % got}]
    return []


def check_device_set(root):
    """device-test.sh 校验 $DEVICE_SET 的 case 行必须认 tabbar（注释里提到不算）。"""
    text = read(root, DEVICE_TEST)
    if text is None:
        raise Incomplete("%s: 文件不存在，无法判定" % DEVICE_TEST)
    rows = [m for m in (re.match(r'\s*case\s+"\$DEVICE_SET"\s+in\s+([^)]*)\)', line) for line in text.splitlines()) if m]
    if len(rows) != 1:
        return [{"rule": "T8-device-set", "file": DEVICE_TEST, "line": 0, "msg": "$DEVICE_SET 的校验 case 行应恰好一条，实际 %d" % len(rows)}]
    if "tabbar" not in [item.strip() for item in rows[0].group(1).split("|")]:
        return [{"rule": "T8-device-set", "file": DEVICE_TEST, "line": 0, "msg": "$DEVICE_SET 的校验 case 不认 tabbar：%s" % rows[0].group(1)}]
    return []


def check(root):
    """返回违反列表；文件缺失 / 语法错误抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
    tool = lint.hm10_toolchain()
    scan = residue_candidates(root)
    files = dict(scan)
    for rel in (NAV, SHELL, CATALOG, LIST_TEST):
        text = read(root, rel)
        if text is None:
            raise Incomplete("%s: 文件不存在，无法判定" % rel)
        files[rel] = text
    payload = json.dumps({"files": files, "scan": sorted(scan)}, ensure_ascii=False).encode("utf-8")
    try:
        proc = subprocess.run([tool["node"], AST_TOOL, tool["typescript"]], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise lint.HM10ToolchainError("运行 node 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("tabbar_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("tabbar_ast.cjs 输出无法解析：%s" % e)
    if out["incomplete"]:
        raise Incomplete("；".join(out["incomplete"]))
    return out["violations"] + check_inventory(root) + check_device_set(root)


def render(violations):
    groups = {}
    for v in violations:
        groups.setdefault(v["rule"].split("-")[0], []).append(v)
    for key in sorted(RULE_TITLES):
        state = "红" if key in groups else "绿"
        print("%s %s：%s（%d 处）" % (key, state, RULE_TITLES[key], len(groups.get(key, []))))
    for v in sorted(violations, key=lambda x: (x["rule"], x["file"], x["line"])):
        print("  [%s] %s:%d %s" % (v["rule"], v["file"], v["line"], v["msg"]))


# ---------------------------------------------------------------- 自测：合成 fixtures 的变异，全部要杀

NV, AS, CM, TR, LT, DT = NAV, SHELL, CATALOG, "entry/src/main/ets/shell/TabRoots.ets", LIST_TEST, DEVICE_TEST
# （名字，文件，原串，新串，应报的规则前缀）；原串必须唯一
MUTATIONS = [
    ("自绘 tabBar 回来（@Builder）", NV,
     "  private bar(item: TabBarItem): BottomTabBarStyle {",
     "  @Builder\n  bar2(item: TabBarItem) {\n    Column() { Text(item.label) }\n  }\n\n  private bar(item: TabBarItem): BottomTabBarStyle {", "T2-forbidden"),
    ("tabBar 直接传 @Builder 调用", NV, ".tabBar(this.bar(item))", ".tabBar(this.other(item))", "T1-bar-method"),
    ("bar 返回类型不是 BottomTabBarStyle", NV, "private bar(item: TabBarItem): BottomTabBarStyle {", "private bar(item: TabBarItem): SubTabBarStyle {", "T1-bar-method"),
    ("返回 SubTabBarStyle", NV, "return new BottomTabBarStyle({ normal: normal, selected: selected }, item.label)",
     "return new SubTabBarStyle(item.label)", "T1-style"),
    ("图标实参是资源", NV, "new BottomTabBarStyle({ normal: normal, selected: selected }, item.label)", "new BottomTabBarStyle($r('app.media.icon'), item.label)", "T1-symbol"),
    ("selected 缺失", NV, "{ normal: normal, selected: selected }", "{ normal: normal }", "T1-symbol"),
    ("selected 不是 SymbolGlyphModifier", NV, "new SymbolGlyphModifier(s.selected).fontColor([CouliColors.brandPrimary])", "this.other(s.selected)", "T1-symbol"),
    ("图标映射漏 fill（house）", NV, "$r('sys.symbol.house_fill')", "$r('sys.symbol.house')", "T1-map"),
    ("图标映射漏 fill（person）", NV, "$r('sys.symbol.person_fill')", "$r('sys.symbol.person')", "T1-map"),
    ("search 用了实心", NV, "selected: $r('sys.symbol.magnifyingglass')", "selected: $r('sys.symbol.magnifyingglass_fill')", "T1-map"),
    ("orders normal / selected 写反", NV, "normal: $r('sys.symbol.doc_plaintext'), selected: $r('sys.symbol.doc_plaintext_fill')",
     "normal: $r('sys.symbol.doc_plaintext_fill'), selected: $r('sys.symbol.doc_plaintext')", "T1-map"),
    ("chat 映射缺", NV, "case 'chat':", "case 'chat2':", "T1-map"),
    ("加回 CouliIcon", NV, "    const s: TabSymbols = symbolsOf(item.icon);", "    const s: TabSymbols = symbolsOf(item.icon);\n    CouliIcon({ name: item.icon, iconSize: 24 });", "T2-forbidden"),
    ("badgeIndex 加回", NV, "  @Param selectedIndex: number = 0;", "  @Param selectedIndex: number = 0;\n  @Param badgeIndex: number = -1;", "T2-forbidden"),
    ("animationDuration(0) 加回", NV, "    .scrollable(false)\n", "    .scrollable(false)\n    .animationDuration(0)\n", "T2-forbidden"),
    ("divider 加回", NV, "    .scrollable(false)\n", "    .scrollable(false)\n    .divider({ strokeWidth: 1 })\n", "T2-forbidden"),
    ("barBackgroundColor 加回", NV, "    .scrollable(false)\n", "    .scrollable(false)\n    .barBackgroundColor(CouliColors.backgroundSurface)\n", "T2-forbidden"),
    ("材质放到 Tabs（两处）", NV, "    .scrollable(false)\n", "    .scrollable(false)\n    .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)\n", "T2-forbidden"),
    ("accessibilityDescription 加回", NV, "    .scrollable(false)\n", "    .scrollable(false)\n    .accessibilityDescription('x')\n", "T2-forbidden"),
    ("accessibilitySelected 加回", NV, "    .scrollable(false)\n", "    .scrollable(false)\n    .accessibilitySelected(true)\n", "T2-forbidden"),
    ("accessibilityGroup 加回", NV, "    .scrollable(false)\n", "    .scrollable(false)\n    .accessibilityGroup(true)\n", "T2-forbidden"),
    ("labelStyle 传 font", NV, "unselectedColor: CouliColors.textSecondary })", "unselectedColor: CouliColors.textSecondary, font: { size: 12 } })", "T2-forbidden"),
    ("去掉 labelStyle", NV, "\n      .labelStyle({ selectedColor: CouliColors.textLink, unselectedColor: CouliColors.textSecondary })", "", "T3-label"),
    ("selectedColor 换色", NV, "selectedColor: CouliColors.textLink", "selectedColor: CouliColors.textPrimary", "T3-label"),
    ("unselectedColor 只给一端", NV, ", unselectedColor: CouliColors.textSecondary })", " })", "T3-label"),
    ("选中图标用 textLink", NV, "fontColor([CouliColors.brandPrimary])", "fontColor([CouliColors.textLink])", "T3-fontcolor"),
    ("未选图标无 fontColor", NV, "new SymbolGlyphModifier(s.normal).fontColor([CouliColors.textSecondary])", "new SymbolGlyphModifier(s.normal)", "T3-fontcolor"),
    ("TabBarItem 第三参回来", NV, "constructor(label: string, icon: string) {", "constructor(label: string, icon: string, accessibilityHint: string = '') {", "T4-ctor"),
    ("tabPosition 回来（标识符）", TR, "return new TabBarItem(shown.label, shown.icon);", "return new TabBarItem(shown.label, shown.icon + ShellDraftTexts.tabPosition(1, 2));", "T4-residue"),
    ("底栏白底回来", AS, ".backgroundBlurStyle(BlurStyle.COMPONENT_THICK)", ".backgroundColor(CouliColors.backgroundSurface)", "T5-background"),
    ("材质换档", AS, "BlurStyle.COMPONENT_THICK", "BlurStyle.COMPONENT_THIN", "T5-material"),
    ("材质放两处（再包一层 Column）", AS, "      .layoutWeight(1)\n", "      .layoutWeight(1)\n      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)\n", "T5-material"),
    ("TabBar 自己加材质", NV, "    .scrollable(false)\n", "    .scrollable(false)\n    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)\n", "T5-material"),
    ("删 expandSafeArea", AS, "\n      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])", "", "T5-safearea"),
    ("expandSafeArea 换边", AS, "[SafeAreaEdge.BOTTOM]", "[SafeAreaEdge.TOP]", "T5-safearea"),
    ("@Local 下标", NV, "  @Param selectedIndex: number = 0;", "  @Param selectedIndex: number = 0;\n  @Local localIndex: number = 0;", "T6-local-state"),
    ("@Trace 下标", NV, "  @Param selectedIndex: number = 0;", "  @Param selectedIndex: number = 0;\n  @Trace localIndex: number = 0;", "T6-local-state"),
    ("@Once selectedIndex", NV, "  @Param selectedIndex: number = 0;", "  @Param @Once selectedIndex: number = 0;", "T6-local-state"),
    ("写 selectedIndex", NV, "      this.onSelect(index);", "      this.selectedIndex = index;\n      this.onSelect(index);", "T6-write"),
    ("++ selectedIndex", NV, "      this.onSelect(index);", "      this.selectedIndex++;\n      this.onSelect(index);", "T6-write"),
    ("目录说明回写只接图片", CM, "TabBarSymbol 系统符号", "BottomTabBarStyle 只接图片资源", "T7-catalog"),
    ("目录变体回 badge", CM, "m(['symbol'],", "m(['badge'],", "T7-catalog"),
    # 测试 v3：评审 S3-1「四项同一图标」
    ("bar 写死同一组符号", NV, "const s: TabSymbols = symbolsOf(item.icon);",
     "const s: TabSymbols = { normal: $r('sys.symbol.house'), selected: $r('sys.symbol.house_fill') };", "T1-source"),
    ("符号表实参写死 'home'", NV, "symbolsOf(item.icon)", "symbolsOf('home')", "T1-source"),
    ("modifier 直接用 $r", NV, "new SymbolGlyphModifier(s.selected)", "new SymbolGlyphModifier($r('sys.symbol.house_fill'))", "T1-source"),
    ("selected 取 .normal", NV, "new SymbolGlyphModifier(s.selected)", "new SymbolGlyphModifier(s.normal)", "T1-source"),
    ("normal 取 .selected", NV, "new SymbolGlyphModifier(s.normal)", "new SymbolGlyphModifier(s.selected)", "T1-source"),
    ("tabBar 绑死第一项", NV, ".tabBar(this.bar(item))", ".tabBar(this.bar(this.items[0]))", "T1-source"),
    ("符号表函数不在本文件", NV, "symbolsOf(item.icon)", "otherSymbols(item.icon)", "T1-source"),
    ("符号表 switch 常量", NV, "switch (icon) {", "switch ('home') {", "T1-source"),
    ("符号表提前返回绕开 switch", NV, "  switch (icon) {",
     "  const fixed: TabSymbols = { normal: $r('sys.symbol.house'), selected: $r('sys.symbol.house_fill') };\n  return fixed;\n  switch (icon) {", "T1-source"),
    # 测试 v3：评审 S3-2「外层加实色」
    ("外层 Column 再加实色", AS, ".backgroundBlurStyle(BlurStyle.COMPONENT_THICK)\n",
     ".backgroundBlurStyle(BlurStyle.COMPONENT_THICK)\n      .backgroundColor(CouliColors.backgroundCanvas)\n", "T5-background"),
    ("外层 Column 用 background()", AS, ".backgroundBlurStyle(BlurStyle.COMPONENT_THICK)\n",
     ".backgroundBlurStyle(BlurStyle.COMPONENT_THICK)\n      .background(this.opaque())\n", "T5-background"),
    ("外层 Column 加渐变", AS, ".backgroundBlurStyle(BlurStyle.COMPONENT_THICK)\n",
     ".backgroundBlurStyle(BlurStyle.COMPONENT_THICK)\n      .linearGradient({ colors: [['#FFFFFF', 0]] })\n", "T5-background"),
    ("外壳 TabBar 上加实色", AS, "            this.selected = index;\n          }\n        })\n",
     "            this.selected = index;\n          }\n        })\n        .backgroundColor(CouliColors.backgroundCanvas)\n", "T5-background"),
    ("Tabs 上加实色", NV, "    .scrollable(false)\n", "    .scrollable(false)\n    .backgroundColor(CouliColors.backgroundSurface)\n", "T5-background"),
    # 测试 v3：复核 S3-2 接线
    ("摘掉 tabBarShellUiTest(); 注册", LT, "  tabBarShellUiTest();\n", "", "T8-register"),
    ("注册只在注释里", LT, "  tabBarShellUiTest();", "  // tabBarShellUiTest();", "T8-register"),
    ("注册包进 if", LT, "  tabBarShellUiTest();", "  if (Date.now() < 0) {\n    tabBarShellUiTest();\n  }", "T8-register"),
    ("注册两次", LT, "  tabBarShellUiTest();", "  tabBarShellUiTest();\n  tabBarShellUiTest();", "T8-register"),
    ("import 指到别的文件", LT, "from './TabBarShellUi.test'", "from './Other.test'", "T8-register"),
    ("device-test.sh 不认 tabbar", DT, "|tabbar|all)", "|all)", "T8-device-set"),
]
# 要同时改两处的变异：（名字，文件，[(原串, 新串), ...]，应报的规则前缀）。每个原串必须唯一。
MULTI_MUTATIONS = [
    ("bar 绕开符号表调另一个无 switch 的函数", NV, [
        ("symbolsOf(item.icon)", "sameSymbols(item.icon)"),
        ("function symbolsOf(icon: string): TabSymbols {",
         "function sameSymbols(icon: string): TabSymbols {\n  return { normal: $r('sys.symbol.house'), selected: $r('sys.symbol.house_fill') };\n}\n\nfunction symbolsOf(icon: string): TabSymbols {"),
    ], "T1-source"),
    ("符号表 chat 写错、靠文件里诱饵 switch 过关", NV, [
        ("normal: $r('sys.symbol.ellipsis_message'), selected: $r('sys.symbol.ellipsis_message_fill')",
         "normal: $r('sys.symbol.house'), selected: $r('sys.symbol.house_fill')"),
        ("const TAB_BAR_HEIGHT: number = CouliInteraction.minTouchTarget;",
         "export function decoy(icon: string): Resource {\n  switch (icon) {\n    case 'chat':\n      return $r('sys.symbol.ellipsis_message') ?? $r('sys.symbol.ellipsis_message_fill');\n    default:\n      return $r('sys.symbol.house');\n  }\n}\n\nconst TAB_BAR_HEIGHT: number = CouliInteraction.minTouchTarget;"),
    ], "T1-map"),
]
# 正例（出现在注释、字符串里不算；保证守卫不靠全文 grep）。放在好件里：Navigation.ets 的注释提到 CouliIcon、badgeIndex、animationDuration。


def copy_good(dest):
    shutil.copytree(GOOD, dest)


def inventory_mutation(root):
    path = os.path.join(root, INVENTORY)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace("TabBar\t§3.4\t系统控件\tsymbol\t", "TabBar\t§3.4\t系统控件\tbadge\t"))


def self_test():
    failures = []
    with tempfile.TemporaryDirectory(prefix="tabbar-selftest-") as tmp:
        good = os.path.join(tmp, "good")
        copy_good(good)
        got = check(good)
        if got:
            failures.append("正例不过：%s" % [(v["rule"], v["file"], v["line"], v["msg"]) for v in got])
        for idx, (name, rel, old, new, want) in enumerate(MUTATIONS):
            root = os.path.join(tmp, "m%02d" % idx)
            copy_good(root)
            path = os.path.join(root, rel)
            with open(path, encoding="utf-8") as f:
                text = f.read()
            if text.count(old) != 1:
                failures.append("变异「%s」的原串出现 %d 次（应 1 次）" % (name, text.count(old)))
                continue
            with open(path, "w", encoding="utf-8") as f:
                f.write(text.replace(old, new))
            rules = {v["rule"] for v in check(root)}
            if not any(r == want or r.startswith(want + "-") for r in rules):
                failures.append("变异「%s」没被 %s 杀（实际 %s）" % (name, want, sorted(rules)))
            shutil.rmtree(root)
        for idx, (name, rel, edits, want) in enumerate(MULTI_MUTATIONS):
            root = os.path.join(tmp, "mm%02d" % idx)
            copy_good(root)
            path = os.path.join(root, rel)
            with open(path, encoding="utf-8") as f:
                text = f.read()
            bad = [old for old, _ in edits if text.count(old) != 1]
            if bad:
                failures.append("变异「%s」的原串不唯一：%s" % (name, bad))
                continue
            for old, new in edits:
                text = text.replace(old, new)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            rules = {v["rule"] for v in check(root)}
            if not any(r == want or r.startswith(want + "-") for r in rules):
                failures.append("变异「%s」没被 %s 杀（实际 %s）" % (name, want, sorted(rules)))
            shutil.rmtree(root)
        # inventory 变异
        root = os.path.join(tmp, "minv")
        copy_good(root)
        inventory_mutation(root)
        if not any(v["rule"] == "T7-inventory" for v in check(root)):
            failures.append("变异「inventory 回 badge」没被 T7-inventory 杀")
        # 现状形态：badgeIndex 只在注释 / 字符串里不算残留（正例已在好件里）；语法错误必须 4，不算断言红
        root = os.path.join(tmp, "msyntax")
        copy_good(root)
        with open(os.path.join(root, NAV), "a", encoding="utf-8") as f:
            f.write("\nexport struct {\n")
        try:
            check(root)
            failures.append("语法错误应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
    total = len(MUTATIONS) + len(MULTI_MUTATIONS) + 2
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("TABBAR_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("TABBAR_SELFTEST 通过：正例 1 + 变异 %d 全杀（含 inventory）+ 语法错误 fail-closed" % total)
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
        print("TABBAR 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("TABBAR 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    if violations:
        print("TABBAR_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("TABBAR_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
