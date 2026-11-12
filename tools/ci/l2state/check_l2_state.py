#!/usr/bin/env python3
"""HM-L2-STATE-harmony（任务书 NATIVE/HM-L2-BATCH1/brief-STATE.md §3「结构」；方案 sprint-plan-harmony.md §1.1；D10-1177）：
空态 / 错误态 L2 的宿主守卫。测试作者 v1（新鲜独立 Claude）。

用法：
    python3 tools/ci/l2state/check_l2_state.py [--root <目录>]    # 检查（默认仓库根）
    python3 tools/ci/l2state/check_l2_state.py --self-test        # 参照件（fixtures/good + 本单测试文件）全过，错误实现逐个打红

退出码：0 通过；1 有违反（自测：有变异没被杀或正例不过）；2 参数不对；3 解析工具链不可用（复用 lint.hm10_toolchain：node + 鸿蒙 SDK ohos-typescript）；
4 无法保证判定完整（文件缺失、语法错误）。解析错误不算「红在断言」，一律 4。

解析与判定在 tools/ci/l2state/l2state_ast.cjs（AST，不用正则切块；注释与字符串里的字不算）。规则：
    SL1 出现 / 消失淡入（书 ST1）：EmptyState / ErrorState 根 Column 恰一次 .transition(CouliMotion.appear())；不自己读减弱动态、不用 TransitionEffect
        （D10-1163 ①：减弱动态只取消位移，淡入保留——由 CouliMotion.appear 内部处理）
    SL2 参数与【重试】（书 ST2）：既有 @Param / @Event 不改名不改默认值（retryId 钉 'couli-error-retry'）；新增 retrying=false 透传 CouliButton.loading；
        buttonId / disabled / onTap 照旧；onAppear 焦点回位；aboutToAppear 播报走 CouliAnnounce.errorText
    SL3 颜色只来自 CouliColors、色彩角色不变；无触感（书 ST3）
    SL4 图标只经 CouliIcon，名字在 SYMBOL_ICON_NAMES（ICON-SYMBOL 已在基线，用现行名）
    SL5 CouliAnnounce.errorText 纯函数形状（行为由 Hypium L2State.test 判）
    SL6 目录：ErrorState 加 trace6/retrying 态（inventory 只加行，D10-1177 ⑨）；EmptyState / ErrorState 说明写 ExceptionPrompt 复核结论「保留 L2」与「调用方」；
        目录 ErrorState 样例传 retrying / onRetry
    SL7 登记：designsystem List.test 注册 L2State；entry ohosTest List.test 注册 Ds02L2Ui（D10-1177 ⑩）；describe('Ds02L2UiState') 的用例
        与 tools/ci/l2state/device-cases.txt 逐条一致
        HM-L2 批 1 集成 2（只换定位，integ2-harmony.md「§l2state 换定位」）：共用套件只剩一个 describe('Ds02L2Ui')，STATE 的 it 在段函数
        ds02L2UiStateCases 里，该函数在这个 describe 回调里恰调用一次（同 K8）；名单 / 下标与 device-cases.txt 逐条一致照旧
    SL8 焦点接线（HM-BATCH1-DEVFIX swap2，编排 D10-1286 ①，#24 只加）：设备 l2state 31 不再硬判 isFocused（UiTest 读不到页面级
        requestFocus 的结果），宿主钉住「进入错误态时对 couli-error-retry 请求焦点」这次调用：retryId 默认 / buttonId / 设备套件
        DEFAULT_RETRY_ID 同为 couli-error-retry；【重试】onAppear 回调恰一句 CouliFocusReturn.to(this.getUIContext(), this.retryId)
        （同步、无条件）、ErrorState 别处不移焦点；CouliFocusReturn 来自 ./Overlays，其 to(ui, id) 同步无条件 requestFocus(id)、
        并发同 id 的读屏焦点。焦点真的落到【重试】由真机读屏核对一次、记进验收记录。
不做（D10-1177 ⑦）：文案键迁移——参数保持，FU-HM-STATE-KEYS 另办；本检查不判文案键。
"""

import argparse
import csv
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
AST_TOOL = os.path.join(HERE, "l2state_ast.cjs")
LOGIC_TOOL = os.path.join(HERE, "run-logic.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")

STATES = "common/designsystem/src/main/ets/components/States.ets"
NAMES = "common/designsystem/src/main/ets/logic/CouliIconNames.ets"
MANIFEST = "entry/src/staging/ets/catalog/CatalogManifest.ets"
SAMPLES = "entry/src/staging/ets/catalog/CatalogSampleViews.ets"
DS_LIST = "common/designsystem/src/test/List.test.ets"
UI_LIST = "entry/src/ohosTest/ets/test/List.test.ets"
UI_SUITE = "entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets"
LOGIC_SUITE = "common/designsystem/src/test/L2State.test.ets"
INVENTORY = "tools/ci/ds02/fixtures/inventory.tsv"
CASES = "tools/ci/l2state/device-cases.txt"
# HM-BATCH1-DEVFIX swap2（D10-1286 ①，只加）：SL8 焦点接线看 CouliFocusReturn 的实现（参照件 fixtures/good 里放节选）。
OVERLAYS = "common/designsystem/src/main/ets/components/Overlays.ets"
AST_FILES = (STATES, NAMES, MANIFEST, SAMPLES, DS_LIST, UI_LIST, UI_SUITE, LOGIC_SUITE, OVERLAYS)
# 自测时从本仓库拷进参照树的本单测试文件（参照件只放实现侧节选）。
OWN_TEST_FILES = (UI_SUITE, LOGIC_SUITE, CASES)

INVENTORY_KEEP = (
    "EmptyState\t§3.6\tL2 业务组件\tempty\tdefault",
    "ErrorState\t§3.6\tL2 业务组件\ttrace6,offline\tdefault",
)
INVENTORY_NEED = {"EmptyState": {"empty/default"}, "ErrorState": {"trace6/default", "offline/default", "trace6/retrying"}}

RULE_TITLES = {
    "SL1": "出现 / 消失淡入走 CouliMotion.appear（减弱动态保留淡入）",
    "SL2": "参数不变 + retrying 透传加载态 + 焦点回位 + 播报",
    "SL3": "颜色只来自 CouliColors、角色不变、无触感",
    "SL4": "图标只经 CouliIcon（系统符号名）",
    "SL5": "CouliAnnounce.errorText 纯函数",
    "SL6": "目录 retrying 态 / 说明 / inventory 只加行",
    "SL7": "套件登记与设备用例名单",
    "SL8": "错误态出现时对 couli-error-retry 请求焦点（D10-1286 ①，设备 isFocused 改宿主）",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_l2state", os.path.join(HERE, "..", "lint.py"))
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


def v(rule, rel, msg):
    return {"rule": rule, "file": rel, "line": 0, "msg": msg}


def check_inventory(root):
    text = read(root, INVENTORY)
    if text is None:
        raise Incomplete("%s: 文件不存在，无法判定" % INVENTORY)
    out = []
    lines = [l for l in text.splitlines() if l and not l.startswith("#")]
    for keep in INVENTORY_KEEP:
        if lines.count(keep) != 1:
            out.append(v("SL6-inventory", INVENTORY, "既有行须原样保留恰一条（D10-1177 ⑨ 只加行）：%s" % keep.replace("\t", " | ")))
    cases = {}
    for row in csv.DictReader(io.StringIO("\n".join(lines)), delimiter="\t"):
        name = row.get("component")
        if name not in INVENTORY_NEED:
            continue
        if row.get("kinds") != "L2 业务组件":
            out.append(v("SL6-inventory", INVENTORY, "%s 行第 3 列应为 L2 业务组件，实际 %r" % (name, row.get("kinds"))))
        for variant in (row.get("variants") or "").split(","):
            for state in (row.get("states") or "").split(","):
                key = variant + "/" + state
                if key in cases.setdefault(name, set()):
                    out.append(v("SL6-inventory", INVENTORY, "%s 的 %s 重复（行间不得重叠）" % (name, key)))
                cases[name].add(key)
    for name, need in INVENTORY_NEED.items():
        missing = sorted(need - cases.get(name, set()))
        if missing:
            out.append(v("SL6-inventory", INVENTORY, "%s 缺 %s（书 §2.2 补 retrying 态；DS-02 清单加一行）" % (name, ", ".join(missing))))
    return out


def check_cases(root, facts):
    text = read(root, CASES)
    if text is None:
        raise Incomplete("%s: 文件不存在，无法判定" % CASES)
    listed = [l.strip() for l in text.splitlines() if l.strip()]
    got = facts.get("deviceCases")
    if got is None:
        return []  # 套件缺失 / 无 describe 已由 SL7-suite 报
    out = []
    if len(set(listed)) != len(listed):
        out.append(v("SL7-cases", CASES, "device-cases.txt 有重复行"))
    if listed != got:
        out.append(v("SL7-cases", CASES, "device-cases.txt 与 ds02L2UiStateCases（describe('Ds02L2Ui') 里的 STATE 段）注册的用例不一致：名单 %s，实际 %s" % (listed, got)))
    return out


def check(root):
    """返回违反列表；文件缺失 / 语法错误抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
    tool = lint.hm10_toolchain()
    files = {}
    for rel in AST_FILES:
        text = read(root, rel)
        if text is not None:
            files[rel] = text
    payload = json.dumps({"files": files}, ensure_ascii=False).encode("utf-8")
    try:
        proc = subprocess.run([tool["node"], AST_TOOL, tool["typescript"]], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise lint.HM10ToolchainError("运行 node 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("l2state_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("l2state_ast.cjs 输出无法解析：%s" % e)
    if out["incomplete"]:
        raise Incomplete("；".join(out["incomplete"]))
    return out["violations"] + check_inventory(root) + check_cases(root, out["facts"])


def render(violations):
    groups = {}
    for x in violations:
        groups.setdefault(x["rule"].split("-")[0], []).append(x)
    for key in sorted(RULE_TITLES):
        state = "红" if key in groups else "绿"
        print("%s %s：%s（%d 处）" % (key, state, RULE_TITLES[key], len(groups.get(key, []))))
    for x in sorted(violations, key=lambda y: (y["rule"], y["file"], y["line"])):
        print("  [%s] %s:%d %s" % (x["rule"], x["file"], x["line"], x["msg"]))


# ---------------------------------------------------------------- 自测：参照件 + 错误实现，全部要杀

S, CM, SV, INV, DL, UL, SU, LS, CS, NM = STATES, MANIFEST, SAMPLES, INVENTORY, DS_LIST, UI_LIST, UI_SUITE, LOGIC_SUITE, CASES, NAMES
OV = OVERLAYS  # HM-BATCH1-DEVFIX swap2（D10-1286 ①，只加）
FOCUS_LINE = "            CouliFocusReturn.to(this.getUIContext(), this.retryId);\n"
EMPTY_TAIL = "    .transition(CouliMotion.appear())\n  }\n}\n\n/**\n * 错误态"
ERROR_TAIL = "    .transition(CouliMotion.appear())\n  }\n}\n\n/** 读屏播报"
# （名字，文件，原串，新串，应报的规则前缀）；原串在参照文件里必须恰好出现一次
MUTATIONS = [
    # SL1 淡入（书 ST4「删 transition」）
    ("EmptyState 删 transition", S, EMPTY_TAIL, EMPTY_TAIL.replace("    .transition(CouliMotion.appear())\n", ""), "SL1-transition"),
    ("ErrorState 删 transition", S, ERROR_TAIL, ERROR_TAIL.replace("    .transition(CouliMotion.appear())\n", ""), "SL1-transition"),
    ("ErrorState 用系统淡入不走 CouliMotion", S, ERROR_TAIL, ERROR_TAIL.replace("CouliMotion.appear()", "TransitionEffect.OPACITY"), "SL1"),
    ("减弱动态时干脆不淡入", S, EMPTY_TAIL,
     EMPTY_TAIL.replace("CouliMotion.appear()", "CouliMotion.reduced() ? TransitionEffect.IDENTITY : CouliMotion.appear()"), "SL1"),
    ("根上一个、子节点再挂一个", S, "      .backgroundColor(CouliColors.statusErrorBackground)\n",
     "      .backgroundColor(CouliColors.statusErrorBackground)\n      .transition(CouliMotion.appear())\n", "SL1-transition"),
    ("根上挂两次", S, ERROR_TAIL, ERROR_TAIL.replace("    .transition(CouliMotion.appear())\n", "    .transition(CouliMotion.appear())\n    .transition(CouliMotion.appear())\n"), "SL1-transition"),
    ("没导入 CouliMotion（换成别处同名）", S, "import { CouliMotion } from './CouliMotion';", "import { CouliMotion } from './OtherMotion';", "SL1-import"),
    # SL2 参数与重试（书 ST4「改 retryId 默认值」「retrying 不透传」）
    ("retryId 默认值改了", S, "@Param retryId: string = 'couli-error-retry';", "@Param retryId: string = 'error-retry';", "SL2-params"),
    ("retryDisabled 默认 true", S, "@Param retryDisabled: boolean = false;", "@Param retryDisabled: boolean = true;", "SL2-params"),
    ("retryDisabled 改名", S, "@Param retryDisabled: boolean = false;", "@Param retryBlocked: boolean = false;", "SL2-params"),
    ("EmptyState icon 默认改了", S, "@Param icon: string = 'search';", "@Param icon: string = 'orders';", "SL2-params"),
    ("EmptyState actionText 改名", S, "@Param actionText: string = '';", "@Param buttonText: string = '';", "SL2-params"),
    ("onRetry 改成 @Param", S, "  @Event onRetry: () => void = () => {", "  @Param onRetry: () => void = () => {", "SL2-params"),
    ("没加 retrying 参数", S, "  @Param retrying: boolean = false;\n", "", "SL2"),
    ("retrying 默认 true", S, "@Param retrying: boolean = false;", "@Param retrying: boolean = true;", "SL2-params"),
    ("retrying 加了 @Once", S, "@Param retrying: boolean = false;", "@Param @Once retrying: boolean = false;", "SL2-params"),
    ("retrying 不透传 loading", S, "          loading: this.retrying,\n", "", "SL2-loading"),
    ("loading 写死 false", S, "loading: this.retrying,", "loading: false,", "SL2-loading"),
    ("loading 接到 retryDisabled", S, "loading: this.retrying,", "loading: this.retryDisabled,", "SL2-loading"),
    ("retrying 只当禁用（不转圈）", S, "          disabled: this.retryDisabled,\n          loading: this.retrying,\n",
     "          disabled: this.retryDisabled || this.retrying,\n", "SL2"),
    ("buttonId 写死", S, "buttonId: this.retryId,", "buttonId: 'couli-error-retry',", "SL2-retry"),
    ("disabled 丢了", S, "          disabled: this.retryDisabled,\n", "", "SL2-retry"),
    ("onTap 不回调 onRetry", S, "          onTap: () => {\n            this.onRetry();\n          }\n        })\n          .margin({ top: CouliSpacing.space2 })\n          .onAppear",
     "          onTap: () => {\n          }\n        })\n          .margin({ top: CouliSpacing.space2 })\n          .onAppear", "SL2-retry"),
    ("onTap 回调两次", S, "            this.onRetry();\n", "            this.onRetry();\n            this.onRetry();\n", "SL2-retry"),
    ("重试降为次按钮", S, "          text: this.retryText,\n", "          text: this.retryText,\n          variant: CouliButtonVariant.SECONDARY,\n", "SL2-retry"),
    ("删焦点回位", S, "          .onAppear(() => {\n            CouliFocusReturn.to(this.getUIContext(), this.retryId);\n          })\n", "", "SL2-focus"),
    ("焦点回位写死默认 id", S, "CouliFocusReturn.to(this.getUIContext(), this.retryId);", "CouliFocusReturn.to(this.getUIContext(), 'couli-error-retry');", "SL2-focus"),
    ("播报删了", S, "    CouliAnnounce.say(this.getUIContext(), CouliAnnounce.errorText(this.title, this.message));\n", "", "SL2-announce"),
    ("播报不走纯函数", S, "CouliAnnounce.errorText(this.title, this.message)", "this.title", "SL2-announce"),
    ("播报参数对调", S, "CouliAnnounce.errorText(this.title, this.message)", "CouliAnnounce.errorText(this.message, this.title)", "SL2-announce"),
    # SL3 颜色 / 触感（书 ST4「加触感」；ST3「颜色只来自 CouliColors」）
    ("重试加触感", S, "            this.onRetry();\n", "            CouliHaptics.play(HapticMoment.FAIL);\n            this.onRetry();\n", "SL3-haptics"),
    ("导入振动", S, "import { CouliMotion } from './CouliMotion';", "import { CouliMotion } from './CouliMotion';\nimport { vibrator } from '@kit.SensorServiceKit';", "SL3-haptics"),
    ("块底色写死 hex", S, ".backgroundColor(CouliColors.statusErrorBackground)", ".backgroundColor('#FDECF0')", "SL3"),
    ("块底色用 Color 枚举", S, ".backgroundColor(CouliColors.backgroundMuted)", ".backgroundColor(Color.White)", "SL3"),
    ("图标色取资源", S, "color: CouliColors.statusErrorText", "color: $r('app.color.status_error_text')", "SL3"),
    ("错误态图标色换成灰", S, "color: CouliColors.statusErrorText", "color: CouliColors.textSecondary", "SL3-role"),
    ("错误态块底色换成空态底", S, ".backgroundColor(CouliColors.statusErrorBackground)", ".backgroundColor(CouliColors.backgroundMuted)", "SL3-role"),
    ("空态标题字色换成次要", S, "      Text(this.title)\n        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))\n        .textAlign(TextAlign.Center)\n      if (this.message.length > 0) {\n        Text(this.message)\n          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))\n          .textAlign(TextAlign.Center)\n      }\n      if (this.actionText",
     "      Text(this.title)\n        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary, CouliFontWeight.semibold))\n        .textAlign(TextAlign.Center)\n      if (this.message.length > 0) {\n        Text(this.message)\n          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))\n          .textAlign(TextAlign.Center)\n      }\n      if (this.actionText", "SL3-role"),
    ("文字写死 rgb", S, "new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))\n          .textAlign(TextAlign.Center)\n      }\n      if (this.retryText",
     "new CouliTextModifier(CouliTypography.footnote, 'rgb(101,94,87)'))\n          .textAlign(TextAlign.Center)\n      }\n      if (this.retryText", "SL3"),
    ("加渐变底", S, ERROR_TAIL, ERROR_TAIL.replace("    .transition", "    .linearGradient({ colors: [[CouliColors.backgroundMuted, 0]] })\n    .transition"), "SL3-color"),
    # SL4 图标
    ("错误态图标换成 info", S, "CouliIcon({ name: 'alert'", "CouliIcon({ name: 'info'", "SL4-icon"),
    ("错误态直接画 SymbolGlyph", S, "        CouliIcon({ name: 'alert', iconSize: 32, color: CouliColors.statusErrorText })\n",
     "        SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontColor([CouliColors.statusErrorText])\n", "SL4"),
    ("空态图标名写死", S, "CouliIcon({ name: this.icon, iconSize: 32,", "CouliIcon({ name: 'search', iconSize: 32,", "SL4-icon"),
    ("空态默认图标换成自有 Path 名", S, "@Param icon: string = 'search';", "@Param icon: string = 'guide';", "SL4-symbol"),
    ("空态加 Path 装饰", S, "        CouliIcon({ name: this.icon, iconSize: 32, color: CouliColors.textSecondary })\n",
     "        CouliIcon({ name: this.icon, iconSize: 32, color: CouliColors.textSecondary })\n        Path().commands('M0 0L1 1')\n", "SL4-draw"),
    # SL5 纯函数
    ("errorText 不是 static", S, "  static errorText(title: string, message: string): string {", "  errorText(title: string, message: string): string {", "SL5-shape"),
    ("errorText 签名错", S, "  static errorText(title: string, message: string): string {", "  static errorText(title: string): string {", "SL5-shape"),
    ("errorText 读时间", S, "    if (message.length === 0) {\n", "    if (Date.now() < 0 || message.length === 0) {\n", "SL5-pure"),
    # SL6 目录
    ("目录没加 retrying 态", CM, ", m(['trace6'], ['retrying'])", "", "SL6-manifest"),
    ("目录 retrying 挂错变体", CM, "m(['trace6'], ['retrying'])", "m(['offline2'], ['retrying'])", "SL6-manifest"),
    ("目录删了 offline", CM, "m(['trace6', 'offline'], ['default'])", "m(['trace6'], ['default'])", "SL6-manifest"),
    ("ErrorState 说明没写复核结论", CM, "系统 ExceptionPrompt 是页顶提示条，'\n    + '整页错误态无系统等价件，保留 L2；", "", "SL6-note"),
    ("EmptyState 说明丢「调用方」", CM, "'\n    + '文案来自调用方。'", "'", "SL6-note"),
    ("EmptyState 说明回写外观不符", CM, "空态（系统 ExceptionPrompt 是页顶提示条", "空态（系统 ExceptionPrompt 外观不符、是页顶提示条", "SL6-note"),
    ("ErrorState 降成 L1", CM, "c('ErrorState', GROUP_FEEDBACK, KIND_L2,", "c('ErrorState', GROUP_FEEDBACK, KIND_L1,", "SL6-manifest"),
    ("目录样例不传 retrying", SV, "          retrying: this.state === 'retrying',\n", "", "SL6-sample"),
    ("目录样例不接 onRetry", SV, "          onRetry: () => {\n            this.events.errorRetryCount++;\n          }\n", "", "SL6-sample"),
    ("inventory 没加行", INV, "ErrorState\t§3.6\tL2 业务组件\ttrace6\tretrying\n", "", "SL6-inventory"),
    ("inventory 改了原行（不是只加行）", INV, "ErrorState\t§3.6\tL2 业务组件\ttrace6,offline\tdefault\nErrorState\t§3.6\tL2 业务组件\ttrace6\tretrying\n",
     "ErrorState\t§3.6\tL2 业务组件\ttrace6,offline\tdefault,retrying\n", "SL6-inventory"),
    # SL7 登记与名单
    ("designsystem List 没注册 L2State", DL, "  l2StateTest();\n", "", "SL7-register"),
    ("designsystem List 注册包进 if", DL, "  l2StateTest();", "  if (Date.now() < 0) {\n    l2StateTest();\n  }", "SL7-register"),
    ("ohosTest List 没注册 Ds02L2Ui", UL, "  ds02L2UiTest();\n", "", "SL7-register"),
    ("ohosTest List 注册两次", UL, "  ds02L2UiTest();", "  ds02L2UiTest();\n  ds02L2UiTest();", "SL7-register"),
    ("ohosTest List import 指错文件", UL, "from './Ds02L2Ui.test'", "from './Ds02Ui2.test'", "SL7-register"),
    ("名单少一条", CS, "l2state_large_font_200_no_truncation_and_retry_hit48\n", "", "SL7-cases"),
    # 集成 2 换定位：describe 名换成共用的 Ds02L2Ui；STATE 段在段函数里（另加「段函数未被调用 / 被调两次 / 里面另起 describe」）。
    ("describe 改名", SU, "describe('Ds02L2Ui',", "describe('Ds02L2UiX',", "SL7-suite"),
    ("段函数没在 describe 里调用", SU, "    L2StateSegment.ds02L2UiStateCases();\n", "", "SL7-suite"),
    ("段函数被调两次", SU, "    L2StateSegment.ds02L2UiStateCases();\n",
     "    L2StateSegment.ds02L2UiStateCases();\n    L2StateSegment.ds02L2UiStateCases();\n", "SL7-suite"),
    ("段函数里另起 describe", SU, "export function ds02L2UiStateCases(): void {\n",
     "export function ds02L2UiStateCases(): void {\n  describe('Ds02L2UiState', () => {});\n", "SL7-suite"),
    ("套件少注册一条 it", SU, "    it(L2STATE_DEVICE_CASES[6], 0,", "    hypiumIt(L2STATE_DEVICE_CASES[6], 0,", "SL7"),
    # SL8 焦点接线（HM-BATCH1-DEVFIX swap2，D10-1286 ①，只加）：去掉调用、换 id、换时机、焦点实现失效都必须红。
    ("SL8 删焦点请求", S, "          .onAppear(() => {\n" + FOCUS_LINE + "          })\n", "", "SL8-timing"),
    ("SL8 焦点请求换成标题 id", S, FOCUS_LINE, "            CouliFocusReturn.to(this.getUIContext(), 'couli-error-title');\n", "SL8-timing"),
    ("SL8 焦点请求写死默认 id（调用方传的 retryId 失效）", S, FOCUS_LINE, "            CouliFocusReturn.to(this.getUIContext(), 'couli-error-retry');\n", "SL8-timing"),
    ("SL8 焦点请求挪进 setTimeout（时机变了）", S, FOCUS_LINE,
     "            setTimeout(() => CouliFocusReturn.to(this.getUIContext(), this.retryId), 0);\n", "SL8-timing"),
    ("SL8 焦点请求加条件", S, FOCUS_LINE,
     "            if (!this.retrying) {\n  " + FOCUS_LINE + "            }\n", "SL8-timing"),
    ("SL8 出现后又把焦点移走", S, FOCUS_LINE, FOCUS_LINE + "            CouliFocusReturn.to(this.getUIContext(), 'couli-error-title');\n", "SL8-timing"),
    ("SL8 onAppear 改 onDisAppear", S, "          .onAppear(() => {\n" + FOCUS_LINE, "          .onDisAppear(() => {\n" + FOCUS_LINE, "SL8-timing"),
    ("SL8 aboutToAppear 里另移焦点", S, "    CouliAnnounce.say(this.getUIContext(), CouliAnnounce.errorText(this.title, this.message));\n",
     "    CouliAnnounce.say(this.getUIContext(), CouliAnnounce.errorText(this.title, this.message));\n"
     "    this.getUIContext().getFocusController().requestFocus('couli-error-title');\n", "SL8-only"),
    ("SL8 retryId 默认值换了", S, "@Param retryId: string = 'couli-error-retry';", "@Param retryId: string = 'couli-retry';", "SL8-id"),
    ("SL8 buttonId 不跟 retryId", S, "buttonId: this.retryId,", "buttonId: 'couli-error-retry-button',", "SL8-id"),
    ("SL8 CouliFocusReturn 换成别处同名", S, "import { CouliFocusReturn } from './Overlays';", "import { CouliFocusReturn } from './FocusStub';", "SL8-import"),
    ("SL8 to 不再请求键盘焦点", OV, "      ui.getFocusController().requestFocus(id);\n", "", "SL8-request"),
    ("SL8 to 请求写死 id", OV, "      ui.getFocusController().requestFocus(id);\n", "      ui.getFocusController().requestFocus('couli-dialog-title');\n", "SL8-request"),
    ("SL8 to 请求挪进 setTimeout", OV, "      ui.getFocusController().requestFocus(id);\n",
     "      setTimeout(() => ui.getFocusController().requestFocus(id), 0);\n", "SL8-request"),
    ("SL8 to 请求加条件", OV, "      ui.getFocusController().requestFocus(id);\n",
     "      if (id !== 'couli-error-retry') {\n        ui.getFocusController().requestFocus(id);\n      }\n", "SL8-request"),
    ("SL8 to 对错误态 id 提前返回", OV, "    if (id.length === 0) {\n", "    if (id.length === 0 || id === 'couli-error-retry') {\n", "SL8-request"),
    ("SL8 读屏焦点不发", OV, "      CouliFocusReturn.accessibilityFocus(ui, id);\n", "", "SL8-a11y"),
    ("SL8 读屏焦点 customId 换值", OV, "      event.customId = id;\n", "      event.customId = 'couli-dialog-title';\n", "SL8-a11y"),
    ("SL8 设备套件 DEFAULT_RETRY_ID 换值", SU, "const DEFAULT_RETRY_ID: string = 'couli-error-retry';", "const DEFAULT_RETRY_ID: string = 'couli-error-retry2';", "SL8-suite"),
]
# 要同时改两处的变异：（名字，[(文件, 原串, 新串), ...]，应报的规则前缀）
MULTI_MUTATIONS = [
    ("transition 挂在图标块上（根上没有）", [
        (S, EMPTY_TAIL, EMPTY_TAIL.replace("    .transition(CouliMotion.appear())\n", "")),
        (S, "      .backgroundColor(CouliColors.backgroundMuted)\n", "      .backgroundColor(CouliColors.backgroundMuted)\n      .transition(CouliMotion.appear())\n"),
    ], "SL1-transition"),
    ("inventory 新行写成 L1", [(INV, "ErrorState\t§3.6\tL2 业务组件\ttrace6\tretrying", "ErrorState\t§3.6\tL1 系统控件\ttrace6\tretrying")], "SL6-inventory"),
    ("名单与套件同步改名但套件没这条（数组多一个名字）", [
        (SU, "  'l2state_large_font_200_no_truncation_and_retry_hit48'\n];", "  'l2state_large_font_200_no_truncation_and_retry_hit48',\n  'l2state_extra_never_registered'\n];"),
        (CS, "l2state_large_font_200_no_truncation_and_retry_hit48\n", "l2state_large_font_200_no_truncation_and_retry_hit48\nl2state_extra_never_registered\n"),
    ], "SL7-suite"),
]
# Hypium 纯逻辑的错误实现（run-logic.cjs 在本仓库上 --swap States.ets <变异> --expect-red，用本仓库的 Index.ets / PriceTerms / L2State.test）：至少一条红。
# v3：参照件 errorText 改成主会话定的新口径（只有说明时只读说明），变异原串随之改写；末两条是评审 r1 S2-1 的 M1、M2。
ERR_BODY = ("    if (message.length === 0) {\n      return title;\n    }\n"
            "    if (title.length === 0) {\n      return message;\n    }\n"
            "    return title + PriceTerms.comma + message;\n")
ERR_JOIN = "    return title + PriceTerms.comma + message;\n"
ERR_TITLE_EMPTY = "    if (title.length === 0) {\n      return message;\n    }\n"
ERR_MESSAGE_EMPTY = "    if (message.length === 0) {\n      return title;\n    }\n"
LOGIC_MUTATIONS = [
    ("半角逗号", ERR_JOIN, "    return title + ',' + message;\n"),
    ("不判空，总带逗号", ERR_BODY, ERR_JOIN),
    ("裁空白", ERR_BODY,
     "    if (message.trim().length === 0) {\n      return title.trim();\n    }\n"
     "    if (title.trim().length === 0) {\n      return message.trim();\n    }\n"
     "    return title.trim() + PriceTerms.comma + message.trim();\n"),
    ("说明在前", ERR_JOIN, "    return message + PriceTerms.comma + title;\n"),
    ("只读标题", ERR_BODY, "    return title;\n"),
    ("补句号", ERR_JOIN, "    return title + PriceTerms.comma + message + '。';\n"),
    ("截断长说明", ERR_JOIN, "    return title + PriceTerms.comma + message.substring(0, 100);\n"),
    ("用空格连接", ERR_JOIN, "    return title + ' ' + message;\n"),
    ("全空时给占位", ERR_MESSAGE_EMPTY, "    if (message.length === 0) {\n      return title.length > 0 ? title : '出错了';\n    }\n"),
    ("有状态：记住上一次", ERR_MESSAGE_EMPTY,
     "    CouliAnnounce.last = CouliAnnounce.last.length > 0 ? CouliAnnounce.last : title;\n    title = CouliAnnounce.last;\n" + ERR_MESSAGE_EMPTY),
    # 评审 r1 S2-1 M1：去掉「标题空时只返回说明」那一支（回到旧拼法，只有说明时读出前导「，」）
    ("只有说明时读出前导逗号（回到旧拼法）", ERR_BODY, "    return message.length > 0 ? title + PriceTerms.comma + message : title;\n"),
    # 评审 r1 S2-1 M2：标题空时返回 title（说明整句丢掉，读屏什么都不播）
    ("标题为空时整句丢掉", ERR_TITLE_EMPTY, "    if (title.length === 0) {\n      return title;\n    }\n"),
    # 同族补充：只有说明时换成别的前导标点（顿号），同样要红
    ("只有说明时带前导顿号", ERR_TITLE_EMPTY, "    if (title.length === 0) {\n      return '、' + message;\n    }\n"),
]


def build_good(dest):
    shutil.copytree(GOOD, dest)
    for rel in OWN_TEST_FILES:
        src = os.path.join(REPO_ROOT, rel)
        os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
        shutil.copyfile(src, os.path.join(dest, rel))


def apply_edits(root, edits):
    """edits: [(rel, old, new)]；原串不唯一返回错误说明。"""
    for rel, old, new in edits:
        path = os.path.join(root, rel)
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if text.count(old) != 1:
            return "%s 原串出现 %d 次（应 1 次）：%r" % (rel, text.count(old), old[:60])
        with open(path, "w", encoding="utf-8") as f:
            f.write(text.replace(old, new))
    return None


def run_logic(root, swap=None, expect_red=False):
    tool = lint.hm10_toolchain()
    cmd = [tool["node"], LOGIC_TOOL, "--root", root]
    if swap:
        cmd += ["--swap", STATES, swap]
    if expect_red:
        cmd.append("--expect-red")
    env = dict(os.environ, COULI_HM_TYPESCRIPT=tool["typescript"])
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


def self_test():
    failures = []
    total = 0
    with tempfile.TemporaryDirectory(prefix="l2state-selftest-") as tmp:
        good = os.path.join(tmp, "good")
        build_good(good)
        got = check(good)
        total += 1
        if got:
            failures.append("参照件不过：%s" % [(x["rule"], x["file"], x["msg"]) for x in got])
        code, out = run_logic(REPO_ROOT, swap=os.path.join(good, STATES))
        total += 1
        if code != 0:
            failures.append("参照件上 L2State 逻辑不全绿：%s" % out.strip().splitlines()[-1:])
        groups = [(name, [(rel, old, new)], want) for name, rel, old, new, want in MUTATIONS] + MULTI_MUTATIONS
        for idx, (name, edits, want) in enumerate(groups):
            total += 1
            root = os.path.join(tmp, "m%02d" % idx)
            build_good(root)
            err = apply_edits(root, edits)
            if err:
                failures.append("变异「%s」%s" % (name, err))
                shutil.rmtree(root)
                continue
            try:
                rules = {x["rule"] for x in check(root)}
            except Incomplete as e:
                rules = {"INCOMPLETE"}
                failures.append("变异「%s」解析不完整（应红在断言）：%s" % (name, e))
                shutil.rmtree(root)
                continue
            if not any(r == want or r.startswith(want + "-") for r in rules):
                failures.append("变异「%s」没被 %s 杀（实际 %s）" % (name, want, sorted(rules)))
            shutil.rmtree(root)
        for idx, (name, old, new) in enumerate(LOGIC_MUTATIONS):
            total += 1
            with open(os.path.join(good, STATES), encoding="utf-8") as f:
                text = f.read()
            if text.count(old) != 1:
                failures.append("逻辑变异「%s」原串出现 %d 次" % (name, text.count(old)))
                continue
            mutated = text.replace(old, new)
            if name.startswith("有状态"):
                mutated = mutated.replace("export class CouliAnnounce {\n", "export class CouliAnnounce {\n  static last: string = '';\n", 1)
            path = os.path.join(tmp, "logic%02d.ets" % idx)
            with open(path, "w", encoding="utf-8") as f:
                f.write(mutated)
            code, out = run_logic(REPO_ROOT, swap=path, expect_red=True)
            if code != 0:
                failures.append("逻辑变异「%s」没被 L2State 杀：%s" % (name, out.strip().splitlines()[-1:]))
        # 语法错误必须 4（Incomplete），不算断言红；缺文件同样
        total += 2
        root = os.path.join(tmp, "msyntax")
        build_good(root)
        with open(os.path.join(root, STATES), "a", encoding="utf-8") as f:
            f.write("\nexport struct {\n")
        try:
            check(root)
            failures.append("语法错误应按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
        root = os.path.join(tmp, "mmissing")
        build_good(root)
        os.remove(os.path.join(root, MANIFEST))
        try:
            check(root)
            failures.append("缺 CatalogManifest 应按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("L2STATE_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("L2STATE_SELFTEST 通过：参照件宿主 0 违反 + 逻辑全绿；宿主变异 %d、逻辑变异 %d 全杀；语法错误 / 缺文件 fail-closed（共 %d 项）"
          % (len(MUTATIONS) + len(MULTI_MUTATIONS), len(LOGIC_MUTATIONS), total))
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
        print("L2STATE 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("L2STATE 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    if violations:
        print("L2STATE_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("L2STATE_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
