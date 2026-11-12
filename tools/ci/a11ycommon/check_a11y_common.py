#!/usr/bin/env python3
"""FU-HM-A11Y-COMMON-harmony（三端共性 ①③④；QA-12b harmony-audit FU-HM-A11Y-06 / 07 / 09；D10-1231；编排裁定 D10-1248 ③⑧⑨）宿主结构守卫（测试作者 v1，先红）。

用法：
    python3 tools/ci/a11ycommon/check_a11y_common.py [--root <目录>]    # 检查（默认仓库根）
    python3 tools/ci/a11ycommon/check_a11y_common.py --self-test        # 参照件（fixtures/good）全过 + 每个变异都要被杀 + 良性改写不误报

退出码：0 通过；1 有违反（自测：有变异没被杀、参照件不过或良性改写被误报）；2 参数不对；3 解析工具链不可用（复用 lint.hm10_toolchain，
node + 鸿蒙 SDK ohos-typescript）；4 无法保证判定完整（文件缺失、语法错误、找不到 struct / class、me12wc 基线读不到）。解析错误不算「红在断言」，一律 4。

判定在 a11ycommon_ast.cjs（AST，不用正则切块；注释与字符串里的字不算）。规则：
    AC1 订单【复制】读屏名带本行单号（共性 ①，FU-HM-A11Y-09，D10-1248 ⑨）：
        AC1-draft  草稿表 OrderDraftTexts 的 order_list.copy_spoken 恰一处，值 =「复制订单号 {no}」
        AC1-label  D10-1275：草稿表 order_list.copy_label 恰一处「复制」；OrderNumberRow 的 copyText = <t>(键) 且键解析为 order_list.copy_label
                   （契约快照待升锁，升锁前草稿表兜底）
        AC1-copy   订单列表、详情里每个 OrderNumberRow 的 copySpoken 实参沿 OrderView 字段 / this.<方法>() / 局部 const / 三元解析到
                   <texts>.format(<COPY_SPOKEN 键>, M)，M 是本函数里的 Map，set 了草稿值里的每个占位名（{no}），{no} 的值在该路径上
                   （三元 / if 条件记成事实）取本行完整单号（orderNo），不经脱敏 / 读屏读法；t(COPY_SPOKEN) 这类不带变量的常量、判不了一律红。
                   空串分支（不可复制）允许。不钉订单号行的 wordBreak（D10-1248 ⑧，另开 FU-HM-NUM-WRAP）
    AC2 问号说明关闭后焦点回问号（共性 ③，FU-HM-A11Y-06）：
        AC2-help-return  钱包 / 提现页每个说明弹窗（primaryText = wallet.help.ok）设 returnFocusId，按调用点（参数位）解析成非空静态 id
        AC2-help-target  Button.onClick 打开的：returnFocusId ∈ 该 Button 的 id；AmountGrid / WalletHeroCard 的 onHelp 打开的：returnFocusId
                         = 该组件实参里的问号 id 前缀 + 非空条目键
        AC2-help-id      问号 Button 没挂 id、AmountGrid / WalletHeroCard 没给前缀
        AC2-help-trigger 判不了由哪个问号打开；AC2-help-missing 页内问号触发点少于（钱包 3、提现 1）或没有说明弹窗
        AC2-grid-id      Wallet.ets AmountGrid 的问号 Button 挂 id，id 带调用方给的 @Param 前缀、按条目（item.<键>）、不用下标 index
        AC2-hero-pass    WalletHeroCard 内的 AmountGrid 前缀实参是 WalletHeroCard 自己的 @Param（调用方可给）
        AC2-id-unique    同一页各问号回焦 id 互不相同；同一 id 不挂在两个组件上
    AC3 点遮罩不关的确认弹窗系统返回 / 读屏返回手势可关（共性 ④，FU-HM-A11Y-07 + 书外 4 处，D10-1248 ③）：
        AC3-back       全仓（features/*/src/main、entry/src/main 的 .ets）：X.dismissOnMask = <非 true> 的同一语句块或外层块里要有
                       X.backDismisses = true（不认 if 分支里的）；豁免名单 EXEMPT 现为空（加项要编排批）
        AC3-back-false 任何 X.backDismisses = <非 true>
        AC3-mask       本单 8 处（Withdraw / PayoutAccount 的 openRiskDialog、confirmAbandon，Login 的 showBlocked、showOAuthRiskBlocked，
                       BindPhone 的 showRiskBlocked、confirmMerge）仍是 dismissOnMask = false（点遮罩不关）
        AC3-exit       资金页（提现、收款账号）：主按钮 withdraw.ok（【知道了】）的弹窗 onDismissed 必须存在且调用集合 = onPrimary 的（dismissRisk）；
                       主按钮 pending_confirm.abandon.ok（放弃）的 onDismissed 不存在或只调 onSecondary 已调的（等同【取消】，不调 abandon、
                       不新增资金动作）；其余主按钮未分类即红。绑定页合并确认 onDismissed 与 onSecondary 同一出口（CANCEL）
    AC4 AC4-frozen：me12wc 冻结的 core wallet / entry wallet 等逻辑文件对基线 0 差异（直接调 tools/ci/me12wc/check_risk_visual.py 的 G1，
        不另写基线；只在被检树里有 me12wc 基线时判，参照件自测另做一棵真实文件拷贝树）

不判（交设备 / 真机）：读屏播报与读屏焦点落点（模拟器读不到，D10-1231）；按返回后弹窗确实消失、焦点回到哪个控件（HmA11yUi a11y_common_02–04）。
"""

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
AST_TOOL = os.path.join(HERE, "a11ycommon_ast.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")

DRAFT = "common/core/src/main/ets/orders/OrderDraftTexts.ets"
KIT = "features/orders/src/main/ets/OrderViewKit.ets"
LIST = "features/orders/src/main/ets/OrderListView.ets"
DETAIL = "features/orders/src/main/ets/OrderDetailView.ets"
DS_WALLET = "common/designsystem/src/main/ets/components/Wallet.ets"
WALLET = "features/wallet/src/main/ets/WalletView.ets"
WITHDRAW = "features/wallet/src/main/ets/WithdrawView.ets"
PAYOUT = "features/wallet/src/main/ets/PayoutAccountView.ets"
LOGIN = "features/auth/src/main/ets/LoginView.ets"
BIND = "features/auth/src/main/ets/BindPhoneView.ets"
REQUIRED = (DRAFT, KIT, LIST, DETAIL, DS_WALLET, WALLET, WITHDRAW, PAYOUT, LOGIN, BIND)
SKIP_DIRS = {"build", "oh_modules", "node_modules", ".hvigor", ".preview", ".test"}

RULE_TITLES = {
    "AC1": "订单【复制】读屏名带本行完整单号（复制订单号 {no}）",
    "AC2": "问号说明弹窗关闭后焦点回到点开它的问号（id 按条目、互不相同）",
    "AC3": "点遮罩不关的确认弹窗系统返回可关，返回 = 现有【知道了】/【取消】",
    "AC4": "me12wc 冻结的 core wallet / entry wallet 对基线 0 差异",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_a11ycommon", os.path.join(HERE, "..", "lint.py"))
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


def scan_files(root):
    """AC3 扫描范围：features/*/src/main 与 entry/src/main 下全部 .ets（不含 src/test、src/ohosTest、staging / release 变体）。"""
    out = []
    bases = [os.path.join(root, "entry", "src", "main")]
    feats = os.path.join(root, "features")
    if os.path.isdir(feats):
        for name in sorted(os.listdir(feats)):
            bases.append(os.path.join(feats, name, "src", "main"))
    for base in bases:
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for fn in sorted(filenames):
                if fn.endswith(".ets"):
                    out.append(os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/"))
    return out


def me12wc_g1(root):
    """AC4：调 me12wc 现有 G1（基线 fixture 钉 sha256）。被检树里没有 me12wc 守卫 / 基线时返回 None（不判）。"""
    tool = os.path.join(root, "tools", "ci", "me12wc", "check_risk_visual.py")
    if not os.path.isfile(tool):
        return None
    spec = importlib.util.spec_from_file_location("couli_me12wc_for_a11ycommon_%d" % abs(hash(root)), tool)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    from pathlib import Path
    base, err = mod.load_fixture(Path(root))
    if err:
        raise Incomplete("AC4 读不到 me12wc 基线：%s" % err)
    return [{"rule": "AC4-frozen", "file": "tools/ci/me12wc", "line": 0, "msg": m + "（本单不碰 me12wc 冻结件）"}
            for m in mod.check_logic(Path(root), base)]


def check(root, with_frozen=True):
    """返回违反列表；文件缺失 / 语法错误抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
    tool = lint.hm10_toolchain()
    files = {}
    for rel in REQUIRED:
        text = read(root, rel)
        if text is None:
            raise Incomplete("%s: 文件不存在，无法判定" % rel)
        files[rel] = text
    scan = scan_files(root)
    for rel in scan:
        if rel not in files:
            text = read(root, rel)
            if text is not None:
                files[rel] = text
    payload = json.dumps({"files": files, "scan": scan}, ensure_ascii=False).encode("utf-8")
    try:
        proc = subprocess.run([tool["node"], AST_TOOL, tool["typescript"]], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise lint.HM10ToolchainError("运行 node 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("a11ycommon_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("a11ycommon_ast.cjs 输出无法解析：%s" % e)
    if out["incomplete"]:
        raise Incomplete("；".join(out["incomplete"]))
    violations = list(out["violations"])
    if with_frozen:
        frozen = me12wc_g1(root)
        if frozen is not None:
            violations.extend(frozen)
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
    s = check.stats
    if s:
        print("  （AC3 扫描 %s 个文件、dismissOnMask 非 true %s 处；AC2 问号触发点 %s；AC1 订单号行 %s 处）" % (
            s.get("scanned"), s.get("maskSites"), json.dumps(s.get("helpTriggers"), ensure_ascii=False), s.get("copyRows")))


# ---------------------------------------------------------------- 自测：参照件的变异，全部要杀
COPY_FIELD = "    this.copySpoken = this.copyable ? texts.format(OrderKeys.COPY_SPOKEN, copyVars) : '';\n"
COPY_SET = "    copyVars.set('no', this.orderNo);\n"
HELP_FROZEN = "this.help('wallet.help.frozen', this.t('wallet.frozen'), HELP_ID_PREFIX + 'frozen');"
HELP_EST = "this.help('wallet.help.estimated', this.t('wallet.estimated'), HELP_ID_PREFIX + 'estimated');"
PAUSED_ID = "          .id(ID_HELP_PAUSED)\n"
PAUSED_CALL = "this.help('wallet.help.pending_paused', this.t('wallet.help.title.pending_paused'), ID_HELP_PAUSED)"
GRID_ID = "          .id(this.helpIdPrefix.length > 0 && item.helpKey.length > 0 ? this.helpIdPrefix + item.helpKey : '')\n"
WD_RISK = "    options.dismissOnMask = false;\n    options.backDismisses = true;\n    options.returnFocusId = ID_SUBMIT;"
WD_ABANDON = "    options.dismissOnMask = false;\n    options.backDismisses = true;\n    options.returnFocusId = 'withdraw_abandon';"
PO_RISK = "    options.dismissOnMask = false;\n    options.backDismisses = true;\n    options.returnFocusId = ID_SAVE;"
PO_ABANDON = "    options.dismissOnMask = false;\n    options.backDismisses = true;\n    options.returnFocusId = 'payout_abandon';"
LG_CODE = "    options.dismissOnMask = false;\n    options.backDismisses = true;\n    options.returnFocusId = ID_CODE;"
LG_OAUTH = "    options.dismissOnMask = false;\n    options.backDismisses = true;\n    options.returnFocusId = 'login_oauth_' + provider;"
BD_RISK = ("    options.secondaryText = this.t(BindPhoneKeys.APPEAL);\n    options.dismissOnMask = false;\n"
           "    options.backDismisses = true;\n")
BD_MERGE = ("    options.secondaryText = this.t(BindPhoneKeys.MERGE_CANCEL);\n    options.dismissOnMask = false;\n"
            "    options.backDismisses = true;\n")
ME_PAGES = "entry/src/main/ets/me/MePages.ets"


def _no_back(block):
    return block.replace("    options.backDismisses = true;\n", "")


# （名字，文件，原串，新串，应报的规则前缀）：原串在参照件里必须恰好出现一次。
MUTATIONS = [
    # AC1
    ("列表复制名回常量 t(COPY_SPOKEN)", LIST, "copySpoken: view.copySpoken,", "copySpoken: this.t(OrderKeys.COPY_SPOKEN),", "AC1-copy"),
    ("详情复制名回常量 t(COPY_SPOKEN)", DETAIL, "copySpoken: view.copySpoken,", "copySpoken: this.t(OrderKeys.COPY_SPOKEN),", "AC1-copy"),
    ("复制按钮键回 order_list.copy", KIT, "  static readonly COPY: string = 'order_list.copy_label';",
     "  static readonly COPY: string = 'order_list.copy';", "AC1-label"),
    ("草稿表没有 copy_label", DRAFT, "    m.set('order_list.copy_label', '复制');\n", "    m.set('order_list.copy', '复制');\n", "AC1-label"),
    ("复制按钮文字改用复制读屏名的键", DETAIL, "copyText: this.t(OrderKeys.COPY),", "copyText: this.t(OrderKeys.COPY_SPOKEN),", "AC1-label"),
    ("复制名改用字面量", LIST, "copySpoken: view.copySpoken,", "copySpoken: '',", "AC1-copy"),
    ("草稿值回「复制订单号」", DRAFT, "m.set('order_list.copy_spoken', '复制订单号 {no}');", "m.set('order_list.copy_spoken', '复制订单号');", "AC1-draft"),
    ("草稿占位拼错 {num}", DRAFT, "m.set('order_list.copy_spoken', '复制订单号 {no}');", "m.set('order_list.copy_spoken', '复制订单号 {num}');", "AC1-draft"),
    ("代入名拼错 set('num')", KIT, COPY_SET, "    copyVars.set('num', this.orderNo);\n", "AC1-copy"),
    ("{no} 代入脱敏读法", KIT, COPY_SET, "    copyVars.set('no', OrderNumberDisplay.spoken(this.orderNo, texts.text(OrderKeys.STAR)));\n", "AC1-copy"),
    ("{no} 代入别的值（数量）", KIT, COPY_SET, "    copyVars.set('no', this.quantityText);\n", "AC1-copy"),
    ("格式化用错键 ORDER_NO_SPOKEN", KIT, COPY_FIELD,
     "    this.copySpoken = this.copyable ? texts.format(OrderKeys.ORDER_NO_SPOKEN, copyVars) : '';\n", "AC1-copy"),
    ("字段取固定文案 texts.text(COPY_SPOKEN)", KIT, COPY_FIELD, "    this.copySpoken = this.copyable ? texts.text(OrderKeys.COPY_SPOKEN) : '';\n", "AC1-copy"),
    ("无条件复用 spokenVars（分享单取脱敏读法）", KIT, COPY_FIELD, "    this.copySpoken = texts.format(OrderKeys.COPY_SPOKEN, spokenVars);\n", "AC1-copy"),
    # AC2
    ("钱包 help() 不设 returnFocusId", WALLET, "    options.returnFocusId = returnId;\n", "", "AC2-help-return"),
    ("提现手续费说明不设 returnFocusId", WITHDRAW, "    options.returnFocusId = ID_HELP_FEE_TAX;\n", "", "AC2-help-return"),
    ("暂停行问号漏 id", WALLET, PAUSED_ID, "", "AC2-help-id"),
    ("手续费问号漏 id", WITHDRAW, "            .id(ID_HELP_FEE_TAX)\n", "", "AC2-help-id"),
    ("AmountGrid 问号漏 id", DS_WALLET, GRID_ID, "", "AC2-grid-id"),
    ("AmountGrid 问号按下标生成 id", DS_WALLET, GRID_ID, "          .id(this.helpIdPrefix.length > 0 ? this.helpIdPrefix + index : '')\n", "AC2-grid-id"),
    ("AmountGrid 问号 id 不带前缀参数", DS_WALLET, GRID_ID, "          .id('amount_help_' + item.helpKey)\n", "AC2-grid-id"),
    ("主卡不透传前缀", DS_WALLET, "          helpIdPrefix: this.helpIdPrefix,\n", "", "AC2-hero-pass"),
    ("钱包主卡不给前缀", WALLET, "      withdrawId: 'wallet_withdraw',\n      helpIdPrefix: HELP_ID_PREFIX,\n",
     "      withdrawId: 'wallet_withdraw',\n", "AC2-help-id"),
    ("预估卡不给前缀", WALLET, "        helpIdPrefix: HELP_ID_PREFIX,\n", "", "AC2-help-id"),
    ("暂停行 returnFocusId 指向不存在的 id", WALLET, PAUSED_CALL,
     "this.help('wallet.help.pending_paused', this.t('wallet.help.title.pending_paused'), 'wallet_help_paused')", "AC2-help-target"),
    ("手续费 returnFocusId 指向提交按钮", WITHDRAW, "    options.returnFocusId = ID_HELP_FEE_TAX;\n", "    options.returnFocusId = ID_SUBMIT;\n",
     "AC2-help-target"),
    ("主卡问号 returnFocusId 不是前缀 + 键", WALLET, HELP_FROZEN, "this.help('wallet.help.frozen', this.t('wallet.frozen'), 'wallet_withdraw');",
     "AC2-help-target"),
    ("主卡问号 returnFocusId 只有前缀", WALLET, HELP_FROZEN, "this.help('wallet.help.frozen', this.t('wallet.frozen'), HELP_ID_PREFIX);",
     "AC2-help-target"),
    ("主卡、预估卡问号同 id", WALLET, HELP_EST, "this.help('wallet.help.estimated', this.t('wallet.estimated'), HELP_ID_PREFIX + 'frozen');",
     "AC2-id-unique"),
    ("暂停行问号与暂停行容器同 id", WALLET, "const ID_HELP_PAUSED: string = 'wallet_help_pending_paused';",
     "const ID_HELP_PAUSED: string = 'wallet_paused_line';", "AC2-id-unique"),
    ("returnFocusId 传空串", WALLET, PAUSED_CALL, "this.help('wallet.help.pending_paused', this.t('wallet.help.title.pending_paused'), '')",
     "AC2-help-return"),
    ("删掉暂停行问号（问号触发点不足）", WALLET, ".onClick(() => " + PAUSED_CALL + ")", ".onClick(() => {})", "AC2-help-missing"),
    # AC3：8 处任一删 backDismisses
    ("提现风控删 backDismisses", WITHDRAW, WD_RISK, _no_back(WD_RISK), "AC3-back"),
    ("提现放弃删 backDismisses", WITHDRAW, WD_ABANDON, _no_back(WD_ABANDON), "AC3-back"),
    ("收款账号风控删 backDismisses", PAYOUT, PO_RISK, _no_back(PO_RISK), "AC3-back"),
    ("收款账号放弃删 backDismisses", PAYOUT, PO_ABANDON, _no_back(PO_ABANDON), "AC3-back"),
    ("登录 44001 删 backDismisses", LOGIN, LG_CODE, _no_back(LG_CODE), "AC3-back"),
    ("第三方 44001 删 backDismisses", LOGIN, LG_OAUTH, _no_back(LG_OAUTH), "AC3-back"),
    ("绑定 44001 删 backDismisses", BIND, BD_RISK, _no_back(BD_RISK), "AC3-back"),
    ("绑定合并确认删 backDismisses", BIND, BD_MERGE, _no_back(BD_MERGE), "AC3-back"),
    ("全仓：MePages 删 backDismisses", ME_PAGES, "  options.backDismisses = true;\n", "", "AC3-back"),
    ("backDismisses 放进 if 分支", WITHDRAW, WD_RISK,
     "    options.dismissOnMask = false;\n    if (this.model.editable) {\n      options.backDismisses = true;\n    }\n    options.returnFocusId = ID_SUBMIT;",
     "AC3-back"),
    ("backDismisses 设 false", PAYOUT, PO_RISK, PO_RISK.replace("backDismisses = true", "backDismisses = false"), "AC3-back"),
    ("dismissOnMask 改成变量（照样要 backDismisses）", LOGIN, LG_CODE,
     "    options.dismissOnMask = this.model.codeText.length < 0;\n    options.returnFocusId = ID_CODE;", "AC3-back"),
    ("提现风控改成点遮罩可关", WITHDRAW, WD_RISK, WD_RISK.replace("dismissOnMask = false", "dismissOnMask = true"), "AC3-mask"),
    ("风控 onDismissed 改成 abandon", WITHDRAW, "    options.onDismissed = () => this.config.controller.dismissRisk();",
     "    options.onDismissed = () => this.config.controller.abandon(0, '');", "AC3-exit"),
    ("收款账号风控 onDismissed 改成 appeal", PAYOUT, "    options.onDismissed = () => this.config.controller.dismissRisk();",
     "    options.onDismissed = () => this.config.controller.appeal();", "AC3-exit"),
    ("风控删 onDismissed（返回不收弹窗状态）", WITHDRAW, "    options.onDismissed = () => this.config.controller.dismissRisk();\n", "", "AC3-exit"),
    ("放弃确认的返回执行放弃", WITHDRAW, """    options.onPrimary = () => {
      this.config.controller.abandon(version, key);
    };
    CouliDialog.open(this.getUIContext(), options);""", """    options.onPrimary = () => {
      this.config.controller.abandon(version, key);
    };
    options.onDismissed = () => {
      this.config.controller.abandon(version, key);
    };
    CouliDialog.open(this.getUIContext(), options);""", "AC3-exit"),
    ("收款账号放弃确认的返回新增动作", PAYOUT, """    options.onPrimary = () => {
      this.config.controller.abandon(version, key);
    };""", """    options.onPrimary = () => {
      this.config.controller.abandon(version, key);
    };
    options.onDismissed = () => this.config.controller.save();""", "AC3-exit"),
    ("合并确认返回改成并入", BIND, "    options.onDismissed = () => this.mergeDecided(MergeDecision.CANCEL);",
     "    options.onDismissed = () => this.mergeDecided(MergeDecision.CONFIRM);", "AC3-exit"),
]

# 良性改写（不得误报）：(名字, [(文件, 原串, 新串), ...])
BENIGN = [
    ("复制名经页面方法格式化（不经 OrderView 字段）", [
        (LIST, "copySpoken: view.copySpoken,", "copySpoken: this.copySpokenOf(view),"),
        (LIST, "  build() {", """  private copySpokenOf(view: OrderView): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('no', view.orderNo);
    return view.copyable ? this.config.texts.format(OrderKeys.COPY_SPOKEN, vars) : '';
  }

  build() {"""),
    ]),
    ("复制名在 if (copyable) 里复用 spokenVars", [
        (KIT, COPY_SET + COPY_FIELD, """    let copy: string = '';
    if (this.copyable) {
      copy = texts.format(OrderKeys.COPY_SPOKEN, spokenVars);
    }
    this.copySpoken = copy;
"""),
    ]),
    ("复制名三元复用 spokenVars（可复制分支读原单号）", [
        (KIT, COPY_FIELD, "    this.copySpoken = this.copyable ? texts.format(OrderKeys.COPY_SPOKEN, spokenVars) : '';\n"),
    ]),
    ("问号 id 用模块 const、经三元选 id", [
        (WALLET, HELP_FROZEN, "this.help('wallet.help.frozen', this.t('wallet.frozen'), i === 0 ? ID_HELP_FROZEN : ID_HELP_WITHDRAWN);"),
        (WALLET, "const ID_HELP_PAUSED: string = 'wallet_help_pending_paused';",
         "const ID_HELP_PAUSED: string = 'wallet_help_pending_paused';\nconst ID_HELP_FROZEN: string = HELP_ID_PREFIX + 'frozen';\n"
         "const ID_HELP_WITHDRAWN: string = HELP_ID_PREFIX + 'withdrawn';"),
    ]),
    ("提现手续费问号 id 写成字面量", [
        (WITHDRAW, "            .id(ID_HELP_FEE_TAX)\n", "            .id('withdraw_help_fee_tax')\n"),
        (WITHDRAW, "    options.returnFocusId = ID_HELP_FEE_TAX;\n", "    options.returnFocusId = 'withdraw_help_fee_tax';\n"),
    ]),
    ("backDismisses 写在 dismissOnMask 之前", [
        (PAYOUT, PO_RISK, "    options.backDismisses = true;\n    options.dismissOnMask = false;\n    options.returnFocusId = ID_SAVE;"),
    ]),
    ("风控 onDismissed 写成块体", [
        (WITHDRAW, "    options.onDismissed = () => this.config.controller.dismissRisk();",
         "    options.onDismissed = () => {\n      this.config.controller.dismissRisk();\n    };"),
    ]),
    ("AmountGrid 问号 id 用模板串", [
        (DS_WALLET, GRID_ID, "          .id(this.helpIdPrefix.length > 0 && item.helpKey.length > 0 ? `${this.helpIdPrefix}${item.helpKey}` : '')\n"),
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


def _frozen_selftest(tmp, failures):
    """AC4：把 me12wc 守卫 + 基线 + 其钉住的真实文件拷进临时树——原样 0 违反；改一个 core wallet 文件必须报 AC4-frozen。"""
    tool_dir = os.path.join(REPO_ROOT, "tools", "ci", "me12wc")
    fixture = os.path.join(tool_dir, "fixtures", "risk-baseline-30201f0.json")
    if not os.path.isfile(fixture):
        failures.append("AC4 自测：本仓库没有 me12wc 基线")
        return
    root = os.path.join(tmp, "frozen")
    shutil.copytree(tool_dir, os.path.join(root, "tools", "ci", "me12wc"))
    with open(fixture, encoding="utf-8") as f:
        base = json.load(f)
    rels = [rel for _, rel in base["strict"]] + [rel for _, rel in base["tree"]] + list(base["append_only"].keys())
    for rel in rels:
        src = os.path.join(REPO_ROOT, rel)
        if os.path.isfile(src):
            os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
            shutil.copy2(src, os.path.join(root, rel))
    got = me12wc_g1(root)
    if got:
        failures.append("AC4 自测：真实文件拷贝树不过（本仓库 me12wc G1 已红？）%s" % [v["msg"] for v in got[:3]])
        return
    target = next((rel for rel in rels if rel.startswith("common/core/src/main/ets/wallet/")), None)
    if target is None:
        failures.append("AC4 自测：基线里没有 core wallet 文件")
        return
    with open(os.path.join(root, target), "a", encoding="utf-8") as f:
        f.write("\n// a11y-common 变异：改冻结件\n")
    got = me12wc_g1(root)
    if not any(v["rule"] == "AC4-frozen" for v in (got or [])):
        failures.append("AC4 自测：改了 %s 却没报 AC4-frozen" % target)
    else:
        print("KILLED 改 me12wc 冻结的 core wallet 文件 ← AC4-frozen")


def self_test():
    failures = []
    with tempfile.TemporaryDirectory(prefix="a11ycommon-selftest-") as tmp:
        good = os.path.join(tmp, "good")
        shutil.copytree(GOOD, good)
        got = check(good, with_frozen=False)
        if got:
            failures.append("参照件不过：%s" % [(v["rule"], v["file"], v["line"], v["msg"]) for v in got])
        for idx, (name, rel, old, new, want) in enumerate(MUTATIONS):
            root = os.path.join(tmp, "m%02d" % idx)
            shutil.copytree(GOOD, root)
            if not _apply(root, rel, old, new, failures, "变异「%s」" % name):
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
            root = os.path.join(tmp, "b%02d" % idx)
            shutil.copytree(GOOD, root)
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
        # 语法错误 / 缺文件 / struct 改名 / OrderView 类改名：一律 4（Incomplete）
        cases = [
            ("语法错误", lambda r: open(os.path.join(r, WALLET), "a", encoding="utf-8").write("\nexport struct {\n")),
            ("缺文件", lambda r: os.remove(os.path.join(r, PAYOUT))),
            ("struct 改名", lambda r: _apply(r, WITHDRAW, "export struct WithdrawView {", "export struct WithdrawPage {", failures, "struct 改名")),
            ("OrderView 改名", lambda r: _apply(r, KIT, "export class OrderView {", "export class OrderCardView {", failures, "OrderView 改名")),
        ]
        for idx, (name, mutate) in enumerate(cases):
            root = os.path.join(tmp, "x%02d" % idx)
            shutil.copytree(GOOD, root)
            mutate(root)
            try:
                check(root, with_frozen=False)
                failures.append("%s应该按 Incomplete 退出，却正常返回" % name)
            except Incomplete:
                print("FAIL-CLOSED %s → 4" % name)
        _frozen_selftest(tmp, failures)
    total = len(MUTATIONS) + len(BENIGN) + 4 + 1 + 1
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("A11YCOMMON_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("A11YCOMMON_SELFTEST 通过：参照件 1 + 变异 %d 全杀 + 良性改写 %d 全绿 + 语法错误 / 缺文件 / 缺 struct / 缺 class fail-closed"
          " + AC4（me12wc G1 真实拷贝树原样 0、改 core wallet 即红）" % (len(MUTATIONS), len(BENIGN)))
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
        print("A11YCOMMON 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("A11YCOMMON 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    if violations:
        print("A11YCOMMON_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("A11YCOMMON_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
