#!/usr/bin/env python3
"""FU-HM-A11Y-FUNDS-harmony（QA-12b harmony-audit FU-HM-A11Y-03 / 04 / 05 / 08 / 19；编排裁定 D10-1248 ④⑤⑥）宿主结构守卫（测试作者 v1，先红；
v2 按 Codex r1 四条 S2 收紧：AF2-restore 一定执行一定生效、AF3-mask、AF7 延时移焦复核）。

用法：
    python3 tools/ci/a11yfunds/check_a11y_funds.py [--root <目录>]    # 检查（默认仓库根）
    python3 tools/ci/a11yfunds/check_a11y_funds.py --self-test        # 参照件（fixtures/good 叠加到真实树）全过 + 每个变异都要被杀 + 良性改写不误报

退出码：0 通过；1 有违反（自测：有变异没被杀、参照件不过或良性改写被误报）；2 参数不对；3 解析工具链不可用（复用 lint.hm10_toolchain，
node + 鸿蒙 SDK ohos-typescript）；4 无法保证判定完整（文件缺失、语法错误、找不到 struct / class、基线读不到）。解析错误不算「红在断言」，一律 4。

资金页铁律（任务书 §0）：只动视图与读屏属性，不碰资金逻辑——AF6 钉「core wallet / entry wallet 0 差异」与「资金页调用集合不变」。
判定在 a11yfunds_ast.cjs（AST，不用正则切块；注释与字符串里的字不算）。规则：
    AF1 提现提交被拒（金额类错误）定位到金额框（FU-HM-A11Y-03，D10-1248 ④）：
        AF1-fn     WithdrawView 从 ./WithdrawA11y 引入 isAmountError（逻辑层 Hypium 钉这个纯函数的名单）
        AF1-desc   金额框 TextInput（id withdraw_amount）恰一个 accessibilityDescription(this.model.F)，F 是 WithdrawModel 的 @Trace 字段；
                   F 的每处非空写入都是「isAmountError(…textKey) 为真时取 …banner.text」，且至少有一处清空（''）
        AF1-focus  与新 banner 播报 CouliAnnounce.say(…banner.text) 同一块（或块里调用的一层 this.<方法>()）里，有
                   CouliFocusReturn.accessibilityFocus(ui, 'withdraw_amount')，所在路径的守卫（if / 三元 / && / 提前 return）断言
                   isAmountError(…textKey) 与 …editable 为真；用 CouliFocusReturn.to（会弹键盘，任务书 §2.1「只移读屏焦点」）判红
    AF2 金额框被拒不重建（FU-HM-A11Y-04；被拒播报不做，D10-1248 ⑤ 另登 FU-HM-A11Y-04B）：
        AF2-key     构建金额卡的 ForEach 键（含一层 this.<方法>()）不读 inputReset；onChange 里 setInput 返回 false 的分支不写任何参与该键的
                    视图模型字段
        AF2-restore （v2 收紧）被拒分支把金额框 text 绑定的字段写回 …inputText，且一定执行、一定让显示状态变一次：写回在直线路径上
                    （除页面生命周期复核外无 if / 三元 / && / 循环 / switch / try，前面无 return / throw，不在从不调用的函数里）；
                    非 $$ 绑定时写回在 setTimeout 回调里，且之前同步、直线地把同一字段写成 onChange 入参（被拒串）；$$ 绑定时同步 / 延时写回都可
    AF3 小眼睛切换后焦点留在眼睛（FU-HM-A11Y-05）：
        AF3-eye     WalletHeroCard 眼睛按钮（onClick 调 onToggleHidden）.id 用调用方可给的 @Param；钱包页给非空静态 id
        AF3-stable  「主卡 ForEach 键（含一层 this.<方法>()）不含 masked」与「onToggleHidden 里 CouliFocusReturn.to(…, <眼睛 id>)」至少一条
        AF3-mask    （v2）WalletHeroCard 的 amount / amountSpoken / amountHidden 是 @Param 且非 @Once；主卡金额 Text 显示
                    「this.amountHidden ? PriceTerms.amountMask : this.amount」、读屏名含「this.amountHidden ? amountHiddenSpoken : this.amountSpoken」；
                    卡内每处读 this.amount / this.amountSpoken 都在 amountHidden 为假的分支里；卡内 AmountGrid masked = this.amountHidden；
                    AmountGrid.cell 读 item.value / item.spoken 都在 this.hides(item) 为假的分支里；钱包页 amountHidden = this.maskUi.masked、
                    onToggleHidden 调 this.maskUi.toggle()
    AF4 二次验证半屏打开时读屏焦点进标题（FU-HM-A11Y-08，D10-1248 ⑥ 改组件）：
        AF4-title   StepUpPanel 标题（id step_up_title）或其外层组件的 onAppear 里 CouliFocusReturn.accessibilityFocus(…, 'step_up_title')；
                    对标题用 CouliFocusReturn.to（抢验证码框键盘焦点）判红；标题仍 focusable(true)
        AF4-code    验证码框（step_up_code）仍 defaultFocus(true)，标题不设 defaultFocus
    AF5 金额格标签不读两遍（FU-HM-A11Y-19）：
        AF5-dup     AmountGrid.cell 的 Text(item.label)、WalletHeroCard 的 Text(this.label) 读屏隐藏（自己 accessibilityLevel no，
                    或外层一定 no-hide-descendants）；标签外层不再 accessibilityGroup(非 false)
        AF5-spoken  金额 Text 的读屏名仍以标签开头（item.label / this.label + …），且不被隐藏
        AF5-help    AmountGrid 格的问号按钮仍可读、focusable(true)
    AF7 （v2）延时移焦不发过期请求（Codex r1 S2-3）：移到 withdraw_amount / step_up_title 的焦点调用凡在延时回调里执行（直接写在
        setTimeout 等回调里、回调调的一层 this.<方法>()、setTimeout(this.<方法>)），执行时（回调 / 方法里的守卫，排队时算好的局部 const 不算）须复核：
        AF7-amount  页面仍在（aboutToDisappear 置否的标志 / this.config.controller.alive；或句柄 this.T 在 aboutToDisappear 里 clearTimeout）、
                    错误序号没变（this.<F> === 排队时捕获的 const，F 由 …banner.seq 写入；或排队前 clearTimeout 旧任务）、仍是金额类错误
                    （说明字段非空）、仍可编辑（视图模型 editable）
        AF7-title   面板仍在（同上生命周期写法）
    AF6 资金页只动视图（任务书 §0 铁律）：
        AF6-frozen  common/core/src/main/ets/wallet/**、entry/src/main/ets/wallet/** 的文件清单与 sha256 = 基线（fixtures/frozen-baseline-2a4b1c8.json）
        AF6-calls   WithdrawView（this.config.controller / 其别名 / this.stepUpController）、WalletView（this.config.controller）、
                    StepUpPanel（this.driver）的调用（方法名 + 实参原文）多重集合 = 基线：只增读屏调用，不增删改资金动作

不判（交设备 / 真机）：读屏播报与读屏焦点落点（模拟器读不到，D10-1231）；被拒后框内值、键盘焦点、组件是否重建、眼睛切换后焦点、
200% 纵排（HmA11yUi a11y_funds_01–05）。不钉订单号 / 金额行的 wordBreak（D10-1248 ⑧）。
"""

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
AST_TOOL = os.path.join(HERE, "a11yfunds_ast.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")
BASELINE = os.path.join(HERE, "fixtures", "frozen-baseline-2a4b1c8.json")

DS_WALLET = "common/designsystem/src/main/ets/components/Wallet.ets"
STEP_UP = "common/designsystem/src/main/ets/components/StepUpPanel.ets"
WALLET = "features/wallet/src/main/ets/WalletView.ets"
WITHDRAW = "features/wallet/src/main/ets/WithdrawView.ets"
A11Y_FN = "features/wallet/src/main/ets/WithdrawA11y.ets"
REQUIRED = (DS_WALLET, STEP_UP, WALLET, WITHDRAW)
FROZEN_DIRS = ("common/core/src/main/ets/wallet", "entry/src/main/ets/wallet")

RULE_TITLES = {
    "AF1": "金额类提交错误：说明关联到金额框 + 只移读屏焦点到金额框",
    "AF2": "金额框被拒输入不重建、显示回已接受值",
    "AF3": "小眼睛有 id，切换后不重建或焦点回眼睛；隐藏时主卡 / 数字格不露金额",
    "AF4": "二次验证打开时读屏焦点进标题，验证码框仍拿键盘默认焦点",
    "AF5": "金额格 / 主卡标签只读一次（不丢标签、问号仍可读）",
    "AF6": "资金页只动视图：core / entry wallet 0 差异，资金调用集合不变",
    "AF7": "延时移焦执行时复核页面 / 面板仍在、错误序号与当前状态（或取消过期任务）",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_a11yfunds", os.path.join(HERE, "..", "lint.py"))
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


def frozen_digests(root):
    out = {}
    for d in FROZEN_DIRS:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            for fn in sorted(filenames):
                p = os.path.join(dirpath, fn)
                with open(p, "rb") as f:
                    out[os.path.relpath(p, root).replace(os.sep, "/")] = hashlib.sha256(f.read()).hexdigest()
    return out


def load_baseline():
    try:
        with open(BASELINE, encoding="utf-8") as f:
            base = json.load(f)
        base["files"], base["calls"]
        return base
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise Incomplete("AF6 读不到基线 %s：%s" % (os.path.relpath(BASELINE, REPO_ROOT), e))


def run_ast(root):
    tool = lint.hm10_toolchain()
    files = {}
    for rel in REQUIRED:
        text = read(root, rel)
        if text is None:
            raise Incomplete("%s: 文件不存在，无法判定" % rel)
        files[rel] = text
    payload = json.dumps({"files": files}, ensure_ascii=False).encode("utf-8")
    try:
        proc = subprocess.run([tool["node"], AST_TOOL, tool["typescript"]], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise lint.HM10ToolchainError("运行 node 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("a11yfunds_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("a11yfunds_ast.cjs 输出无法解析：%s" % e)
    if out["incomplete"]:
        raise Incomplete("；".join(out["incomplete"]))
    return out


# FU-HM-ROOTSHOWN-CHAIN（编排 D10-1668 批，#24）：本单对资金页 / 资金逻辑的窄改动。只认下面这些逐字的调用与新 sha，其余照旧判红。
AF6_D10_1668_REPLACED = {}
AF6_D10_1668_ADDED = {
    'features/wallet/src/main/ets/WithdrawView.ets': ('this.config.controller.subscribe((s:WithdrawSnapshot):void=>this.apply(s))',),
}
AF6_D10_1668_FROZEN = dict((rel, digest) for digest, rel in [
    ('1da3248a80ae1ce7dad3867af1c32f011a132977f159f4b51f46f5ab19892838', 'common/core/src/main/ets/wallet/WithdrawController.ets'),
])


def _multiset_diff(base, now):
    left = list(base)
    extra = []
    for c in now:
        if c in left:
            left.remove(c)
        else:
            extra.append(c)
    return left, extra


def check(root, with_frozen=True):
    """返回违反列表；文件缺失 / 语法错误抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
    out = run_ast(root)
    violations = list(out["violations"])
    base = load_baseline()
    for rel, now in sorted(out["calls"].items()):
        want = base["calls"].get(rel)
        if want is None:
            raise Incomplete("AF6 基线里没有 %s 的调用集合" % rel)
        missing, extra = _multiset_diff(want, now)
        # FU-HM-ROOTSHOWN-CHAIN ③（编排 D10-1668 批，#24）：提现页对执行器的单槽 onChange 赋值换成按页订阅 / 注销；这一换不算资金动作变化。
        missing = [c for c in missing if c not in AF6_D10_1668_REPLACED.get(rel, ())]
        extra = [c for c in extra if c not in AF6_D10_1668_ADDED.get(rel, ())]
        for c in missing:
            violations.append({"rule": "AF6-calls", "file": rel, "line": 0, "msg": "资金调用少了 / 改了：%s（只能加读屏调用，不改资金动作）" % c})
        for c in extra:
            violations.append({"rule": "AF6-calls", "file": rel, "line": 0, "msg": "多了资金调用：%s（资金页只动视图，不新增资金动作）" % c})
    if with_frozen:
        now = frozen_digests(root)
        for rel in sorted(set(base["files"]) | set(now)):
            if rel not in now:
                violations.append({"rule": "AF6-frozen", "file": rel, "line": 0, "msg": "冻结的资金逻辑文件被删（基线 2a4b1c8）"})
            elif rel not in base["files"]:
                violations.append({"rule": "AF6-frozen", "file": rel, "line": 0, "msg": "冻结目录里新增了文件（本单不碰 core / entry wallet）"})
            elif now[rel] != base["files"][rel] and now[rel] != AF6_D10_1668_FROZEN.get(rel):
                violations.append({"rule": "AF6-frozen", "file": rel, "line": 0, "msg": "冻结的资金逻辑文件有改动（sha256 ≠ 基线 2a4b1c8）"})
    check.stats = out.get("stats", {})
    return violations


check.stats = {}


def render(violations):
    groups = {}
    for v in violations:
        groups.setdefault(v["rule"].split("-")[0], []).append(v)
    for key in sorted(RULE_TITLES):
        state = "红" if key in groups else "绿"
        print("%s %s：%s（%d 处）" % (key, state, RULE_TITLES[key], len(groups.get(key, []))))
    for v in sorted(violations, key=lambda x: (x["rule"], x["file"], x["line"])):
        print("  [%s] %s:%d %s" % (v["rule"], v["file"], v["line"], v["msg"]))
    if check.stats:
        print("  （%s）" % json.dumps(check.stats, ensure_ascii=False))


# ---------------------------------------------------------------- 自测：参照件叠加在真实树上，逐个变异全部要杀
FOCUS_CALL = "              CouliFocusReturn.accessibilityFocus(ui, ID_AMOUNT);\n"
RECHECK = "            if (this.alive && this.lastBannerSeq === seq && this.model.amountError.length > 0 && this.model.editable) {\n"
FOCUS = ("          const seq: number = s.banner.seq;\n          setTimeout(() => {\n"
         "            // 执行时复核：页面仍在、没有更新的 banner、仍是金额类错误（改金额 / 非金额类错误已清空）、金额框仍可编辑。\n"
         + RECHECK + FOCUS_CALL + "            }\n          }, A11Y_ERROR_DELAY_MS);\n")
FOCUS_V1 = "          setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, ID_AMOUNT), A11Y_ERROR_DELAY_MS);\n"
RESTORE = "                  this.model.inputShown = this.model.inputText;\n"
AMOUNT_IF = "      if (isAmountError(s.banner.textKey)) {\n"
SET_ERR = "        m.amountError = s.banner.text;\n"
REJECT = """                this.model.inputShown = value;
                setTimeout(() => {
                  this.model.inputShown = this.model.inputText;
                }, 0);
"""
AMOUNT_KEY = "      }, (_v: number) => 'withdraw_amount_' + this.model.editable + '_' + (this.model.pending !== null))"
HERO_KEY = "      }, (v: number) => 'wallet_hero_' + v + '_' + this.model.withdrawAllowed)"
EYE_ID = "          .id(this.eyeId.length > 0 ? this.eyeId : '')\n"
TITLE_TIMER = """                setTimeout(() => {
                  if (this.alive) {
                    CouliFocusReturn.accessibilityFocus(ui, 'step_up_title');
                  }
                }, STEP_UP_TITLE_FOCUS_DELAY_MS);
"""
TITLE_APPEAR = """              .onAppear(() => {
                // FU-HM-A11Y-08：半屏弹出后读屏焦点进标题（只移读屏焦点；验证码框仍拿键盘默认焦点）。
                const ui: UIContext = this.getUIContext();
""" + TITLE_TIMER + """              })
"""
HERO_TEXT = "        Text(this.amountHidden ? PriceTerms.amountMask : this.amount)\n"
GRID_LABEL_NO = "          // FU-HM-A11Y-19：标签已在金额的读屏名里（「标签，金额」），这里不再单独读。\n          .accessibilityLevel('no')\n"
HERO_LABEL_NO = "            // FU-HM-A11Y-19：标签已在大数字的读屏名里。\n            .accessibilityLevel('no')\n"
ROW_LEVEL = "      .accessibilityLevel(item.helpLabel.length === 0 ? 'no' : 'auto')\n"

# （名字，文件，原串，新串，应报的规则前缀）：原串在参照件里必须恰好出现一次。
MUTATIONS = [
    # AF1
    ("description 接错字段（bannerText）", WITHDRAW, "            .accessibilityDescription(this.model.amountError)\n",
     "            .accessibilityDescription(this.model.bannerText)\n", "AF1-desc"),
    ("description 接错字段（errorText）", WITHDRAW, "            .accessibilityDescription(this.model.amountError)\n",
     "            .accessibilityDescription(this.model.errorText)\n", "AF1-desc"),
    ("金额框没有 description", WITHDRAW, "            .accessibilityDescription(this.model.amountError)\n", "", "AF1-desc"),
    ("说明字段非金额类也写入", WITHDRAW, "      } else {\n        m.amountError = '';\n      }\n",
     "      } else {\n        m.amountError = s.banner.text;\n      }\n", "AF1-desc"),
    ("说明字段从不清空", [(WITHDRAW, "    if (s.banner === null) {\n      m.amountError = '';\n    }\n", ""),
                          (WITHDRAW, "      } else {\n        m.amountError = '';\n      }\n", "      }\n")], None, None, "AF1-desc"),
    ("焦点给非金额码也移", WITHDRAW, AMOUNT_IF, "      if (s.banner.text.length > 0) {\n", "AF1"),
    ("焦点 id 写成 withdraw_submit", WITHDRAW, FOCUS_CALL,
     "              CouliFocusReturn.accessibilityFocus(ui, ID_SUBMIT);\n", "AF1-focus"),
    ("焦点改用 CouliFocusReturn.to（弹键盘）", WITHDRAW, FOCUS_CALL,
     "              CouliFocusReturn.to(ui, ID_AMOUNT);\n", "AF1-focus"),
    ("不可编辑时也移焦（排队与执行时都不查 editable）", WITHDRAW, "        if (m.editable) {\n" + FOCUS + "        }\n",
     FOCUS.replace(" && this.model.editable", ""), "AF1-focus"),
    ("删掉移焦", WITHDRAW, FOCUS, "", "AF1-focus"),
    ("移焦挪到播报块外（不同路）", [(WITHDRAW, "        if (m.editable) {\n" + FOCUS + "        }\n", ""),
                              (WITHDRAW, "    this.lastPendingKey = key;\n", "    this.lastPendingKey = key;\n"
                               "    if (s.banner !== null && isAmountError(s.banner.textKey) && m.editable) {\n"
                               "      setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, ID_AMOUNT), A11Y_ERROR_DELAY_MS);\n    }\n")],
     None, None, "AF1-focus"),
    # AF7（v2，Codex r1 S2-3）：延时移焦执行时复核
    ("金额移焦无条件延时发送（v1 写法）", WITHDRAW, FOCUS, FOCUS_V1, "AF7-amount"),
    ("金额移焦执行时不复核页面仍在", WITHDRAW, RECHECK, RECHECK.replace("this.alive && ", ""), "AF7-amount"),
    ("金额移焦执行时不复核错误序号", WITHDRAW, RECHECK, RECHECK.replace("this.lastBannerSeq === seq && ", ""), "AF7-amount"),
    ("金额移焦执行时不复核仍是金额类错误", WITHDRAW, RECHECK, RECHECK.replace(" && this.model.amountError.length > 0", ""), "AF7-amount"),
    ("金额移焦执行时不复核可编辑（只在排队时查）", WITHDRAW, RECHECK, RECHECK.replace(" && this.model.editable", ""), "AF7-amount"),
    ("错误序号在回调里现取（不是排队时捕获）", WITHDRAW, FOCUS,
     FOCUS.replace("          const seq: number = s.banner.seq;\n", "").replace(
         "          setTimeout(() => {\n", "          setTimeout(() => {\n            const seq: number = this.lastBannerSeq;\n"), "AF7-amount"),
    ("复核条件在排队时就算好（局部 const 旧值）", WITHDRAW, FOCUS,
     FOCUS.replace("          setTimeout(() => {\n", "          const live: boolean = this.alive && this.model.editable;\n          setTimeout(() => {\n").replace(
         "this.alive && this.lastBannerSeq === seq && this.model.amountError.length > 0 && this.model.editable",
         "live && this.lastBannerSeq === seq && this.model.amountError.length > 0"), "AF7-amount"),
    ("生命周期标志离页不置 false", WITHDRAW, "  aboutToDisappear(): void {\n    this.alive = false;\n", "  aboutToDisappear(): void {\n", "AF7-amount"),
    ("生命周期标志从不置 true（初值 false）", WITHDRAW, "    this.alive = true;\n", "", "AF7-amount"),
    ("经页面方法延时、方法里不复核", [
        (WITHDRAW, FOCUS, "          setTimeout(() => this.focusAmountNow(ui), A11Y_ERROR_DELAY_MS);\n"),
        (WITHDRAW, "  private pageAvoid(resize: boolean): void {",
         "  private focusAmountNow(ui: UIContext): void {\n    CouliFocusReturn.accessibilityFocus(ui, ID_AMOUNT);\n  }\n\n"
         "  private pageAvoid(resize: boolean): void {")], None, None, "AF7-amount"),
    ("setTimeout(this.方法) 引用、方法里不复核", [
        (WITHDRAW, FOCUS, "          this.pendingUi = ui;\n          setTimeout(this.focusAmountLater, A11Y_ERROR_DELAY_MS);\n"),
        (WITHDRAW, "  private pageAvoid(resize: boolean): void {",
         "  private pendingUi: UIContext | null = null;\n\n  private focusAmountLater(): void {\n    if (this.pendingUi !== null) {\n"
         "      CouliFocusReturn.accessibilityFocus(this.pendingUi, ID_AMOUNT);\n    }\n  }\n\n"
         "  private pageAvoid(resize: boolean): void {")], None, None, "AF7-amount"),
    ("取消式只在新错误前 clearTimeout、离页不取消也不复核", [
        (WITHDRAW, FOCUS, "          clearTimeout(this.amountFocusTimer);\n          this.amountFocusTimer = setTimeout(() => {\n"
         "            if (this.model.amountError.length > 0 && this.model.editable) {\n" + FOCUS_CALL + "            }\n"
         "          }, A11Y_ERROR_DELAY_MS);\n"),
        (WITHDRAW, "  private alive: boolean = false;\n", "  private alive: boolean = false;\n  private amountFocusTimer: number = -1;\n")],
     None, None, "AF7-amount"),
    ("标题移焦无条件延时发送（v1 写法）", STEP_UP, TITLE_TIMER,
     "                setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, 'step_up_title'), STEP_UP_TITLE_FOCUS_DELAY_MS);\n", "AF7-title"),
    ("面板离页不置 alive=false", STEP_UP, "    this.alive = false;\n", "", "AF7-title"),
    ("标题移焦复核的是别的字段（lastClear 不是生命周期）", STEP_UP, "                  if (this.alive) {\n",
     "                  if (this.lastClear >= 0) {\n", "AF7-title"),
    ("金额类判定换成本页自写函数", WITHDRAW, "import { isAmountError } from './WithdrawA11y';\n",
     "function isAmountError(k: string): boolean {\n  return k.startsWith('error.303');\n}\n", "AF1-fn"),
    # AF2
    ("ForEach 键加回 inputReset", WITHDRAW, AMOUNT_KEY,
     "      }, (_v: number) => 'withdraw_amount_' + this.model.editable + '_' + (this.model.pending !== null) + '_' + this.model.inputReset)",
     "AF2-key"),
    ("被拒分支改键字段 editable（照样重建）", WITHDRAW, REJECT,
     REJECT + "                this.model.editable = !this.model.editable;\n", "AF2-key"),
    ("被拒分支什么都不做（框里留着被拒串）", WITHDRAW, REJECT, "                // 不处理\n", "AF2-restore"),
    ("被拒分支写回的不是已接受值", WITHDRAW, RESTORE,
     "                  this.model.inputShown = value;\n", "AF2-restore"),
    # AF2-restore（v2，Codex r1 S2-2）：回填一定执行、一定生效
    ("删掉被拒串写入（inputShown = value）", WITHDRAW, "                this.model.inputShown = value;\n                setTimeout(() => {\n",
     "                setTimeout(() => {\n", "AF2-restore"),
    ("回填写进 if (false)", WITHDRAW, RESTORE,
     "                  if (false) {\n                    this.model.inputShown = this.model.inputText;\n                  }\n", "AF2-restore"),
    ("整个回填 setTimeout 写进 if (false)", WITHDRAW, REJECT, "                this.model.inputShown = value;\n                if (false) {\n"
     "                  setTimeout(() => {\n                    this.model.inputShown = this.model.inputText;\n                  }, 0);\n"
     "                }\n", "AF2-restore"),
    ("回填改成同步（同一轮两次写入合并成没变）", WITHDRAW, REJECT,
     "                this.model.inputShown = value;\n                this.model.inputShown = this.model.inputText;\n", "AF2-restore"),
    ("回填在 return 之后（执行不到）", WITHDRAW, RESTORE, "                  return;\n" + RESTORE, "AF2-restore"),
    ("回填写进从不调用的箭头函数", WITHDRAW, RESTORE,
     "                  const restore = (): void => {\n                    this.model.inputShown = this.model.inputText;\n                  };\n",
     "AF2-restore"),
    ("被拒串写入挪进延时回调（显示状态同一轮没变）", WITHDRAW, REJECT, "                setTimeout(() => {\n"
     "                  this.model.inputShown = value;\n                  this.model.inputShown = this.model.inputText;\n                }, 0);\n",
     "AF2-restore"),
    ("被拒串写入带条件", WITHDRAW, "                this.model.inputShown = value;\n                setTimeout(() => {\n",
     "                if (value.length > 12) {\n                  this.model.inputShown = value;\n                }\n                setTimeout(() => {\n",
     "AF2-restore"),
    ("回填写进 while (false)", WITHDRAW, RESTORE,
     "                  while (false) {\n                    this.model.inputShown = this.model.inputText;\n                  }\n", "AF2-restore"),
    # AF3
    ("眼睛无 id", DS_WALLET, EYE_ID, "", "AF3-eye"),
    ("眼睛 id 写死不走参数", DS_WALLET, EYE_ID, "          .id('eye')\n", "AF3-eye"),
    ("钱包页不传 eyeId", WALLET, "      eyeId: ID_AMOUNT_EYE,\n", "", "AF3-eye"),
    ("钱包页传空 eyeId", WALLET, "      eyeId: ID_AMOUNT_EYE,\n", "      eyeId: '',\n", "AF3-eye"),
    ("主卡键留 masked、回焦却指向【提现】", [
        (WALLET, HERO_KEY, "      }, (v: number) => 'wallet_hero_' + v + '_' + this.maskUi.masked + '_' + this.model.withdrawAllowed)"),
        (WALLET, "      onToggleHidden: () => this.maskUi.toggle(),", """      onToggleHidden: () => {
        this.maskUi.toggle();
        CouliFocusReturn.to(this.getUIContext(), 'wallet_withdraw');
      },"""),
        (WALLET, "  CouliFontWeight, CouliFormat,", "  CouliFocusReturn, CouliFontWeight, CouliFormat,")], None, None, "AF3-stable"),
    ("主卡键经页面方法读 masked", [
        (WALLET, HERO_KEY, "      }, (v: number) => this.heroKey(v))"),
        (WALLET, "  @Builder\n  heroCard() {", "  private heroKey(v: number): string {\n    return 'wallet_hero_' + v + '_' + this.maskUi.masked;\n  }\n\n  @Builder\n  heroCard() {")],
     None, None, "AF3-stable"),
    ("主卡键加回 masked 且无回焦", WALLET, HERO_KEY,
     "      }, (v: number) => 'wallet_hero_' + v + '_' + this.maskUi.masked + '_' + this.model.withdrawAllowed)", "AF3-stable"),
    # AF3-mask（v2，Codex r1 S2-4）
    ("主卡始终 Text(this.amount)", DS_WALLET, HERO_TEXT, "        Text(this.amount)\n", "AF3-mask"),
    ("主卡隐藏 / 显示两支写反", DS_WALLET, HERO_TEXT, "        Text(this.amountHidden ? this.amount : PriceTerms.amountMask)\n", "AF3-mask"),
    ("主卡读屏名隐藏时仍读金额", DS_WALLET, "            + (this.amountHidden ? PriceTerms.amountHiddenSpoken : this.amountSpoken))",
     "            + this.amountSpoken)", "AF3-mask"),
    ("主卡数字格 masked 写死 false", DS_WALLET, "          masked: this.amountHidden,\n", "          masked: false,\n", "AF3-mask"),
    ("amountHidden 改 @Param @Once（不重建时冻住旧值）", DS_WALLET, "  @Param amountHidden: boolean = false;",
     "  @Param @Once amountHidden: boolean = false;", "AF3-mask"),
    ("钱包页 amountHidden 写死 false", WALLET, "      amountHidden: this.maskUi.masked,\n", "      amountHidden: false,\n", "AF3-mask"),
    ("主卡多一处不受隐藏控制的金额（读屏名）", DS_WALLET, "          .flexGrow(1)\n        CouliButton({",
     "          .flexGrow(1)\n          .accessibilityDescription(this.amount)\n        CouliButton({", "AF3-mask"),
    ("格金额始终 item.value", DS_WALLET, "      Text(this.hides(item) ? PriceTerms.amountMask : item.value)\n", "      Text(item.value)\n", "AF3-mask"),
    # AF4
    ("标题 onAppear 删除", STEP_UP, TITLE_APPEAR, "", "AF4-title"),
    ("标题焦点改用 CouliFocusReturn.to（抢键盘焦点）", STEP_UP,
     "CouliFocusReturn.accessibilityFocus(ui, 'step_up_title')", "CouliFocusReturn.to(ui, 'step_up_title')", "AF4-title"),
    ("标题 onAppear 移焦到关闭按钮", STEP_UP,
     "CouliFocusReturn.accessibilityFocus(ui, 'step_up_title')", "CouliFocusReturn.accessibilityFocus(ui, 'step_up_close')", "AF4-title"),
    ("验证码框不再 defaultFocus", STEP_UP, "        .id('step_up_code')\n        .defaultFocus(true)\n", "        .id('step_up_code')\n", "AF4-code"),
    ("标题抢 defaultFocus", STEP_UP, "              .id('step_up_title')\n", "              .id('step_up_title')\n              .defaultFocus(true)\n", "AF4-code"),
    # AF5
    ("格标签恢复可读", DS_WALLET, GRID_LABEL_NO, "", "AF5-dup"),
    ("格标签行恢复成组", DS_WALLET, ROW_LEVEL, "      .accessibilityGroup(item.helpLabel.length === 0)\n", "AF5-dup"),
    ("主卡标签恢复可读", DS_WALLET, HERO_LABEL_NO, "", "AF5-dup"),
    ("格金额读屏名丢标签", DS_WALLET, "        .accessibilityText(item.label + PriceTerms.comma + (this.hides(item)",
     "        .accessibilityText(PriceTerms.comma + (this.hides(item)", "AF5-spoken"),
    ("主卡金额读屏名丢标签", DS_WALLET, "          .accessibilityText(this.label + PriceTerms.comma\n",
     "          .accessibilityText(PriceTerms.comma\n", "AF5-spoken"),
    ("标签行整行隐藏连问号一起藏", DS_WALLET, ROW_LEVEL, "      .accessibilityLevel('no-hide-descendants')\n", "AF5-help"),
    # AF6
    ("多一处控制器调用（提现页）", WITHDRAW, "                this.model.inputShown = value;\n",
     "                this.model.inputShown = value;\n                this.config.controller.retryRules();\n", "AF6-calls"),
    ("改了 setInput 实参", WITHDRAW, "              if (!this.config.controller.setInput(value)) {",
     "              if (!this.config.controller.setInput(value.trim())) {", "AF6-calls"),
    ("眼睛切换顺带刷新钱包（新增资金动作）", WALLET, "      onToggleHidden: () => this.maskUi.toggle(),",
     "      onToggleHidden: () => {\n        this.maskUi.toggle();\n        this.config.controller.refresh();\n      },", "AF6-calls"),
    ("面板出现时自动发码（新增驱动调用）", STEP_UP, "                const ui: UIContext = this.getUIContext();\n",
     "                const ui: UIContext = this.getUIContext();\n                this.driver.send();\n", "AF6-calls"),
]

# 良性改写（不得误报）：(名字, [(文件, 原串, 新串), ...])
BENIGN = [
    ("移焦用提前 return 守卫、写进页面方法（执行时同样提前 return 复核）", [
        (WITHDRAW, "        if (m.editable) {\n" + FOCUS + "        }\n", "        this.focusAmount(ui);\n"),
        (WITHDRAW, "  private pageAvoid(resize: boolean): void {", """  private focusAmount(ui: UIContext): void {
    if (!this.model.editable) {
      return;
    }
    const seq: number = this.lastBannerSeq;
    setTimeout(() => {
      if (!this.alive || this.lastBannerSeq !== seq || this.model.amountError.length === 0 || !this.model.editable) {
        return;
      }
      CouliFocusReturn.accessibilityFocus(ui, 'withdraw_amount');
    }, A11Y_ERROR_DELAY_MS);
  }

  private pageAvoid(resize: boolean): void {"""),
    ]),
    ("金额类判定先存局部 const", [
        (WITHDRAW, AMOUNT_IF, "      const amountErr: boolean = isAmountError(s.banner.textKey);\n      if (amountErr) {\n"),
    ]),
    ("说明写入用三元（非金额类写空串）", [
        (WITHDRAW, SET_ERR, ""),
        (WITHDRAW, "      } else {\n        m.amountError = '';\n      }\n", "      }\n      m.amountError = isAmountError(s.banner.textKey) ? s.banner.text : '';\n"),
    ]),
    ("眼睛保留 masked 键、改走回焦兜底（任务书 §2.3 备选）", [
        (WALLET, HERO_KEY, "      }, (v: number) => 'wallet_hero_' + v + '_' + this.maskUi.masked + '_' + this.model.withdrawAllowed)"),
        (WALLET, "      onToggleHidden: () => this.maskUi.toggle(),", """      onToggleHidden: () => {
        this.maskUi.toggle();
        CouliFocusReturn.to(this.getUIContext(), ID_AMOUNT_EYE);
      },"""),
        (WALLET, "  CouliFontWeight, CouliFormat,", "  CouliFocusReturn, CouliFontWeight, CouliFormat,"),
    ]),
    ("标题读屏焦点挂在外层 Row 的 onAppear", [
        (STEP_UP, TITLE_APPEAR, ""),
        (STEP_UP, "          .alignItems(VerticalAlign.Top)\n          .width('100%')\n          .onAreaChange((_old: Area, now: Area) => {\n            this.headerVp",
         "          .alignItems(VerticalAlign.Top)\n          .width('100%')\n          .onAppear(() => {\n            const ui: UIContext = this.getUIContext();\n"
         "            setTimeout(() => {\n              if (!this.alive) {\n                return;\n              }\n"
         "              CouliFocusReturn.accessibilityFocus(ui, 'step_up_title');\n            }, STEP_UP_TITLE_FOCUS_DELAY_MS);\n          })\n"
         "          .onAreaChange((_old: Area, now: Area) => {\n            this.headerVp"),
    ]),
    ("金额框用 $$ 双向绑定、被拒写回控制器快照", [
        (WITHDRAW, "          TextInput({ text: this.model.inputShown,", "          TextInput({ text: $$this.model.inputShown,"),
        (WITHDRAW, REJECT, "                this.model.inputShown = this.config.controller.snapshot.inputText;\n"),
    ]),
    ("取消式：句柄存字段，离页与新错误排队前 clearTimeout，回调复核当前状态", [
        (WITHDRAW, FOCUS, "          clearTimeout(this.amountFocusTimer);\n          this.amountFocusTimer = setTimeout(() => {\n"
         "            if (this.model.amountError.length > 0 && this.model.editable) {\n" + FOCUS_CALL + "            }\n"
         "          }, A11Y_ERROR_DELAY_MS);\n"),
        (WITHDRAW, "  private alive: boolean = false;\n", "  private alive: boolean = false;\n  private amountFocusTimer: number = -1;\n"),
        (WITHDRAW, "  aboutToDisappear(): void {\n    this.alive = false;\n",
         "  aboutToDisappear(): void {\n    this.alive = false;\n    clearTimeout(this.amountFocusTimer);\n"),
    ]),
    ("页面仍在用既有的 this.config.controller.alive", [
        (WITHDRAW, RECHECK, RECHECK.replace("this.alive && ", "this.config.controller.alive && ")),
    ]),
    ("金额类错误复核写成说明字段 !== ''、序号写成 seq === this.lastBannerSeq", [
        (WITHDRAW, RECHECK, "            if (this.alive && seq === this.lastBannerSeq && this.model.amountError !== '' && m.editable) {\n"),
    ]),
    ("被拒写回带页面生命周期复核", [
        (WITHDRAW, RESTORE, "                  if (this.alive) {\n    " + RESTORE + "                  }\n"),
    ]),
    ("主卡显示值三元写成 !this.amountHidden ? this.amount : 掩码", [
        (DS_WALLET, HERO_TEXT, "        Text(!this.amountHidden ? this.amount : PriceTerms.amountMask)\n"),
    ]),
    ("被拒判定先存局部 const", [
        (WITHDRAW, "              if (!this.config.controller.setInput(value)) {",
         "              const ok: boolean = this.config.controller.setInput(value);\n              if (!ok) {"),
    ]),
]


def _apply(root, rel, old, new, failures, what):
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.count(old) != 1:
        failures.append("%s 的原串出现 %d 次（应 1 次）" % (what, text.count(old)))
        return False
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(old, new))
    return True


def _good_tree(tmp, name):
    """参照件树：只放 REQUIRED（参照件版本）与 WithdrawA11y 参照件。AF6-frozen 另在真实拷贝树上测。"""
    root = os.path.join(tmp, name)
    for rel in REQUIRED + (A11Y_FN,):
        os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
        shutil.copy2(os.path.join(GOOD, rel), os.path.join(root, rel))
    return root


def _frozen_selftest(tmp, failures):
    """AF6-frozen：真实冻结目录拷贝树原样 0；改一个 / 加一个 / 删一个都要红。"""
    for idx, (name, mutate) in enumerate([
        ("改 WithdrawController", lambda r: open(os.path.join(r, "common/core/src/main/ets/wallet/WithdrawController.ets"), "a",
                                                  encoding="utf-8").write("\n// 变异\n")),
        ("在 entry wallet 新增文件", lambda r: open(os.path.join(r, "entry/src/main/ets/wallet/Extra.ets"), "w", encoding="utf-8").write("//\n")),
        ("删 WalletDraftTexts", lambda r: os.remove(os.path.join(r, "common/core/src/main/ets/wallet/WalletDraftTexts.ets"))),
    ]):
        root = os.path.join(tmp, "f%02d" % idx)
        for d in FROZEN_DIRS:
            shutil.copytree(os.path.join(REPO_ROOT, d), os.path.join(root, d))
        # D10-1668：基线按本单窄换钉的新 sha 计（只这两份执行器；其余文件仍须与基线逐字节相同）。
        base = dict(load_baseline()["files"])
        for rel, digest in AF6_D10_1668_FROZEN.items():
            if rel in base and frozen_digests(root).get(rel) == digest:
                base[rel] = digest
        if idx == 0 and frozen_digests(root) != base:
            failures.append("AF6-frozen 自测：真实冻结目录拷贝树 ≠ 基线（本仓库已改了 core / entry wallet？）")
            return
        mutate(root)
        if frozen_digests(root) == base:
            failures.append("AF6-frozen 自测：变异「%s」没被发现" % name)
        else:
            print("KILLED %s ← AF6-frozen" % name)


DEVICE_CASES = os.path.join(HERE, "device-cases.txt")
DEVICE_SUITE = os.path.join(REPO_ROOT, "entry", "src", "ohosTest", "ets", "test", "HmA11yFundsCases.ets")


def _device_names_selftest(failures):
    """设备名单 device-cases.txt 与 HmA11yFundsCases.ets 的 A11Y_FUNDS_DEVICE_CASES、段里 it(...) 名字逐条一致（顺序也一致）。"""
    import re
    with open(DEVICE_CASES, encoding="utf-8") as f:
        listed = [x.strip() for x in f if x.strip() and not x.startswith("#")]
    with open(DEVICE_SUITE, encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"A11Y_FUNDS_DEVICE_CASES: string\[\] = \[(.*?)\];", src, re.S)
    const = re.findall(r"'([^']+)'", m.group(1)) if m else []
    its = re.findall(r"\bit\('([^']+)'", src)
    if not (listed == const == its) or len(set(listed)) != len(listed) or not all(x.startswith("a11y_funds_") for x in listed):
        failures.append("设备名单不一致：device-cases.txt %s / 常量 %s / it %s" % (listed, const, its))
    else:
        print("DEVICE_NAMES %d 条：device-cases.txt = A11Y_FUNDS_DEVICE_CASES = 段内 it（同序、a11y_funds_ 前缀、无重复）" % len(listed))


def self_test():
    failures = []
    _device_names_selftest(failures)
    with tempfile.TemporaryDirectory(prefix="a11yfunds-selftest-") as tmp:
        good = _good_tree(tmp, "good")
        got = check(good, with_frozen=False)
        if got:
            failures.append("参照件不过：%s" % [(v["rule"], v["file"], v["line"], v["msg"]) for v in got])
        else:
            print("REFERENCE 参照件 0 违反（%s）" % json.dumps(check.stats, ensure_ascii=False))
        for idx, (name, rel, old, new, want) in enumerate(MUTATIONS):
            root = _good_tree(tmp, "m%02d" % idx)
            edits = rel if isinstance(rel, list) else [(rel, old, new)]
            if not all([_apply(root, r, o, n, failures, "变异「%s」" % name) for r, o, n in edits]):
                continue
            try:
                rules = {v["rule"] for v in check(root, with_frozen=False)}
            except Incomplete as e:
                failures.append("变异「%s」解析不完整（变异写坏了，不算杀）：%s" % (name, e))
                continue
            if not any(r == want or r.startswith(want + "-") for r in rules):
                failures.append("变异「%s」没被 %s 杀（实际 %s）" % (name, want, sorted(rules)))
            else:
                print("KILLED %s ← %s" % (name, ", ".join(sorted(rules))))
            shutil.rmtree(root)
        for idx, (name, edits) in enumerate(BENIGN):
            root = _good_tree(tmp, "b%02d" % idx)
            ok = True
            for rel, old, new in edits:
                ok = _apply(root, rel, old, new, failures, "良性改写「%s」" % name) and ok
            if not ok:
                continue
            try:
                got = check(root, with_frozen=False)
            except Incomplete as e:
                failures.append("良性改写「%s」解析不完整：%s" % (name, e))
                continue
            if got:
                failures.append("良性改写「%s」被误报：%s" % (name, [(v["rule"], v["msg"]) for v in got]))
            else:
                print("BENIGN %s：0 违反" % name)
            shutil.rmtree(root)
        cases = [
            ("语法错误", lambda r: open(os.path.join(r, WALLET), "a", encoding="utf-8").write("\nexport struct {\n")),
            ("缺文件", lambda r: os.remove(os.path.join(r, STEP_UP))),
            ("struct 改名", lambda r: _apply(r, WITHDRAW, "export struct WithdrawView {", "export struct WithdrawPage {", failures, "struct 改名")),
            ("WithdrawModel 改名", lambda r: _apply(r, WITHDRAW, "class WithdrawModel {", "class WithdrawState {", failures, "class 改名")),
        ]
        for idx, (name, mutate) in enumerate(cases):
            root = _good_tree(tmp, "x%02d" % idx)
            mutate(root)
            try:
                check(root, with_frozen=False)
                failures.append("%s应该按 Incomplete 退出，却正常返回" % name)
            except Incomplete:
                print("FAIL-CLOSED %s → 4" % name)
        _frozen_selftest(tmp, failures)
    total = len(MUTATIONS) + len(BENIGN) + 4 + 3 + 1
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("A11YFUNDS_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("A11YFUNDS_SELFTEST 通过：参照件 1 + 变异 %d 全杀 + 良性改写 %d 全绿 + 语法错误 / 缺文件 / 缺 struct / 缺 class fail-closed"
          " + AF6-frozen（真实拷贝树原样 = 基线，改 / 加 / 删即红）" % (len(MUTATIONS), len(BENIGN)))
    return 0


def print_baseline(root):
    """只打印（不写文件）：生成 fixtures/frozen-baseline-*.json 用（测试作者在基线树上跑一次，结果入 fixture）。"""
    out = run_ast(root)
    print(json.dumps({"rev": "2a4b1c8", "dirs": list(FROZEN_DIRS), "files": frozen_digests(root), "calls": out["calls"]},
                     ensure_ascii=False, indent=1, sort_keys=True))
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", default=REPO_ROOT)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--print-baseline", action="store_true")
    try:
        args = ap.parse_args()
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        if args.print_baseline:
            return print_baseline(os.path.abspath(args.root))
        if args.self_test:
            return self_test()
        violations = check(os.path.abspath(args.root))
    except lint.HM10ToolchainError as e:
        print("A11YFUNDS 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("A11YFUNDS 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    if violations:
        print("A11YFUNDS_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("A11YFUNDS_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
