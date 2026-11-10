#!/usr/bin/env python3
"""FU-HM-LOGIN-PHONE-LAYOUT-harmony（D10-1223 / 编排 15:49 / D10-1230 判据 1 / D10-1231 FU-HM-A11Y-01 并入）宿主结构守卫（测试作者 v2：收紧 LP4 焦点 / 说明、钉住待确认禁用、I1 先红 LP7）。

用法：
    python3 tools/ci/loginphone/check_login_phone.py [--root <目录>]    # 检查（默认仓库根）
    python3 tools/ci/loginphone/check_login_phone.py --self-test        # 参照件（fixtures/good）全过 + 每个变异都要被杀 + 良性改写不误报

退出码：0 通过；1 有违反（自测：有变异没被杀、参照件不过或良性改写被误报）；2 参数不对；3 解析工具链不可用（复用 lint.hm10_toolchain，
node + 鸿蒙 SDK ohos-typescript）；4 无法保证判定完整（文件缺失、语法错误、找不到 struct）。解析错误不算「红在断言」，一律 4。

只看两个产品文件：features/auth/src/main/ets/LoginView.ets（短信登录页）、BindPhoneView.ets（绑定手机号页）。判定在 loginphone_ast.cjs（AST，
不用正则切块；注释与字符串里的字不算）。组件的「所在容器」沿尾随闭包向外找，遇到 this.<@Builder>() 调用点继续向外（每个调用点一条路径），
到 Scroll（含）为止。规则：
    LP1 绑定页发码 bind_phone_send 是系统按钮：buttonId 为它的 CouliButton 至少一个；不得有别的组件挂这个 id、不得在 onClick 里调 sendCode；
        「获取验证码 / N 秒后重新获取」（BindPhoneKeys.GET_CODE、countdownText()）不得出现在 CouliButton 以外的组件里，且按钮 text 显示它；
        variant 静态可判且不含 TEXT（文字按钮无底无框，折行后就是光秃红字）；接了 disabled；按钮上不挂 height / 缩字 / 截断属性；
        v2 LP1-pending：disabled 按顶层 || 拆开（经无参单 return 的 this.<方法>() 展开）必须有一项是 model.pending !== null（待确认卡显示时禁用；
        Core 与视图 sendCode 都不判 pending，只靠这一条）
    LP2 发码与重新获取按钮所在容器（到 Scroll 为止）：不是 Row、Flex 必须 wrap: FlexWrap.Wrap（放不下就换行）；容器不定高（百分比除外）、不挂缩字 / 截断
    LP3 手机号框 login_phone（与绑定页 bind_phone_phone、bind_phone_code 钉住不回退）：恰一个；不写 .height；constraintSize minHeight 恰为 52、不带 maxHeight；
        不挂缩字属性；所在容器（到 Scroll 为止）不定高
    LP4 出错（FU-HM-A11Y-01 / 02，D10-1231 共性 ②，主会话 06:24 ③）：phoneError / codeError 每处赋非空错误文字，所在作用域（case 分支，否则整个方法；
        经 this.<方法>() 展开）要有 CouliAnnounce.say，且有 CouliFocusReturn.accessibilityFocus / to；v2：每个移焦调用的 id 按赋值所在路径的 if 条件求值
        （三元条件在该路径上能定真假只取那一支），必须只解析到该输入框 id——不认错误提示 Text（T1），不认另一个框（T2 交叉），判不了也红；
        输入框 accessibilityDescription（链上最后一次）的实参在该错误非空时的取值必须带这句错误（T4，按值求，不只看记号）。绑定页同口径钉住
    LP5 判据 1：login_phone、bind_phone_phone 是单行 TextInput；「验证码已发送至 {phone}」的 Text 不设 wordBreak BREAK_ALL / HYPHENATION、不缩字
    LP6 登录页验证码步 login_resend 是系统按钮：同 LP1（needle = tapResend；倒计时 LoginKeys.CODE_COUNTDOWN 不得是光秃 Text，要进按钮 text）
    LP7（v2，评审 I1 先红）登录页每个 phoneError 出错点（fieldError(true, …) 调用点或直接赋值处）：路径事实（各层 if 条件 + 前面的「回手机号步」语句：
        this.model.step = LoginModel.STEP_PHONE 或经 this.<方法>() 调 pageFlow.backToPhone()）须确定页面在手机号步（LP7-step；验证码步没挂 login_phone，
        移焦落空），且同一路径上不再 this.toast / CouliToast.show / 另一次 CouliAnnounce.say（LP7-dup；读屏读两遍）
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
AST_TOOL = os.path.join(HERE, "loginphone_ast.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")

LOGIN = "features/auth/src/main/ets/LoginView.ets"
BIND = "features/auth/src/main/ets/BindPhoneView.ets"
REQUIRED = (LOGIN, BIND)
RULE_TITLES = {
    "LP1": "绑定页发码是系统按钮（非 TEXT 变体、禁用接线、不裸 Text + onClick）",
    "LP2": "发码 / 重新获取所在容器可换行、不定高、不缩字",
    "LP3": "手机号框高度随字号长（minHeight 52、无固定 height）",
    "LP4": "出错播报 + 焦点移到出错的框 + 错误关联到输入框",
    "LP5": "判据 1：手机号单行 TextInput、脱敏号码不在数字中间断",
    "LP6": "登录验证码步「N 秒后可重新获取 / 重新获取」是系统按钮",
    "LP7": "验证码步遇手机号错误：不重复播报、焦点不落空（评审 I1，v2 先红）",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_loginphone", os.path.join(HERE, "..", "lint.py"))
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


def check(root):
    """返回违反列表；文件缺失 / 语法错误抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
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
        raise Incomplete("loginphone_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("loginphone_ast.cjs 输出无法解析：%s" % e)
    if out["incomplete"]:
        raise Incomplete("；".join(out["incomplete"]))
    return out["violations"]


def render(violations):
    groups = {}
    for v in violations:
        groups.setdefault(v["rule"].split("-")[0], []).append(v)
    for key in sorted(RULE_TITLES):
        state = "红" if key in groups else "绿"
        print("%s %s：%s（%d 处）" % (key, state, RULE_TITLES[key], len(groups.get(key, []))))
    for v in sorted(violations, key=lambda x: (x["rule"], x["file"], x["line"])):
        print("  [%s] %s:%d %s" % (v["rule"], v["file"], v["line"], v["msg"]))


# ---------------------------------------------------------------- 自测：参照件的变异，全部要杀
BIND_SEND_GOOD = """        CouliButton({
          text: this.countdown() > 0 ? this.countdownText() : this.t(BindPhoneKeys.GET_CODE),
          variant: CouliButtonVariant.SECONDARY,
          buttonSize: CouliButtonSize.COMPACT,
          loading: this.model.sending,
          disabled: this.countdown() > 0 || this.sendRateLimited() || this.model.pending !== null,
          buttonId: ID_SEND,
          onTap: () => {
            this.sendCode(b);
          }
        })"""
BIND_SEND_OLD = """        Text(this.countdown() > 0 ? this.countdownText() : this.t(BindPhoneKeys.GET_CODE))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
            this.countdown() > 0 || this.sendRateLimited() ? CouliColors.textSecondary : CouliColors.brandEmphasis,
            CouliFontWeight.medium, true))
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
          .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
          .border({ width: { left: 1 }, color: CouliColors.borderSubtle })
          .textAlign(TextAlign.Center)
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .enabled(this.countdown() <= 0 && !this.sendRateLimited() && !this.model.sending && this.model.pending === null)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .id(ID_SEND)
          .onClick(() => {
            this.sendCode(b);
          })"""
LOGIN_RESEND_GOOD = """        CouliButton({
          text: this.model.countdown > 0 ? this.fmt(LoginKeys.CODE_COUNTDOWN, 'n', String(this.model.countdown))
            : this.t(LoginKeys.CODE_RESEND),
          variant: CouliButtonVariant.SECONDARY,
          buttonSize: CouliButtonSize.COMPACT,
          loading: this.model.sending,
          disabled: this.model.countdown > 0 || this.sendRateLimited() || this.model.submitting,
          buttonId: ID_RESEND,
          onTap: () => {
            this.pageAction(this.pageFlow.tapResend(), ID_RESEND);
          }
        })"""
LOGIN_RESEND_OLD = """        Blank()
        if (this.model.countdown > 0) {
          Text(this.fmt(LoginKeys.CODE_COUNTDOWN, 'n', String(this.model.countdown)))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary, undefined, true))
        } else {
          Text(this.t(LoginKeys.CODE_RESEND))
            .attributeModifier(new CouliTextModifier(CouliTypography.body,
              this.sendRateLimited() ? CouliColors.textSecondary : CouliColors.brandEmphasis, CouliFontWeight.medium))
            .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
            .accessibilityRole(AccessibilityRoleType.BUTTON)
            .enabled(!this.sendRateLimited() && !this.model.sending && !this.model.submitting)
            .focusable(true)
            .focusBox(CouliFocus.box)
            .id('login_resend')
            .onClick(() => this.pageAction(this.pageFlow.tapResend(), 'login_resend'))
        }"""
LOGIN_FLEX = "      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {\n        if (this.entries().help) {"
BIND_FLEX = "      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {\n        TextInput({ text: this.model.codeText"
LOGIN_PHONE_CS = "          .constraintSize({ minHeight: INPUT_HEIGHT })\n          .accessibilityText(this.t(LoginKeys.PHONE_LABEL)"
LOGIN_FOCUS = "    const id: string = phone ? ID_PHONE : ID_CODE;\n    setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, id), A11Y_ERROR_DELAY_MS);\n"
LOGIN_SAY = "    CouliAnnounce.say(ui, text);\n    const id: string = phone ? ID_PHONE : ID_CODE;"

LOGIN_FOCUS_ID = "    const id: string = phone ? ID_PHONE : ID_CODE;"
BIND_FOCUS_ID = "    const id: string = phone ? ID_PHONE : ID_CODE;\n    // 键盘弹起"
BIND_DISABLED = "disabled: this.countdown() > 0 || this.sendRateLimited() || this.model.pending !== null,"
LOGIN_PHONE_DESC = "          .accessibilityDescription(this.model.phoneError)\n"
LOGIN_CODE_DESC = "        .accessibilityDescription(this.model.codeError)\n"
BIND_PHONE_DESC = "          .accessibilityDescription(this.model.phoneError)\n          .id(ID_PHONE)"
LOGIN_FEEDBACK_PHONE = "      if (feedback.field === 'phone' && this.model.step === LoginModel.STEP_PHONE) {\n        this.fieldError(true, this.t(feedback.textKey ?? 'error.20001'));\n      }\n"
LOGIN_FEEDBACK_TOAST = "      if (feedback.field !== 'phone' || this.model.step === LoginModel.STEP_CODE) {\n        this.toast(feedback.textKey, feedback.trace6);\n      }\n"
LOGIN_FIELD_PHONE = "          this.backToPhone();\n          this.fieldError(true, this.t(outcome.textKey ?? 'error.20001'));\n"
LOGIN_ERR_TEXT_IDS = [
    (LOGIN, "        Text(this.model.codeError)\n          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))\n",
     "        Text(this.model.codeError)\n          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))\n          .id('login_code_error')\n"),
    (LOGIN, "        Text(this.model.phoneError)\n          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))\n",
     "        Text(this.model.phoneError)\n          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))\n          .id('login_phone_error')\n"),
]

# （名字，文件，原串，新串，应报的规则前缀）；原串在参照件里必须唯一
MUTATIONS = [
    # LP1 绑定页发码
    ("发码退回 Text + 竖线 + onClick（现树写法）", BIND, BIND_SEND_GOOD, BIND_SEND_OLD, "LP1-button"),
    ("发码 variant 改 TEXT（光秃文字按钮）", BIND, "          variant: CouliButtonVariant.SECONDARY,\n          buttonSize: CouliButtonSize.COMPACT,\n          loading: this.model.sending,\n          disabled: this.countdown()",
     "          variant: CouliButtonVariant.TEXT,\n          buttonSize: CouliButtonSize.COMPACT,\n          loading: this.model.sending,\n          disabled: this.countdown()", "LP1-variant"),
    ("发码只在倒计时时用 TEXT（三元）", BIND, "          variant: CouliButtonVariant.SECONDARY,\n          buttonSize: CouliButtonSize.COMPACT,\n          loading: this.model.sending,\n          disabled: this.countdown()",
     "          variant: this.countdown() > 0 ? CouliButtonVariant.TEXT : CouliButtonVariant.SECONDARY,\n          buttonSize: CouliButtonSize.COMPACT,\n          loading: this.model.sending,\n          disabled: this.countdown()", "LP1-variant"),
    ("发码 variant 无法静态判定", BIND, "          variant: CouliButtonVariant.SECONDARY,\n          buttonSize: CouliButtonSize.COMPACT,\n          loading: this.model.sending,\n          disabled: this.countdown()",
     "          variant: this.sendVariant(),\n          buttonSize: CouliButtonSize.COMPACT,\n          loading: this.model.sending,\n          disabled: this.countdown()", "LP1-variant"),
    ("发码不接 disabled", BIND, "          disabled: this.countdown() > 0 || this.sendRateLimited() || this.model.pending !== null,\n", "", "LP1-disabled"),
    ("发码 disabled 写死 false", BIND, "disabled: this.countdown() > 0 || this.sendRateLimited() || this.model.pending !== null,", "disabled: false,", "LP1-disabled"),
    ("发码 buttonId 不是 bind_phone_send", BIND, "          buttonId: ID_SEND,\n          onTap: () => {\n            this.sendCode(b);", "          buttonId: 'bind_send',\n          onTap: () => {\n            this.sendCode(b);", "LP1-button"),
    ("按钮外另挂一行光秃倒计时 Text", BIND, BIND_SEND_GOOD, BIND_SEND_GOOD + "\n        Text(this.countdownText())", "LP1-label"),
    ("发码按钮定高", BIND, BIND_SEND_GOOD, BIND_SEND_GOOD + "\n        .height(48)", "LP1-shrink"),
    ("系统按钮外面再套一个 onClick 调 sendCode 的 Row", BIND, BIND_SEND_GOOD,
     "        Column() {\n" + BIND_SEND_GOOD + "\n        }\n        .onClick(() => {\n          this.sendCode(b);\n        })", "LP1-bare"),
    # LP2 换行
    ("绑定页发码所在 Flex 去掉 wrap", BIND, BIND_FLEX, BIND_FLEX.replace("wrap: FlexWrap.Wrap, ", ""), "LP2-nowrap"),
    ("绑定页发码所在 Flex 改 NoWrap", BIND, BIND_FLEX, BIND_FLEX.replace("FlexWrap.Wrap", "FlexWrap.NoWrap"), "LP2-nowrap"),
    ("绑定页发码所在 Flex 改 Row", BIND, BIND_FLEX, BIND_FLEX.replace("Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center })", "Row()"), "LP2-row"),
    ("发码抽进 @Builder，调用点包在 Row 里（跨调用点）", BIND, BIND_SEND_GOOD + "\n      }",
     "        Row() {\n          this.sendButton(b)\n        }\n      }", "LP2-row"),
    ("登录倒计时行退回 Row", LOGIN, LOGIN_FLEX, LOGIN_FLEX.replace("Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center })", "Row()"), "LP2-row"),
    ("现树整段：Row + Blank + 光秃倒计时 Text（Row 不换行导致截断）", LOGIN, LOGIN_RESEND_GOOD, LOGIN_RESEND_OLD, "LP2-row"),
    ("登录倒计时行 Flex 不换行", LOGIN, LOGIN_FLEX, LOGIN_FLEX.replace("wrap: FlexWrap.Wrap, ", ""), "LP2-nowrap"),
    ("登录倒计时行定高 48", LOGIN, LOGIN_RESEND_GOOD + "\n      }\n      .width('100%')", LOGIN_RESEND_GOOD + "\n      }\n      .width('100%')\n      .height(48)", "LP2-height"),
    ("登录倒计时行挂 maxLines", LOGIN, LOGIN_RESEND_GOOD + "\n      }\n      .width('100%')", LOGIN_RESEND_GOOD + "\n      }\n      .width('100%')\n      .maxLines(1)", "LP2-shrink"),
    # LP3 手机号框
    ("登录手机号框退回固定 height(INPUT_HEIGHT)（现树写法）", LOGIN, LOGIN_PHONE_CS,
     LOGIN_PHONE_CS.replace(".constraintSize({ minHeight: INPUT_HEIGHT })", ".height(INPUT_HEIGHT)"), "LP3-height"),
    ("登录手机号框 minHeight 与固定 height 并存", LOGIN, LOGIN_PHONE_CS,
     LOGIN_PHONE_CS.replace(".constraintSize({ minHeight: INPUT_HEIGHT })", ".constraintSize({ minHeight: INPUT_HEIGHT })\n          .height(INPUT_HEIGHT)"), "LP3-height"),
    ("登录手机号框 minHeight 写 48", LOGIN, LOGIN_PHONE_CS, LOGIN_PHONE_CS.replace("minHeight: INPUT_HEIGHT", "minHeight: 48"), "LP3-min"),
    ("登录手机号框没有 minHeight", LOGIN, LOGIN_PHONE_CS, LOGIN_PHONE_CS.replace(".constraintSize({ minHeight: INPUT_HEIGHT })\n", ""), "LP3-min"),
    ("登录手机号框 constraintSize 带 maxHeight", LOGIN, LOGIN_PHONE_CS, LOGIN_PHONE_CS.replace("minHeight: INPUT_HEIGHT", "minHeight: INPUT_HEIGHT, maxHeight: 60"), "LP3-max"),
    ("登录手机号框缩字 maxFontScale(1)", LOGIN, LOGIN_PHONE_CS, LOGIN_PHONE_CS.replace(".constraintSize(", ".maxFontScale(1)\n          .constraintSize("), "LP3-shrink"),
    ("登录手机号外框 Row 定高 52", LOGIN, "      .width('100%')\n      .constraintSize({ minHeight: INPUT_HEIGHT })\n      .borderRadius(CouliRadius.button)\n      .border({ width: 1, color: this.model.phoneError",
     "      .width('100%')\n      .height(INPUT_HEIGHT)\n      .borderRadius(CouliRadius.button)\n      .border({ width: 1, color: this.model.phoneError", "LP3-container"),
    ("绑定页手机号框回退固定 height", BIND, "          .constraintSize({ minHeight: INPUT_HEIGHT })\n          .accessibilityText(this.t(BindPhoneKeys.PHONE_LABEL)",
     "          .height(INPUT_HEIGHT)\n          .accessibilityText(this.t(BindPhoneKeys.PHONE_LABEL)", "LP3-height"),
    ("登录手机号框 id 丢了", LOGIN, "          .id(ID_PHONE)\n", "", "LP3-missing"),
    # LP5 判据 1
    ("登录手机号改多行 TextArea", LOGIN, "        TextInput({ text: this.model.phoneText, placeholder: this.t(LoginKeys.PHONE_PLACEHOLDER) })",
     "        TextArea({ text: this.model.phoneText, placeholder: this.t(LoginKeys.PHONE_PLACEHOLDER) })", "LP5-input"),
    ("已发送至的脱敏号码按任意字符断行", LOGIN, "        Text(this.fmt(LoginKeys.CODE_SENT_TO, 'phone', this.model.sentTo))\n",
     "        Text(this.fmt(LoginKeys.CODE_SENT_TO, 'phone', this.model.sentTo))\n          .wordBreak(WordBreak.BREAK_ALL)\n", "LP5-wordbreak"),
    # LP6 登录重新获取
    ("登录倒计时 / 重新获取退回光秃 Text（现树写法）", LOGIN, LOGIN_RESEND_GOOD, LOGIN_RESEND_OLD, "LP6-button"),
    ("倒计时留在按钮外的光秃 Text", LOGIN, LOGIN_RESEND_GOOD,
     "        if (this.model.countdown > 0) {\n          Text(this.fmt(LoginKeys.CODE_COUNTDOWN, 'n', String(this.model.countdown)))\n        }\n"
     + LOGIN_RESEND_GOOD.replace("this.model.countdown > 0 ? this.fmt(LoginKeys.CODE_COUNTDOWN, 'n', String(this.model.countdown))\n            : this.t(LoginKeys.CODE_RESEND)", "this.t(LoginKeys.CODE_RESEND)"), "LP6-label"),
    ("重新获取只显示「重新获取」不显示倒计时", LOGIN, "          text: this.model.countdown > 0 ? this.fmt(LoginKeys.CODE_COUNTDOWN, 'n', String(this.model.countdown))\n            : this.t(LoginKeys.CODE_RESEND),",
     "          text: this.t(LoginKeys.CODE_RESEND),", "LP6-label"),
    ("重新获取 variant TEXT", LOGIN, "          variant: CouliButtonVariant.SECONDARY,\n          buttonSize: CouliButtonSize.COMPACT,\n          loading: this.model.sending,\n          disabled: this.model.countdown",
     "          variant: CouliButtonVariant.TEXT,\n          buttonSize: CouliButtonSize.COMPACT,\n          loading: this.model.sending,\n          disabled: this.model.countdown", "LP6-variant"),
    ("重新获取不接 disabled", LOGIN, "          disabled: this.model.countdown > 0 || this.sendRateLimited() || this.model.submitting,\n", "", "LP6-disabled"),
    ("重新获取经 Text.onClick 调 tapResend", LOGIN, LOGIN_RESEND_GOOD,
     LOGIN_RESEND_GOOD + "\n        Text(this.t(LoginKeys.CODE_RESEND))\n          .onClick(() => this.pageAction(this.pageFlow.tapResend(), ID_RESEND))", "LP6-bare"),
    # LP4 出错播报与焦点
    ("登录 fieldError 不播报", LOGIN, "    CouliAnnounce.say(ui, text);\n    const id: string = phone ? ID_PHONE : ID_CODE;", "    const id: string = phone ? ID_PHONE : ID_CODE;", "LP4-say"),
    ("登录 fieldError 不移焦点", LOGIN, "    setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, id), A11Y_ERROR_DELAY_MS);\n  }\n\n  private toast(", "  }\n\n  private toast(", "LP4-focus"),
    ("登录 fieldError 焦点移到标题", LOGIN, "    const id: string = phone ? ID_PHONE : ID_CODE;", "    const id: string = ID_TITLE;", "LP4-focus"),
    ("登录 fieldError 焦点 id 判不了", LOGIN, "    setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, id), A11Y_ERROR_DELAY_MS);",
     "    setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, this.focusTarget()), A11Y_ERROR_DELAY_MS);", "LP4-focus"),
    ("code_error 分支绕过 fieldError 直接赋值", LOGIN, "        this.fieldError(false, this.t(outcome.textKey ?? 'error.20002'));",
     "        this.model.codeError = this.t(outcome.textKey ?? 'error.20002');", "LP4-say"),
    ("code_expired 分支绕过 fieldError 直接赋值", LOGIN, "        this.fieldError(false, this.t(outcome.textKey ?? 'error.20003'));",
     "        this.model.codeError = this.t(outcome.textKey ?? 'error.20003');", "LP4-say"),
    ("发码 phone 错误绕过 fieldError 直接赋值", LOGIN, "        this.fieldError(true, this.t(feedback.textKey ?? 'error.20001'));",
     "        this.model.phoneError = this.t(feedback.textKey ?? 'error.20001');", "LP4-say"),
    ("登录 field_error phone 绕过 fieldError", LOGIN, "          this.fieldError(true, this.t(outcome.textKey ?? 'error.20001'));",
     "          this.model.phoneError = this.t(outcome.textKey ?? 'error.20001');", "LP4-say"),
    ("登录手机号框不带错误说明", LOGIN, "          .accessibilityDescription(this.model.phoneError)\n", "", "LP4-desc"),
    ("登录验证码框错误说明换成空串", LOGIN, "        .accessibilityDescription(this.model.codeError)\n", "        .accessibilityDescription('')\n", "LP4-desc"),
    ("绑定页 fieldError 不播报（钉住）", BIND, "    CouliAnnounce.say(ui, text);\n    // D10-1231 共性 ②", "    // D10-1231 共性 ②", "LP4-say"),
    ("绑定页验证码框不带错误说明（钉住）", BIND, "          .accessibilityDescription(this.model.codeError)\n", "", "LP4-desc"),
    # v2 T1：焦点只认出错的输入框（主会话 06:24 ③）
    ("登录焦点移到带 id 的错误提示 Text（v1 良性改写，v2 转变异）", LOGIN, LOGIN_FOCUS_ID,
     "    const id: string = phone ? 'login_phone_error' : 'login_code_error';", "LP4-focus"),
    ("绑定页焦点改回错误提示 Text（基线写法）", BIND, BIND_FOCUS_ID, BIND_FOCUS_ID.replace("phone ? ID_PHONE : ID_CODE", "phone ? ID_PHONE_ERROR : ID_CODE_ERROR"), "LP4-focus"),
    ("登录移到输入框后又移到错误提示 Text", LOGIN, "    setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, id), A11Y_ERROR_DELAY_MS);\n  }\n\n  private toast(",
     "    setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, id), A11Y_ERROR_DELAY_MS);\n    setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, 'login_phone_error'), A11Y_ERROR_DELAY_MS);\n  }\n\n  private toast(", "LP4-focus"),
    # v2 T2：焦点交叉
    ("登录焦点交叉（手机号错移到验证码框，反之亦然）", LOGIN, LOGIN_FOCUS_ID, "    const id: string = phone ? ID_CODE : ID_PHONE;", "LP4-focus"),
    ("绑定页焦点交叉", BIND, BIND_FOCUS_ID, BIND_FOCUS_ID.replace("phone ? ID_PHONE : ID_CODE", "phone ? ID_CODE : ID_PHONE"), "LP4-focus"),
    ("登录焦点一律移到验证码框", LOGIN, LOGIN_FOCUS_ID, "    const id: string = ID_CODE;", "LP4-focus"),
    ("登录焦点按与出错字段无关的状态选框（可能交叉）", LOGIN, LOGIN_FOCUS_ID, "    const id: string = this.model.phoneError.length > 0 ? ID_PHONE : ID_CODE;", "LP4-focus"),
    # v2 T3：待确认时发码禁用
    ("绑定发码 disabled 去掉待确认", BIND, BIND_DISABLED, "disabled: this.countdown() > 0 || this.sendRateLimited(),", "LP1-pending"),
    ("绑定发码 待确认只在 && 里（限流且待确认才禁用）", BIND, BIND_DISABLED,
     "disabled: this.countdown() > 0 || (this.sendRateLimited() && this.model.pending !== null),", "LP1-pending"),
    ("绑定发码 待确认判反（=== null）", BIND, BIND_DISABLED, "disabled: this.countdown() > 0 || this.sendRateLimited() || this.model.pending === null,", "LP1-pending"),
    # v2 T4：说明真接到出错状态
    ("登录手机号框说明在出错时反而为空", LOGIN, LOGIN_PHONE_DESC, "          .accessibilityDescription(this.model.phoneError.length > 0 ? '' : this.model.phoneError)\n", "LP4-desc"),
    ("登录手机号框说明接成 codeError", LOGIN, LOGIN_PHONE_DESC, "          .accessibilityDescription(this.model.codeError)\n", "LP4-desc"),
    ("登录验证码框说明随后被覆盖成空串", LOGIN, LOGIN_CODE_DESC, LOGIN_CODE_DESC + "        .accessibilityDescription('')\n", "LP4-desc"),
    ("绑定页手机号框说明只在没错误时取值", BIND, BIND_PHONE_DESC,
     BIND_PHONE_DESC.replace("accessibilityDescription(this.model.phoneError)", "accessibilityDescription(this.model.phoneError.length === 0 ? this.model.phoneError : '')"), "LP4-desc"),
    ("登录手机号框说明受无关条件左右（判不了）", LOGIN, LOGIN_PHONE_DESC, "          .accessibilityDescription(this.model.agreed ? this.model.phoneError : '')\n", "LP4-desc"),
    # v2 LP7（I1 先红）：验证码步遇手机号错误
    ("发码反馈手机号错不判步骤（现产品写法）", LOGIN, LOGIN_FEEDBACK_PHONE, LOGIN_FEEDBACK_PHONE.replace(" && this.model.step === LoginModel.STEP_PHONE", ""), "LP7-step"),
    ("发码反馈：手机号错时 fieldError 之外仍一律 toast", LOGIN, LOGIN_FEEDBACK_TOAST, "      this.toast(feedback.textKey, feedback.trace6);\n", "LP7-dup"),
    ("登录 field_error 手机号不回手机号步", LOGIN, LOGIN_FIELD_PHONE, "          this.fieldError(true, this.t(outcome.textKey ?? 'error.20001'));\n", "LP7-step"),
    ("登录 field_error 先 fieldError 后回手机号步", LOGIN, LOGIN_FIELD_PHONE,
     "          this.fieldError(true, this.t(outcome.textKey ?? 'error.20001'));\n          this.backToPhone();\n", "LP7-step"),
]

SEND_BUILDER = """
  @Builder
  sendButton(b: BindPhoneFormBinding) {
""" + BIND_SEND_GOOD.replace("\n        ", "\n    ").replace("        CouliButton", "    CouliButton", 1) + """
  }

  /** 输入框获焦"""
# 「抽进 @Builder」变异要同时加方法：第二处编辑
EXTRA_EDITS = {
    "现树整段：Row + Blank + 光秃倒计时 Text（Row 不换行导致截断）": [
        (LOGIN, LOGIN_FLEX, LOGIN_FLEX.replace("Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center })", "Row()"))],
    "发码抽进 @Builder，调用点包在 Row 里（跨调用点）": [(BIND, "\n\n  /** 输入框获焦", SEND_BUILDER)],
    # v1 的良性改写「焦点移到带 id 的错误提示 Text」在 v2 是变异（主会话 06:24 ③ 只认输入框）：错误提示 Text 真带上这两个 id，证明不是 id 不存在才红
    "登录焦点移到带 id 的错误提示 Text（v1 良性改写，v2 转变异）": LOGIN_ERR_TEXT_IDS,
    "登录移到输入框后又移到错误提示 Text": LOGIN_ERR_TEXT_IDS[1:],
}

# 良性改写（重构但口径不变），必须仍然全绿——防判据收紧过头。（名字，[(文件，原串，新串)…]）
BENIGN = [
    ("焦点改用 CouliFocusReturn.to（键盘焦点 + 读屏焦点）", [
        (LOGIN, "setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, id), A11Y_ERROR_DELAY_MS);",
         "setTimeout(() => CouliFocusReturn.to(ui, id), A11Y_ERROR_DELAY_MS);"),
    ]),
    ("发码用主按钮（省略 variant = PRIMARY）、放进框下方 Column", [
        (BIND, BIND_SEND_GOOD, "        Column() {\n" + BIND_SEND_GOOD + "\n        }\n        .width('100%')"),
        (BIND, "          variant: CouliButtonVariant.SECONDARY,\n          buttonSize: CouliButtonSize.COMPACT,\n          loading: this.model.sending,\n          disabled: this.countdown()",
         "          buttonSize: CouliButtonSize.COMPACT,\n          loading: this.model.sending,\n          disabled: this.countdown()"),
    ]),
    ("重新获取抽进 @Builder（调用点在可换行 Flex 里）", [
        (LOGIN, LOGIN_RESEND_GOOD, "        this.resendButton()"),
        (LOGIN, "\n  build() {\n    Column() {\n      this.topBar()",
         "\n  @Builder\n  resendButton() {\n" + LOGIN_RESEND_GOOD.replace("\n        ", "\n    ").replace("        CouliButton", "    CouliButton", 1)
         + "\n  }\n\n  build() {\n    Column() {\n      this.topBar()"),
    ]),
    ("焦点三元写成取反条件（!phone ? ID_CODE : ID_PHONE）", [
        (LOGIN, LOGIN_FOCUS_ID, "    const id: string = !phone ? ID_CODE : ID_PHONE;"),
        (BIND, BIND_FOCUS_ID, BIND_FOCUS_ID.replace("phone ? ID_PHONE : ID_CODE", "!phone ? ID_CODE : ID_PHONE")),
    ]),
    ("说明写成「有错误才带错误」的三元 / 前缀拼接 / 无参取值方法", [
        (LOGIN, LOGIN_PHONE_DESC, "          .accessibilityDescription(this.model.phoneError.length > 0 ? this.model.phoneError : '')\n"),
        (LOGIN, LOGIN_CODE_DESC, "        .accessibilityDescription(this.t(LoginKeys.PHONE_LABEL) + ' ' + this.model.codeError)\n"),
        (BIND, BIND_PHONE_DESC, BIND_PHONE_DESC.replace("accessibilityDescription(this.model.phoneError)", "accessibilityDescription(this.phoneDesc())")),
        (BIND, "\n\n  /** 输入框获焦", "\n\n  private phoneDesc(): string {\n    return this.model.phoneError;\n  }\n\n  /** 输入框获焦"),
    ]),
    ("待确认禁用经无参方法、null 写在左边", [
        (BIND, BIND_DISABLED, "disabled: this.sendBlocked(),"),
        (BIND, "\n\n  /** 输入框获焦", "\n\n  private sendBlocked(): boolean {\n    return this.countdown() > 0 || this.sendRateLimited() || null !== this.model.pending;\n  }\n\n  /** 输入框获焦"),
    ]),
    ("I1 改法二：手机号错先回手机号步再 fieldError", [
        (LOGIN, LOGIN_FEEDBACK_PHONE, "      if (feedback.field === 'phone') {\n        this.backToPhone();\n        this.fieldError(true, this.t(feedback.textKey ?? 'error.20001'));\n      }\n"),
    ]),
    ("I1 改法一的嵌套写法：手机号错按步骤二选一", [
        (LOGIN, LOGIN_FEEDBACK_PHONE + LOGIN_FEEDBACK_TOAST,
         "      if (feedback.field === 'phone') {\n        if (this.model.step === LoginModel.STEP_CODE) {\n          this.toast(feedback.textKey, feedback.trace6);\n"
         "        } else {\n          this.fieldError(true, this.t(feedback.textKey ?? 'error.20001'));\n        }\n      } else {\n"
         "        this.toast(feedback.textKey, feedback.trace6);\n      }\n"),
    ]),
    ("倒计时文字经 this.resendLabel() 取", [
        (LOGIN, "          text: this.model.countdown > 0 ? this.fmt(LoginKeys.CODE_COUNTDOWN, 'n', String(this.model.countdown))\n            : this.t(LoginKeys.CODE_RESEND),",
         "          text: this.resendLabel(),"),
        (LOGIN, "\n  private toast(key: string | null, trace6: string): void {",
         "\n  private resendLabel(): string {\n    return this.model.countdown > 0 ? this.fmt(LoginKeys.CODE_COUNTDOWN, 'n', String(this.model.countdown))\n"
         "      : this.t(LoginKeys.CODE_RESEND);\n  }\n\n  private toast(key: string | null, trace6: string): void {"),
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


def self_test():
    failures = []
    with tempfile.TemporaryDirectory(prefix="loginphone-selftest-") as tmp:
        good = os.path.join(tmp, "good")
        shutil.copytree(GOOD, good)
        got = check(good)
        if got:
            failures.append("参照件不过：%s" % [(v["rule"], v["file"], v["line"], v["msg"]) for v in got])
        for idx, (name, rel, old, new, want) in enumerate(MUTATIONS):
            root = os.path.join(tmp, "m%02d" % idx)
            shutil.copytree(GOOD, root)
            if not _apply(root, rel, old, new, failures, "变异「%s」" % name):
                continue
            ok = True
            for (rel2, old2, new2) in EXTRA_EDITS.get(name, []):
                ok = _apply(root, rel2, old2, new2, failures, "变异「%s」附加编辑" % name) and ok
            if not ok:
                continue
            try:
                rules = {v["rule"] for v in check(root)}
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
            for rel, old, new in edits:
                _apply(root, rel, old, new, failures, "良性改写「%s」" % name)
            try:
                got = check(root)
            except Incomplete as e:
                failures.append("良性改写「%s」解析不完整：%s" % (name, e))
                continue
            if got:
                failures.append("良性改写「%s」被误报：%s" % (name, [(v["rule"], v["msg"]) for v in got]))
            shutil.rmtree(root)
        # 语法错误必须 4（Incomplete），不算断言红
        root = os.path.join(tmp, "msyntax")
        shutil.copytree(GOOD, root)
        with open(os.path.join(root, LOGIN), "a", encoding="utf-8") as f:
            f.write("\nexport struct {\n")
        try:
            check(root)
            failures.append("语法错误应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
        # 必查文件缺失也必须 4
        root = os.path.join(tmp, "mmissing")
        shutil.copytree(GOOD, root)
        os.remove(os.path.join(root, BIND))
        try:
            check(root)
            failures.append("缺文件应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
        # struct 改名也必须 4
        root = os.path.join(tmp, "mstruct")
        shutil.copytree(GOOD, root)
        _apply(root, LOGIN, "export struct LoginView {", "export struct LoginPage {", failures, "struct 改名")
        try:
            check(root)
            failures.append("找不到 struct 应该按 Incomplete 退出，却正常返回")
        except Incomplete:
            pass
    total = len(MUTATIONS) + len(BENIGN) + 3
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("LOGINPHONE_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("LOGINPHONE_SELFTEST 通过：参照件 1 + 变异 %d 全杀 + 良性改写 %d 全绿 + 语法错误 / 缺文件 / 缺 struct fail-closed" % (len(MUTATIONS), len(BENIGN)))
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
        print("LOGINPHONE 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("LOGINPHONE 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    if violations:
        print("LOGINPHONE_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("LOGINPHONE_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
