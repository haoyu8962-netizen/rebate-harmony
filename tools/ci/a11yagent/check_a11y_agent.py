#!/usr/bin/env python3
"""FU-HM-A11Y-AGENT-harmony（测试作者 v1，新鲜独立 Claude，先红）：AI 助手读屏（标签、弹层焦点、标题、行操作标识、装饰字符）与商品卡组件读屏激活的宿主守卫。

依据：NATIVE/FU-HM-A11Y/brief-AGENT.md §2、§3「结构」AG1–AG6；README 末节「编排裁定 D10-1248」（⑦ S3-1 读看得见的权益、S3-2 并入本单；
⑬ 新键与行标识写法）；QA-12b/harmony-audit.md FU-HM-A11Y-10 / 12 / 14 / 17 / 18 / 20；NATIVE/HM-L2-PRODUCT-CELL/review-harmony-r1.md S3-2。
照 tools/ci/l2cell/check_l2_cell.py、tools/ci/loginphone/check_login_phone.py：.ets 一律经 a11yagent_ast.cjs 用 SDK ohos-typescript 解析（AST）。

  AG1 商品卡（ProductCard.ets）：LIST / AI / GRID 在 openable=true 时信息组 = 按钮角色 + 自身 onClick 恰调一次 onOpen（读屏双击信息组即打开）；
      openable=false 时信息组与基线一致（不挂点击 / 手势 / 按压 / 角色 / focusable，组内也不挂）
  AG2 AI 卡（AgentCards.ets AgentProductItem）：ProductCard 传 openable: true、onOpen → port.tap(detail)、onBuy → port.buy；外层不再挂裸 .onClick
  AG3 标签：输入框 agent_input、举报补充说明 agent_report_supplement 的 accessibilityText 是 this.t(固定键)，不随配额三元切换，键有非空文字、不等于占位
  AG4 弹层：页面 / 同意 / 举报三处标题 TITLE_BAR + id；同意 / 举报标题 focusable 且 onAppear 移焦到自身；同意弹窗 onDidDisappear 回焦
      {agent_input, agent_title}，且系统返回 / 点遮罩关闭时回焦标记不在 onDidDisappear 前被 close() 关掉（v2 AG4-return-early，Codex r1 S2）；举报半屏 onDisappear 回焦到运行时记下的触发 id；读屏入口 id 每条唯一；两个触发处打开时记下自己的 id；
      长按气泡、「已举报」标签有带回复键的 id 且可聚焦
  AG5 行标识：AgentFeedbackBar @Param replyTag；赞 / 踩（含已赞 / 已踩）、读屏举报入口读屏名带 PriceTerms.comma + this.replyTag；
      调用处传 AgentReplyTag.of(this.turn.blocks)
  AG6 features/agent 下只含圆点的 Text 对读屏隐藏（accessibilityLevel 'no'），或所在行成组且读屏名不含圆点

用法：
  python3 tools/ci/a11yagent/check_a11y_agent.py [--root <目录>]    检查（默认仓库根）
  python3 tools/ci/a11yagent/check_a11y_agent.py --self-test        参照件 0 违反 + 每个错误实现被打红 + 良性改写不误报（REFERENCE_ONLY，不算产品通过）
退出码：0 通过；1 有违反（自测：有变异没被杀、参照件不过或良性改写被误报）；2 参数不对；3 解析工具链不可用；4 无法保证判定完整（语法错误、必需文件缺失、找不到 struct）。
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
AST_TOOL = os.path.join(HERE, "a11yagent_ast.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")

PC = "common/designsystem/src/main/ets/components/ProductCard.ets"
AC = "features/agent/src/main/ets/AgentCards.ets"
TR = "features/agent/src/main/ets/AgentTabRoot.ets"
CD = "features/agent/src/main/ets/AgentConsentDialog.ets"
DT = "common/core/src/main/ets/agent/AgentDraftTexts.ets"
REQUIRED = (PC, AC, TR, CD, DT)
AGENT_DIR = "features/agent/src/main/ets"
SKIP_DIRS = {"build", "oh_modules", "node_modules", ".hvigor", ".test", ".preview"}
RULE_TITLES = {
    "AG1": "商品卡 openable：信息组是按钮、读屏激活即 onOpen；不可点时与基线一致",
    "AG2": "AI 卡切 openable（onOpen = port.tap(detail)），外层不再挂裸点击",
    "AG3": "输入框 / 举报补充说明有固定读屏名（不随配额切换、不是占位）",
    "AG4": "标题是 TITLE_BAR；同意 / 举报弹层打开移焦到标题、关闭回焦；行 id 唯一",
    "AG5": "赞 / 踩 / 举报入口读屏名带本条回复的行标识",
    "AG6": "装饰圆点对读屏隐藏",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_a11yagent", os.path.join(HERE, "..", "lint.py"))
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


def agent_files(root):
    base = os.path.join(root, AGENT_DIR)
    out = []
    if not os.path.isdir(base):
        raise Incomplete("%s: 目录不存在，无法判定" % AGENT_DIR)
    for cur, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if name.endswith(".ets"):
                out.append(os.path.relpath(os.path.join(cur, name), root).replace(os.sep, "/"))
    return out


def check(root):
    """返回违反列表；语法错误 / 必需文件缺失抛 Incomplete；工具链不可用抛 lint.HM10ToolchainError。"""
    tool = lint.hm10_toolchain()
    scan = agent_files(root)
    files = {}
    for rel in list(REQUIRED) + scan:
        text = read(root, rel)
        if text is None:
            raise Incomplete("%s: 文件不存在，无法判定" % rel)
        files[rel] = text
    payload = json.dumps({"files": files, "scan": scan}, ensure_ascii=False).encode("utf-8")
    try:
        proc = subprocess.run([tool["node"], AST_TOOL, tool["typescript"]], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise lint.HM10ToolchainError("运行 node 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("a11yagent_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("a11yagent_ast.cjs 输出无法解析：%s" % e)
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


# ---------------------------------------------------------------- 自测：参照件（fixtures/good）+ 错误实现，全部要杀

LIST_OPEN = ("          this.listInfo()\n        }\n        .alignItems(HorizontalAlign.Start)\n        .width('100%')\n"
             "        .accessibilityGroup(true)\n        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n"
             "        .accessibilityRole(AccessibilityRoleType.BUTTON)\n        .onClick(() => {\n          this.onOpen();\n        })\n")
LIST_STATIC = ("      } else {\n        Column({ space: CouliSpacing.space2 }) {\n          this.listInfo()\n        }\n"
               "        .alignItems(HorizontalAlign.Start)\n        .width('100%')\n        .accessibilityGroup(true)\n"
               "        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n      }\n")
GRID_OPEN = LIST_OPEN.replace("this.listInfo()", "this.gridInfoBody()")
GRID_STATIC = LIST_STATIC.replace("this.listInfo()", "this.gridInfoBody()")
ITEM_OPEN = ("          openable: true,\n          onOpen: () => {\n            const detail = this.item?.detail;\n"
             "            if (detail !== null && detail !== undefined) {\n              this.port?.tap(detail);\n            }\n          },\n")
INPUT = ("          .id(ID_INPUT)\n          .accessibilityText(this.t('agent.draft.input_label'))\n")
AREA = ("            .id(ID_REPORT_SUPPLEMENT)\n            .accessibilityText(this.t('agent.draft.report.supplement'))")
HEADER = ("          .accessibilityLevel('yes')\n          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)\n          .id(ID_TITLE)\n")
CONSENT_TITLE = ("        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)\n        .id(ID_CONSENT_TITLE)\n        .focusable(true)\n"
                 "        .focusBox(CouliFocus.box)\n        .onAppear(() => {\n          CouliFocusReturn.to(this.getUIContext(), ID_CONSENT_TITLE);\n"
                 "        })\n")
REPORT_TITLE = ("            .accessibilityRole(AccessibilityRoleType.TITLE_BAR)\n            .id(ID_REPORT_TITLE)\n            .focusable(true)\n"
                "            .focusBox(CouliFocus.box)\n            .onAppear(() => {\n"
                "              CouliFocusReturn.to(this.getUIContext(), ID_REPORT_TITLE);\n            })\n")
CONSENT_BACK = "        if (!this.pageClosing) {\n          CouliFocusReturn.to(this.ui, returnFocusId());\n        }\n"
CONSENT_PICK = "    return usable ? ID_INPUT : ID_TITLE;\n"
REPORT_BACK = "        CouliFocusReturn.to(this.getUIContext(), this.reportReturnId());\n"
# v2（Codex r1 S2）：系统返回 / 点遮罩提交前把本实例从承载方摘下
DISMISS_RELEASE = "          if (inst !== null) {\n            this.slot.release(inst);\n          }\n          port.consentDismissed(ticket);\n"
CLOSE_FLAG = "  close(): void {\n    this.pageClosing = true;\n"
ENTRY_ID = "        .id(AgentReportIds.entry(this.replyKey()))\n"
ENTRY_REMEMBER = "            AgentReportFocus.remember(AgentReportIds.entry(this.replyKey()), this.replyKey(), true);\n"
LONG_REMEMBER = "            AgentReportFocus.remember(AgentReportIds.bubble(this.replyKey()), this.replyKey(), false);\n"
BUBBLE = "        .id(AgentReportIds.bubble(this.replyKey()))\n        .focusable(true)\n"
REPORTED = "          .id(AgentReportIds.reported(this.replyKey()))\n          .focusable(true)\n"
THUMB = ("    .accessibilityText(this.tagged(this.feedback !== undefined && this.feedback.selected === value ? selectedLabel : label))\n")
ENTRY_NAME = "        .accessibilityText(this.tagged(this.t('agent.draft.report.more_entry')))\n"
CALLER = "                disabled: this.actionLimited, replyTag: AgentReplyTag.of(this.turn.blocks)\n"
BULLET_AC = "            Text('•')\n              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))\n              .accessibilityLevel('no')\n"
BULLET_CD = "      Text('•')\n        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))\n        .accessibilityLevel('no')\n"
CONSENT_LINE = ("      Text(this.t(key))\n        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))\n"
                "        .layoutWeight(1)\n    }\n    .width('100%')\n    .alignItems(VerticalAlign.Top)\n")

# （名字，文件，原串，新串，应报的规则前缀）；原串在参照件里必须唯一
MUTATIONS = [
    # AG1
    ("列表卡 openable 时信息组没有按钮角色（S3-2 现状）", PC, LIST_OPEN, LIST_OPEN.replace("        .accessibilityRole(AccessibilityRoleType.BUTTON)\n", ""), "AG1-role"),
    ("列表卡 openable 时信息组角色写成 TEXT", PC, LIST_OPEN, LIST_OPEN.replace("AccessibilityRoleType.BUTTON", "AccessibilityRoleType.TEXT"), "AG1-role"),
    ("列表卡信息组不接点击（读屏双击到不了 onOpen）", PC, LIST_OPEN, LIST_OPEN.replace("        .onClick(() => {\n          this.onOpen();\n        })\n", ""), "AG1-open"),
    ("列表卡信息组点击调 onBuy", PC, LIST_OPEN, LIST_OPEN.replace("this.onOpen();", "this.onBuy();"), "AG1-open"),
    ("列表卡信息组点击调两次 onOpen", PC, LIST_OPEN, LIST_OPEN.replace("this.onOpen();", "this.onOpen();\n          this.onOpen();"), "AG1-open"),
    ("网格卡 openable 时信息组没有按钮角色", PC, GRID_OPEN, GRID_OPEN.replace("        .accessibilityRole(AccessibilityRoleType.BUTTON)\n", ""), "AG1-role"),
    ("网格卡信息组不接点击", PC, GRID_OPEN, GRID_OPEN.replace("        .onClick(() => {\n          this.onOpen();\n        })\n", ""), "AG1-open"),
    ("openable=false 的列表信息组也接点击（吞页面外层 .onClick）", PC, LIST_STATIC,
     LIST_STATIC.replace("        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n      }\n",
                         "        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n        .onClick(() => {\n          this.onOpen();\n        })\n      }\n"),
     "AG1-static"),
    ("openable=false 的网格信息组标成按钮", PC, GRID_STATIC,
     GRID_STATIC.replace("        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n      }\n",
                         "        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n        .accessibilityRole(AccessibilityRoleType.BUTTON)\n      }\n"),
     "AG1-static"),
    ("列表 openable 分支丢了 cellLabel 读屏名", PC, LIST_OPEN,
     LIST_OPEN.replace("        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n", "        .accessibilityText(this.data.title)\n"), "AG1-group"),
    ("去掉 openable 分支判定（两支都是可点版）", PC, "      if (this.openable) {\n        Column({ space: CouliSpacing.space2 }) {\n          this.listInfo()",
     "      if (true) {\n        Column({ space: CouliSpacing.space2 }) {\n          this.listInfo()", "AG1-static"),
    # AG2
    ("AI 卡不传 openable（现状）", AC, ITEM_OPEN, ITEM_OPEN.replace("          openable: true,\n", ""), "AG2-openable"),
    ("AI 卡 openable: false", AC, ITEM_OPEN, ITEM_OPEN.replace("openable: true", "openable: false"), "AG2-openable"),
    ("AI 卡 onOpen 不打开详情", AC, ITEM_OPEN, ITEM_OPEN.replace("              this.port?.tap(detail);\n", ""), "AG2-onopen"),
    ("AI 卡 onOpen 改成购买", AC, ITEM_OPEN,
     ITEM_OPEN.replace("            const detail = this.item?.detail;\n            if (detail !== null && detail !== undefined) {\n              this.port?.tap(detail);\n            }\n",
                       "            const buy = this.item?.buy;\n            if (buy !== null && buy !== undefined) {\n              this.port?.buy(buy);\n            }\n"),
     "AG2-onopen"),
    ("AI 卡外层仍挂裸 .onClick", AC, "        })\n      }\n      .width('100%')\n      Flex({ wrap: FlexWrap.Wrap",
     "        })\n      }\n      .width('100%')\n      .onClick(() => {\n        const detail = this.item?.detail;\n        if (detail !== null && detail !== undefined) {\n"
     "          this.port?.tap(detail);\n        }\n      })\n      Flex({ wrap: FlexWrap.Wrap", "AG2-outer"),
    ("AI 卡 onBuy 不再购买", AC, "              this.port?.buy(buy);\n            }\n          }\n        })\n      }\n      .width('100%')\n",
     "            }\n          }\n        })\n      }\n      .width('100%')\n", "AG2-buy"),
    # AG3
    ("输入框没有 id", TR, INPUT, INPUT.replace("          .id(ID_INPUT)\n", ""), "AG3-id"),
    ("输入框没有读屏名（现状）", TR, INPUT, INPUT.replace("          .accessibilityText(this.t('agent.draft.input_label'))\n", ""), "AG3-label"),
    ("输入框读屏名随配额三元切换", TR, INPUT,
     INPUT.replace("this.t('agent.draft.input_label')", "quota ? this.t('agent.draft.quota.input_disabled') : this.t('agent.draft.input_label')"), "AG3-label"),
    ("输入框读屏名直接用占位", TR, INPUT, INPUT.replace("agent.draft.input_label", "agent.draft.input_placeholder"), "AG3-label"),
    ("草稿表没加输入框标签键", DT, "    m.set('agent.draft.input_label', '给 AI 助手发消息');\n", "", "AG3-key"),
    ("草稿表输入框标签为空串", DT, "    m.set('agent.draft.input_label', '给 AI 助手发消息');\n", "    m.set('agent.draft.input_label', '');\n", "AG3-key"),
    ("补充说明没有读屏名（现状）", TR, AREA, "            .id(ID_REPORT_SUPPLEMENT)", "AG3-label"),
    ("补充说明没有 id", TR, AREA, "            .accessibilityText(this.t('agent.draft.report.supplement'))", "AG3-id"),
    # AG4 标题
    ("页面标题没有 TITLE_BAR（现状）", TR, HEADER, HEADER.replace("          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)\n", ""), "AG4-title"),
    ("页面标题没有 id", TR, HEADER, HEADER.replace("          .id(ID_TITLE)\n", ""), "AG4-title"),
    ("同意标题没有 TITLE_BAR", CD, CONSENT_TITLE, CONSENT_TITLE.replace("        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)\n", ""), "AG4-title"),
    ("同意标题打开不移焦（现状）", CD, CONSENT_TITLE,
     CONSENT_TITLE.replace("        .onAppear(() => {\n          CouliFocusReturn.to(this.getUIContext(), ID_CONSENT_TITLE);\n        })\n", ""), "AG4-title"),
    ("同意标题不可聚焦", CD, CONSENT_TITLE, CONSENT_TITLE.replace("        .focusable(true)\n", ""), "AG4-title"),
    ("举报标题打开时移焦到别处", TR, REPORT_TITLE, REPORT_TITLE.replace("CouliFocusReturn.to(this.getUIContext(), ID_REPORT_TITLE);",
                                                                     "CouliFocusReturn.to(this.getUIContext(), ID_REPORT_SUPPLEMENT);"), "AG4-title"),
    ("举报标题没有 id（现状）", TR, REPORT_TITLE, REPORT_TITLE.replace("            .id(ID_REPORT_TITLE)\n", ""), "AG4-title"),
    # AG4 回焦
    ("同意弹窗关闭不回焦（现状）", CD, CONSENT_BACK, "", "AG4-return"),
    ("同意弹窗只回输入框（输入框不在时落空）", TR, CONSENT_PICK, "    return ID_INPUT;\n", "AG4-return"),
    ("系统返回提交前不摘实例（v1 原状，Codex r1 S2：同步收起关掉回焦）", CD, DISMISS_RELEASE, "          port.consentDismissed(ticket);\n", "AG4-return-early"),
    ("系统返回在提交之后才摘实例（顺序错）", CD, DISMISS_RELEASE,
     "          port.consentDismissed(ticket);\n          if (inst !== null) {\n            this.slot.release(inst);\n          }\n", "AG4-return-early"),
    ("同意弹窗回到发送按钮", TR, CONSENT_PICK, "    return usable ? 'agent-send' : ID_TITLE;\n", "AG4-return"),
    ("举报半屏关闭不回焦（现状）", TR, REPORT_BACK, "", "AG4-return"),
    ("举报半屏关闭回到固定的页面标题", TR, REPORT_BACK, "        CouliFocusReturn.to(this.getUIContext(), ID_TITLE);\n", "AG4-return"),
    ("读屏入口 id 每条相同（现状）", AC, ENTRY_ID, "        .id('agent_report_a11y_entry')\n", "AG4-unique"),
    ("读屏入口打开举报不记触发 id", AC, ENTRY_REMEMBER, "", "AG4-record"),
    ("长按打开举报不记触发 id", AC, LONG_REMEMBER, "", "AG4-record"),
    ("长按记成读屏入口的 id", AC, LONG_REMEMBER, LONG_REMEMBER.replace("AgentReportIds.bubble(", "AgentReportIds.entry("), "AG4-record"),
    ("回复气泡没有 id", AC, BUBBLE, "        .focusable(true)\n", "AG4-trigger"),
    ("回复气泡不可聚焦", AC, BUBBLE, "        .id(AgentReportIds.bubble(this.replyKey()))\n", "AG4-trigger"),
    ("「已举报」没有 id", AC, REPORTED, "          .focusable(true)\n", "AG4-reported"),
    ("「已举报」id 固定", AC, REPORTED, REPORTED.replace("AgentReportIds.reported(this.replyKey())", "'agent_report_reported'"), "AG4-reported"),
    # AG5
    ("没有 @Param replyTag", AC, "  @Param replyTag: string = '';\n", "  replyTag: string = '';\n", "AG5-param"),
    ("赞 / 踩读屏名不带行标识（现状）", AC, THUMB,
     "    .accessibilityText(this.feedback !== undefined && this.feedback.selected === value ? selectedLabel : label)\n", "AG5-name"),
    ("已赞 / 已踩那一支不带行标识", AC, THUMB,
     "    .accessibilityText(this.feedback !== undefined && this.feedback.selected === value ? selectedLabel : this.tagged(label))\n", "AG5-name"),
    ("读屏举报入口不带行标识（现状）", AC, ENTRY_NAME, "        .accessibilityText(this.t('agent.draft.report.more_entry'))\n", "AG5-name"),
    ("行标识直接拼、不用 PriceTerms.comma", AC, "    return this.replyTag.length > 0 ? name + PriceTerms.comma + this.replyTag : name;",
     "    return this.replyTag.length > 0 ? name + this.replyTag : name;", "AG5-name"),
    ("调用处不传 replyTag", AC, CALLER, "                disabled: this.actionLimited\n", "AG5-caller"),
    ("调用处传固定串", AC, CALLER, CALLER.replace("AgentReplyTag.of(this.turn.blocks)", "'回复'"), "AG5-caller"),
    # AG6
    ("消息列表圆点被读出（现状）", AC, BULLET_AC, BULLET_AC.replace("              .accessibilityLevel('no')\n", ""), "AG6-bullet"),
    ("同意弹窗圆点 level 写成 yes", CD, BULLET_CD, BULLET_CD.replace("'no'", "'yes'"), "AG6-bullet"),
]
# 良性改写（实现可能的合理写法），必须仍然全绿——防判据收紧过头。（名字，[(文件，原串，新串)…]）
BENIGN = [
    ("系统返回经同类方法摘实例（v2）", [
        (CD, DISMISS_RELEASE, "          this.detach(inst);\n          port.consentDismissed(ticket);\n"),
        (CD, CLOSE_FLAG, "  private detach(i: CouliModalInstance | null): void {\n    if (i !== null) {\n      this.slot.release(i);\n    }\n  }\n\n"
                         + CLOSE_FLAG)]),
    ("close() 按用户关闭记号跳过关回焦（v2）", [
        (CD, DISMISS_RELEASE, "          this.dismissing = true;\n          port.consentDismissed(ticket);\n"),
        (CD, "  private pageClosing: boolean = false;\n", "  private pageClosing: boolean = false;\n  private dismissing: boolean = false;\n"),
        (CD, CLOSE_FLAG, "  close(): void {\n    if (!this.dismissing) {\n      this.pageClosing = true;\n    }\n")]),
    ("系统返回的提交挪到 onDidDisappear（v2）", [
        (CD, DISMISS_RELEASE, "          userDismissed = true;\n"),
        (CD, "    let inst: CouliModalInstance | null = null;\n", "    let inst: CouliModalInstance | null = null;\n    let userDismissed: boolean = false;\n"),
        (CD, "          this.slot.release(inst);\n        }\n        if (!this.pageClosing) {",
         "          this.slot.release(inst);\n        }\n        if (userDismissed) {\n          port.consentDismissed(ticket);\n        }\n        if (!this.pageClosing) {")]),
    ("同意标题打开时只移读屏焦点（accessibilityFocus）", [
        (CD, "          CouliFocusReturn.to(this.getUIContext(), ID_CONSENT_TITLE);\n",
         "          CouliFocusReturn.accessibilityFocus(this.getUIContext(), ID_CONSENT_TITLE);\n")]),
    ("输入框 id 写字面量", [(TR, "          .id(ID_INPUT)\n", "          .id('agent_input')\n")]),
    ("同意弹窗回焦 id 写成 if / return", [
        (TR, "    return usable ? ID_INPUT : ID_TITLE;\n", "    if (!usable) {\n      return ID_TITLE;\n    }\n    return ID_INPUT;\n")]),
    ("同意弹窗回焦改由宿主按「输入框可用」三元选 id", [
        (TR, "(): string => this.consentReturnId());", "(): boolean => this.consentReturnId() === ID_INPUT);"),
        (CD, "returnFocusId: () => string): void {", "inputUsable: () => boolean): void {"),
        (CD, "          CouliFocusReturn.to(this.ui, returnFocusId());\n",
         "          CouliFocusReturn.to(this.ui, inputUsable() ? 'agent_input' : 'agent_title');\n")]),
    ("读屏入口打开时经局部常量记 id", [
        (AC, ENTRY_REMEMBER, "            const from: string = AgentReportIds.entry(this.replyKey());\n"
                             "            AgentReportFocus.remember(from, this.replyKey(), true);\n")]),
    ("同意弹窗圆点改成所在行成组（行读屏名只读正文）", [
        (CD, BULLET_CD, "      Text('•')\n        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))\n"),
        (CD, CONSENT_LINE, CONSENT_LINE + "    .accessibilityGroup(true)\n    .accessibilityText(this.t(key))\n")]),
    ("信息组点击写成表达式体箭头", [
        (PC, LIST_OPEN, LIST_OPEN.replace("        .onClick(() => {\n          this.onOpen();\n        })\n", "        .onClick(() => this.onOpen())\n"))]),
    ("赞 / 踩读屏名在行标识方法里先判空再拼", [
        (AC, "    return this.replyTag.length > 0 ? name + PriceTerms.comma + this.replyTag : name;",
         "    if (this.replyTag.length === 0) {\n      return name;\n    }\n    return name + PriceTerms.comma + this.replyTag;")]),
]


def copy_good(dest):
    shutil.copytree(GOOD, dest)


def apply(root, rel, old, new):
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.count(old) != 1:
        return text.count(old)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(old, new))
    return 1


def self_test():
    failures = []
    killed = 0
    with tempfile.TemporaryDirectory(prefix="a11yagent-selftest-") as tmp:
        good = os.path.join(tmp, "good")
        copy_good(good)
        try:
            got = check(good)
        except Incomplete as e:
            got = [{"rule": "INCOMPLETE", "file": "", "line": 0, "msg": str(e)}]
        if got:
            failures.append("参照件不过：%s" % [(v["rule"], v["file"], v["line"], v["msg"]) for v in got])
        for idx, (name, rel, old, new, want) in enumerate(MUTATIONS):
            root = os.path.join(tmp, "m%02d" % idx)
            copy_good(root)
            n = apply(root, rel, old, new)
            if n != 1:
                failures.append("变异「%s」的原串出现 %d 次（应 1 次）" % (name, n))
                shutil.rmtree(root)
                continue
            try:
                rules = sorted({v["rule"] for v in check(root)})
            except Incomplete as e:
                failures.append("变异「%s」解析不完整（变异写坏了，不算杀）：%s" % (name, e))
                shutil.rmtree(root)
                continue
            if not any(r == want or r.startswith(want + "-") for r in rules):
                failures.append("变异「%s」没被 %s 杀（实际 %s）" % (name, want, rules))
            else:
                killed += 1
                print("KILLED %s ← %s" % (name, ", ".join(rules)))
            shutil.rmtree(root)
        for idx, (name, edits) in enumerate(BENIGN):
            root = os.path.join(tmp, "b%02d" % idx)
            copy_good(root)
            for rel, old, new in edits:
                n = apply(root, rel, old, new)
                if n != 1:
                    failures.append("良性改写「%s」的原串出现 %d 次（应 1 次）" % (name, n))
            try:
                got = check(root)
            except Incomplete as e:
                failures.append("良性改写「%s」解析不完整：%s" % (name, e))
                got = []
            if got:
                failures.append("良性改写「%s」被误报：%s" % (name, [(v["rule"], v["msg"]) for v in got]))
            else:
                print("BENIGN ok %s" % name)
            shutil.rmtree(root)
        # 语法错误 / 缺文件 / struct 改名必须 Incomplete（4），不算断言红
        for label, mutate in (
                ("语法错误", lambda r: open(os.path.join(r, TR), "a", encoding="utf-8").write("\nexport struct {\n")),
                ("缺文件", lambda r: os.remove(os.path.join(r, CD))),
                ("struct 改名", lambda r: apply(r, AC, "export struct AgentProductItem {", "export struct AgentProductItemX {"))):
            root = os.path.join(tmp, "x-" + str(abs(hash(label))))
            copy_good(root)
            mutate(root)
            try:
                check(root)
                failures.append("%s应该按 Incomplete 退出，却正常返回" % label)
            except Incomplete:
                pass
            shutil.rmtree(root)
    total = len(MUTATIONS) + len(BENIGN) + 4
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("A11YAGENT_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("A11YAGENT_SELFTEST 通过：参照件 0 违反 + 变异 %d/%d 全杀 + 良性改写 %d 全绿 + 语法错误 / 缺文件 / struct 改名 fail-closed"
          % (killed, len(MUTATIONS), len(BENIGN)))
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
        print("A11YAGENT 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("A11YAGENT 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    if violations:
        print("A11YAGENT_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("A11YAGENT_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
