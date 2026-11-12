#!/usr/bin/env python3
"""FU-HM-A11Y-HOME-SEARCH-harmony（FU-HM-A11Y-11 / 13 / 15 / 17 首页段；README 待编排 ⑫ ⑬，编排裁定 D10-1248）宿主结构守卫（测试作者 v1，先红；v2 按 Codex r1 两条 S2 收紧，见 AH5 与「不可执行代码」；v3 按 Codex r2 S2 收紧 AH5「被盖住」）。

用法：
    python3 tools/ci/a11yhome/check_a11y_home_search.py [--root <目录>]    # 检查（默认仓库根）
    python3 tools/ci/a11yhome/check_a11y_home_search.py --self-test        # 参照件（fixtures/good）全过 + 每个变异都要被杀 + 良性改写不误报

退出码：0 通过；1 有违反（自测：有变异没被杀、参照件不过或良性改写被误报）；2 参数不对；3 解析工具链不可用（复用 lint.hm10_toolchain，
node + 鸿蒙 SDK ohos-typescript）；4 无法保证判定完整（文件缺失、语法错误、找不到 struct / class、契约 JSON 坏）。解析错误不算「红在断言」，一律 4。

AH1–AH5 只看四个文件（AH6 另读登记文件，见下）：features/home/src/main/ets/HomeCards.ets、features/search/src/main/ets/SearchView.ets、entry/src/main/ets/search/SearchDraftTexts.ets、
contracts/snapshot/contracts/texts.default.json。判定在 a11yhome_ast.cjs（AST，不用正则切块；注释与字符串里的字不算）。@Builder 形参按每个调用点
代入求值（priceInput 的 id / 说明按 search_price_min、search_price_max 两个调用点分别判）。「移焦」认三种调用：CouliFocusReturn.to（键盘 + 读屏）、
CouliFocusReturn.accessibilityFocus（只读屏）、<…>.getFocusController().requestFocus（只键盘）；经 this.<方法>() 展开 4 层。
v2（Codex r1 S2-2）：移焦 / 播报只认会执行的调用——常量为假的 if / 三元 / && 分支、常量为真的 else / || 右侧、常量为假的 while / for 体、
return / throw / break / continue（或两支都退出的 if）之后的语句、从不调用的函数体（裸箭头语句、void、声明后没再引用的局部函数）里的都不算。
规则：
    AH1 首页弹窗（FU-15）：HomePopupView 里各组件的 onAppear 要把读屏焦点移到 home_popup_close（AH1-a11y），键盘焦点照旧也到它（AH1-kbd，
        Hm07vOverlayUi:185 钉住），读屏焦点不得再移到别处 / 判不了（AH1-wrong）。只有 getFocusController().requestFocus 是现树写法 → 红
    AH2 公告关闭（FU-17 首页段，⑬ 不加键）：每个 id 为 home_notice_close 的组件，accessibilityText 实参（经 this.<方法>() 单 return 展开）
        就是 HomeNoticeA11y.closeLabel(<row>.item.text)，<row> 是该按钮所在 @Builder 的 HomeNoticeRow 形参（AH2-label / AH2-row）；
        closeLabel 的读法（原名 + 「，」+ 正文前 12 字 + 省略）由逻辑层 A11yHomeNotice.test.ets 钉住。id 不得改（AH2-missing）
    AH3 价格半屏（FU-11）：bindSheet 内容 builder 树里有 search_price_confirm / search_price_min 的那个半屏——
        AH3-out   选项 onDisappear / onWillDisappear 里键盘 + 读屏焦点都回 search_filter_price（ID_FILTER_PRICE），不移到别处；
        AH3-in    半屏里 TITLE_BAR 标题 id 恰为 search_price_title（AH3-in-id）、.focusable(true)（AH3-in-focusable）、标题 / 半屏树组件
                  onAppear 或选项 onAppear / onWillAppear 把读屏焦点移到它、不移到别处；
        AH3-say   sheetError 每处非空赋值，同路执行的语句（跳过 if / switch 兄弟分支，同 LP4-say）里有 CouliAnnounce.say(…, 该错误)；
        AH3-none  一处非空赋值都没有也红；
        AH3-desc  search_price_min、search_price_max 两个价格框（每个调用点）的 accessibilityDescription 在 sheetError 非空时带这句错误
    AH4 搜索框标签（FU-13，⑫ 只改搜索框）：search_input 的 TextInput 恰一个；占位仍是 search.placeholder（AH4-placeholder，占位照旧显示）；
        accessibilityText 是 this.t(SearchKeys.X) 这类可求值的文案键（AH4-label），不是 search.placeholder，键在契约（优先）或
        SearchDraftTexts 里有文字（AH4-text，同 lockph R3），且文字与占位的生效文字不同（AH4-label）
    AH5 （v2，Codex r1 S2-1）延时读屏移焦不发过期请求：focus_sim.cjs 把真实 SearchView / HomePopupView 与真实 CouliFocusReturn（按 designsystem
        Index.ets 导出找到的源文件）在可控时钟下执行（读屏事件换记录器），走场景：打开 / 关闭（AH5-sheet-open / -close，正常路径仍要移焦）、
        打开后 10 ms 就关（-fastclose）、关后 10 ms 重开（-reopen）、连开连关（-flurry）、关后 / 开着时离页（-leave / -leave-open，出栈 =
        config.life.exit() + aboutToDisappear）、关后被详情盖住（-cover，config.onCovered(true)）；首页弹窗出现（AH5-popup-shown）、出现后
        10 ms 关闭（-popup-close，只允许 HomeTabRoot 回首页搜索入口）/ 点图片跳转（-popup-nav）。每次读屏移焦归到发出时最近的一步，目标不在
        该步允许的集合里 = 旧请求没作废 → 红。合格写法两种都认：调用方执行时复核（页面仍在、弹层轮次、没被盖住），或底层可作废
        （票据 / 轮次 / 取消句柄，调用方在关闭、重开、离页、被盖住时作废）。用户自己滑动读屏焦点宿主看不到（D10-1231），走真机走查。
        v3（Codex r2 S2；主会话口径：被详情盖住算离页，旧 / 新回焦请求都不得发出）：开着被盖住再收起（-cover-open，收起不得新排回
        【价格】）、盖住期间收起后解除覆盖再正常开关（-uncover，恢复后仍要进标题 / 回【价格】）、开着被盖住再解除后关闭（-uncover-open）、
        点【价格】后被盖住 / 离页、半屏出现回调迟到（-late-appear-cover / -late-appear-leave，标题移焦不得排队）。
        模拟执行出错 / 找不到半屏、【价格】点击、config.onCovered → 判不了（退出 4）。
    AH6 （#24 补，swap-recheck-harmony.md S2：摘整步 / 只摘本体行 / 删 List 登记原先都不红）登记自检，另读 tools/ci/verify.sh、
        common/core/src/test/List.test.ets 与 A11yHomeNotice.test.ets、entry/src/ohosTest/ets/test/ 下的 .ets（文本扫描，注释 / 字符串不算）：
        AH6-step  verify 顶层（不在函数 / if / for / while / case / heredoc 里）恰一行 step "FU-HM-A11Y-HOME-SEARCH 宿主检查" 与其后一行 record … PASS；
        AH6-cmd   步内顶层有现 verify.sh 的 6 条命令（本守卫 --self-test / 本体〔AH5 的 focus_sim.cjs 由本体执行〕、run-logic.cjs --self-test / 本体、
                  check-arkts.cjs --reference / --real），注释掉、改参数、挪进条件块或函数都算缺；
        AH6-chain 6 条按序、整行 `<命令> || fail_fast "…" "…"`（`|| true`、fail_fast 后再挂 `|| true` 都红）；
        AH6-fast  这一步在 --fast 早退之前、之前没有顶层 exit / return；
        AH6-core  core List.test.ets 恰一行 import <名> from './A11yHomeNotice.test'，<名>(); 在 testsuite() 体最外层恰一次、别处不调；逻辑单测有 export default；
        AH6-entry 设备段 A11yHomeSearchSeg.ets 恰导出 a11yHomeSearchCases(): void；HmA11yUi.test.ets 在时：恰一行 import 段函数、在 describe('HmA11yUi')
                  回调最外层恰调一次、entry 别处不调，entry List.test.ets 登记 HmA11yUi（同 AH6-core 口径）；本树（abd347c）还没有 HmA11yUi（COMMON
                  首建、集成随乙补丁加）→ 段函数须 0 处调用，输出「待集成」说明。
        verify.sh 块结构判不了 / 没有唯一 --fast 早退 / 找不到 testsuite() 或唯一 describe('HmA11yUi') / 文件缺失 → 退出 4。
        --self-test 以本仓库真实的这些文件为底本：真实登记须 0 违反（因此只摘本体行时，留下的 --self-test 行也会红）+ 41 个登记变异全杀 + 6 个良性改写 0 违反。
        局限：摘整步时本守卫自己也不跑了——在本树里只有守卫被运行（本体 / 自测 / 集成复核）时才红；集成头上应并进 ds02 test_test_facilities 的
        verify_top_level 断言（FUNDS 补 S1 同法），由别的步守本步。
不钉：商品卡整卡读屏（待编排 ①，推后 FLOW-HOME / FLOW-SEARCH）、价格框读屏名（⑫ 记「满足」）、骨架（⑯ 推后）、任何 wordBreak（⑧）。
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
AST_TOOL = os.path.join(HERE, "a11yhome_ast.cjs")
SIM_TOOL = os.path.join(HERE, "focus_sim.cjs")
GOOD = os.path.join(HERE, "fixtures", "good")

HOME = "features/home/src/main/ets/HomeCards.ets"
SEARCH = "features/search/src/main/ets/SearchView.ets"
DRAFT = "entry/src/main/ets/search/SearchDraftTexts.ets"
CONTRACT = "contracts/snapshot/contracts/texts.default.json"
OVERLAYS = "common/designsystem/src/main/ets/components/Overlays.ets"
DS_INDEX = "common/designsystem/Index.ets"
REQUIRED = (HOME, SEARCH, DRAFT, CONTRACT)
RULE_TITLES = {
    "AH1": "首页弹窗打开：读屏焦点 + 键盘焦点到关闭（FU-15）",
    "AH2": "公告【关闭】读屏名带行标识（FU-17 首页段）",
    "AH3": "价格半屏：焦点进标题、关闭回【价格】、校验错误播报并关联（FU-11）",
    "AH4": "搜索框读屏名是标签、不是占位（FU-13）",
    "AH5": "延时读屏移焦不发过期请求：关闭、重开、离页、被盖住后作废，盖住期间不新排（Codex r1 S2-1 / r2 S2，执行级）",
    "AH6": "登记：verify 宿主步必跑（顶层、fail_fast 链、--fast 早退前）+ core / entry 测试登记（复核 S2）",
}

_spec = importlib.util.spec_from_file_location("couli_lint_for_a11yhome", os.path.join(HERE, "..", "lint.py"))
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
        raise Incomplete("a11yhome_ast.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("a11yhome_ast.cjs 输出无法解析：%s" % e)
    if out["incomplete"]:
        raise Incomplete("；".join(out["incomplete"]))
    return out["violations"] + simulate(tool, root)


def simulate(tool, root):
    """AH5：focus_sim.cjs 在可控时钟下执行真实页面与 CouliFocusReturn（读真实树，designsystem 按 Index.ets 解析）。"""
    try:
        proc = subprocess.run([tool["node"], SIM_TOOL, tool["typescript"], root], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise lint.HM10ToolchainError("运行 focus_sim.cjs 失败：%s" % e)
    if proc.returncode == 3:
        raise lint.HM10ToolchainError(proc.stderr.decode("utf-8", "replace").strip())
    if proc.returncode != 0:
        raise Incomplete("focus_sim.cjs 退出 %d：%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))
    try:
        out = json.loads(proc.stdout.decode("utf-8"))
    except ValueError as e:
        raise Incomplete("focus_sim.cjs 输出无法解析：%s" % e)
    if os.environ.get("A11YHOME_SIM_LOG"):
        for line in out.get("log", []):
            print("  SIM " + line)
    if out["incomplete"]:
        raise Incomplete("AH5 模拟判不了：" + "；".join(out["incomplete"]))
    return out["violations"]


# ---------------------------------------------------------------- AH6 登记自检（swap-recheck-harmony.md S2，#24 只加）
# 复核 S2：摘整步、只摘本体行、删 core List 登记，宿主段都全绿。这里钉三处登记，不碰产品 / verify.sh / List.test.ets。

VERIFY = "tools/ci/verify.sh"
CORE_LIST = "common/core/src/test/List.test.ets"
CORE_TEST = "common/core/src/test/A11yHomeNotice.test.ets"
ENTRY_DIR = "entry/src/ohosTest/ets/test"
ENTRY_LIST = ENTRY_DIR + "/List.test.ets"
ENTRY_SUITE = ENTRY_DIR + "/HmA11yUi.test.ets"
ENTRY_SEG = ENTRY_DIR + "/A11yHomeSearchSeg.ets"
SEG_FN = "a11yHomeSearchCases"
HOST_STEP = "FU-HM-A11Y-HOME-SEARCH 宿主检查"
# 以现 verify.sh（:370–375）为准；focus_sim.cjs（AH5）由本体行内部执行（check() → simulate()），不单列 verify 步。
HOST_CMDS = (
    'python3 "$ROOT/tools/ci/a11yhome/check_a11y_home_search.py" --self-test',
    'python3 "$ROOT/tools/ci/a11yhome/check_a11y_home_search.py"',
    'node "$ROOT/tools/ci/a11yhome/run-logic.cjs" --self-test',
    'node "$ROOT/tools/ci/a11yhome/run-logic.cjs"',
    'node "$ROOT/tools/ci/a11yhome/check-arkts.cjs" --reference',
    'node "$ROOT/tools/ci/a11yhome/check-arkts.cjs" --real',
)
FAST_EXIT = 'if [ "$FAST" -eq 1 ]; then'


def verify_top_level(source):
    """verify.sh 的顶层命令行 [(行号, 行)]：不在函数体、if / for / while / until / case 块、heredoc 里，不是注释
    （照 FU-HM-A11Y-FUNDS 补 S1 的 test_test_facilities.verify_top_level）。结构对不上抛 Incomplete（fail-closed，退出 4）。"""
    out, stack, heredoc = [], [], None
    for no, line in enumerate(source.split("\n"), 1):
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        if stack and stack[-1] == "fn":
            if line == "}":
                stack.pop()
            continue
        if line[:1] in ("", " ", "\t", "#"):
            pass
        elif re.match(r"[A-Za-z_][A-Za-z0-9_]*\(\) \{$", line):
            if stack:
                raise Incomplete("%s 第 %d 行：块里定义函数，顶层结构判不了" % (VERIFY, no))
            stack.append("fn")
            continue
        else:
            word = line.split()[0].rstrip(";")
            single = re.search(r"(;|\s)(fi|done|esac)\s*$", line)
            if word in ("if", "for", "while", "until", "case") and not single:
                stack.append({"if": "fi", "case": "esac"}.get(word, "done"))
            elif word in ("fi", "done", "esac"):
                if not stack or stack[-1] != word:
                    raise Incomplete("%s 第 %d 行：多余或错配的 %s" % (VERIFY, no, word))
                stack.pop()
            elif not stack:
                out.append((no, line))
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_]+)['\"]?\s*$", line)
        if m and not line.lstrip().startswith("#"):
            heredoc = m.group(1)
    if stack or heredoc is not None:
        raise Incomplete("%s 结束时块 / heredoc 未闭合：%s %s" % (VERIFY, stack, heredoc))
    return out


def _v(rule, rel, line, msg):
    return {"rule": rule, "file": rel, "line": line, "msg": msg}


def verify_violations(source):
    """AH6-step / -cmd / -chain / -fast：宿主步顶层恰一处、6 条命令按序且整行 `<命令> || fail_fast "…" "…"`、在 --fast 早退之前。"""
    top = verify_top_level(source)
    lines = source.split("\n")
    v = []
    fast = [no for no, line in enumerate(lines, 1) if line == FAST_EXIT]
    if len(fast) != 1:
        raise Incomplete("%s 应恰有一处 --fast 早退（%s），实际 %d 处，判不了必跑" % (VERIFY, FAST_EXIT, len(fast)))
    steps = [no for no, line in top if line == 'step "%s"' % HOST_STEP]
    records = [no for no, line in top if line.startswith('record "%s" PASS ' % HOST_STEP)]
    if len(steps) != 1 or len(records) != 1 or records[0] < steps[0]:
        return [_v("AH6-step", VERIFY, (steps or records or [0])[0],
                   "verify 顶层须恰一行 step \"%s\" 与一行 record … PASS（record 在后）；实际 step %s record %s"
                   % (HOST_STEP, steps, records))]
    block = [(no, line) for no, line in top if steps[0] < no < records[0]]
    cursor = steps[0]
    for cmd in HOST_CMDS:
        chain = re.compile(re.escape(cmd) + r' \|\| fail_fast "[^"]+" "[^"]*"$')
        hits = [no for no, line in block if line.split(" ||")[0].rstrip() == cmd]
        good = [no for no, line in block if chain.match(line) and no > cursor]
        if not hits:
            v.append(_v("AH6-cmd", VERIFY, steps[0], "宿主步顶层缺命令（注释掉、改参数、挪进条件块 / 函数都算缺）：%s" % cmd))
        elif not good:
            v.append(_v("AH6-chain", VERIFY, hits[0], "命令不在 fail_fast 链上（须整行 `<命令> || fail_fast \"…\" \"…\"`）或顺序不对：%s" % cmd))
        else:
            cursor = good[0]
    if records[0] > fast[0]:
        v.append(_v("AH6-fast", VERIFY, steps[0], "宿主步须在 --fast 早退（第 %d 行）之前，fast 模式也要跑" % fast[0]))
    exits = [no for no, line in top if re.match(r"(exit|return)\b", line) and no < records[0]]
    if exits:
        v.append(_v("AH6-fast", VERIFY, exits[0], "宿主步之前有顶层 exit / return：%s" % exits))
    return v


def _blank(text, strings):
    """把 // 与 /* */ 注释（strings=True 时连同字符串内容）换成空格，换行与长度不变（行号、偏移照旧）。"""
    out, i, n = list(text), 0, len(text)
    while i < n:
        c, d = text[i], text[i + 1] if i + 1 < n else ""
        if c == "/" and d == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
        elif c == "/" and d == "*":
            end = text.find("*/", i + 2)
            if end < 0:
                raise Incomplete("块注释没闭合")
            for k in range(i, end + 2):
                if text[k] != "\n":
                    out[k] = " "
            i = end + 2
        elif c in "'\"`":
            k = i + 1
            while k < n and text[k] != c:
                k += 2 if text[k] == "\\" else 1
            if k >= n:
                raise Incomplete("字符串没闭合")
            if strings:
                for j in range(i + 1, k):
                    if text[j] != "\n":
                        out[j] = " "
            i = k + 1
        else:
            i += 1
    return "".join(out)


def _body(code, start):
    """code[start:] 起第一个 { 到配对 } 的 (开, 闭) 偏移；code 已去注释与字符串。"""
    open_at = code.find("{", start)
    if open_at < 0:
        return None
    depth = 0
    for k in range(open_at, len(code)):
        if code[k] == "{":
            depth += 1
        elif code[k] == "}":
            depth -= 1
            if depth == 0:
                return open_at, k
    return None


def _calls(code, name):
    return [m.start() for m in re.finditer(r"(?<![\w.$])" + re.escape(name) + r"\s*\(\s*\)\s*;", code)
            if not re.search(r"function\s*$", code[:m.start()])]


def _depth(code, lo, pos):
    return code[lo:pos].count("{") - code[lo:pos].count("}")


def _line(text, pos):
    return text.count("\n", 0, pos) + 1


def list_violations(rel, text, module, rule, what):
    """`import X from './<module>';` 恰一处，X(); 在 `export default function testsuite()` 体最外层恰一处、别处 0 处。"""
    comments = _blank(text, False)
    code = _blank(text, True)
    imports = re.findall(r"^import\s+([A-Za-z_$][\w$]*)\s+from\s+'\./" + re.escape(module) + r"';?[ \t]*$", comments, re.M)
    if len(imports) != 1:
        return [_v(rule, rel, 1, "%s：须恰一行 import <名> from './%s'（实际 %d 行）" % (what, module, len(imports)))]
    name = imports[0]
    head = re.search(r"export\s+default\s+function\s+testsuite\s*\(\s*\)", code)
    span = _body(code, head.end()) if head else None
    if span is None:
        raise Incomplete("%s：找不到 export default function testsuite() 的函数体" % rel)
    calls = _calls(code, name)
    inside = [p for p in calls if span[0] < p < span[1] and _depth(code, span[0], p) == 1]
    if len(inside) != 1 or len(calls) != 1:
        where = calls[0] if calls else span[0]
        return [_v(rule, rel, _line(text, where), "%s：%s(); 须在 testsuite() 体最外层恰调一次、别处不调（注释掉、挪进条件块 / 别的函数都不算；"
                   "实际体内最外层 %d 次、全文 %d 次）" % (what, name, len(inside), len(calls)))]
    return []


def entry_violations(read_rel, list_dir):
    """AH6-entry：设备段 A11yHomeSearchSeg 只经 HmA11yUi 唯一 describe 登记（README ⑪ / D10-1248）。
    返回 (违反, 说明)。本树（abd347c）还没有 HmA11yUi.test.ets（COMMON 首建，集成随乙补丁加）：此时段函数必须哪里都不调（待集成）；
    一旦 HmA11yUi.test.ets 在：须 import { a11yHomeSearchCases } from './A11yHomeSearchSeg' 恰一处、在 describe('HmA11yUi') 回调最外层恰调一次、
    entry 别处不调，且 entry List.test.ets 登记 HmA11yUi（list_violations 同口径）。"""
    seg = read_rel(ENTRY_SEG)
    if seg is None or len(re.findall(r"^export\s+function\s+" + SEG_FN + r"\s*\(\s*\)\s*:\s*void\s*\{", _blank(seg, True), re.M)) != 1:
        return [_v("AH6-entry", ENTRY_SEG, 1, "设备段文件须在且恰导出一个 export function %s(): void" % SEG_FN)], []
    calls = {}
    for rel in list_dir():
        text = read_rel(rel)
        found = _calls(_blank(text, True), SEG_FN)
        if found:
            calls[rel] = (text, found)
    suite = read_rel(ENTRY_SUITE)
    if suite is None:
        if calls:
            rel, (text, found) = sorted(calls.items())[0]
            return [_v("AH6-entry", rel, _line(text, found[0]), "还没有 HmA11yUi.test.ets，%s() 不得在别处调用（只能进 HmA11yUi 唯一 describe）" % SEG_FN)], []
        return [], ["AH6 entry：本树无 %s，设备段 %s() 0 处调用 = 待集成（乙补丁加进 describe('HmA11yUi')）；文件一出现本条即按登记判" % (ENTRY_SUITE, SEG_FN)]
    v = []
    comments, code = _blank(suite, False), _blank(suite, True)
    imports = re.findall(r"^import\s*\{[^}]*\b" + SEG_FN + r"\b[^}]*\}\s*from\s*'\./A11yHomeSearchSeg';?[ \t]*$", comments, re.M)
    if len(imports) != 1:
        v.append(_v("AH6-entry", ENTRY_SUITE, 1, "须恰一行 import { %s } from './A11yHomeSearchSeg'（实际 %d 行）" % (SEG_FN, len(imports))))
    heads = list(re.finditer(r"describe\s*\(\s*'HmA11yUi'\s*,\s*\(\s*\)\s*=>\s*", comments))
    span = _body(code, heads[0].end()) if len(heads) == 1 else None
    if span is None:
        raise Incomplete("%s：找不到唯一的 describe('HmA11yUi', () => { … })" % ENTRY_SUITE)
    others = sum(len(found) for rel, (_, found) in calls.items() if rel != ENTRY_SUITE)
    mine = calls.get(ENTRY_SUITE, (suite, []))[1]
    inside = [p for p in mine if span[0] < p < span[1] and _depth(code, span[0], p) == 1]
    if len(inside) != 1 or len(mine) != 1 or others:
        v.append(_v("AH6-entry", ENTRY_SUITE, _line(suite, (mine or [span[0]])[0]),
                    "%s(); 须在 describe('HmA11yUi') 回调最外层恰调一次、entry 别处不调（实际最外层 %d 次、本文件 %d 次、别处 %d 次）"
                    % (SEG_FN, len(inside), len(mine), others)))
    entry_list = read_rel(ENTRY_LIST)
    if entry_list is None:
        raise Incomplete("%s 不存在，判不了登记" % ENTRY_LIST)
    v += list_violations(ENTRY_LIST, entry_list, "HmA11yUi.test", "AH6-entry", "entry 设备 List 登记 HmA11yUi")
    return v, []


def registration(root):
    """AH6：verify 宿主步必跑 + core / entry 测试登记。返回 (违反, 说明)；文件缺失 / 结构判不了抛 Incomplete。"""
    def read_rel(rel):
        return read(root, rel)

    def must(rel):
        text = read_rel(rel)
        if text is None:
            raise Incomplete("%s: 文件不存在，判不了登记" % rel)
        return text

    def list_dir():
        base = os.path.join(root, ENTRY_DIR)
        if not os.path.isdir(base):
            raise Incomplete("%s 目录不存在，判不了设备段登记" % ENTRY_DIR)
        return sorted(ENTRY_DIR + "/" + f for f in os.listdir(base) if f.endswith(".ets"))

    v = verify_violations(must(VERIFY))
    core_test = read_rel(CORE_TEST)
    if core_test is None or len(re.findall(r"^export\s+default\s+function\s+[A-Za-z_$][\w$]*\s*\(", _blank(core_test, True), re.M)) != 1:
        v.append(_v("AH6-core", CORE_TEST, 1, "core 逻辑单测文件须在且恰一个 export default function"))
    v += list_violations(CORE_LIST, must(CORE_LIST), "A11yHomeNotice.test", "AH6-core", "core 本机单测 List 登记 A11yHomeNotice")
    ev, notes = entry_violations(read_rel, list_dir)
    return v + ev, notes


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
POPUP_GOOD = "      this.closeFocus = CouliFocusReturn.to(this.getUIContext(), 'home_popup_close');\n"
POPUP_OLD = ("      try {\n        this.getUIContext().getFocusController().requestFocus('home_popup_close');\n      } catch (e) {\n"
             "        // 焦点请求失败不影响弹窗。\n      }\n")
NOTICE_GOOD = "        .accessibilityText(HomeNoticeA11y.closeLabel(row.item.text))\n"
TITLE_ID = "        .id('search_price_title')\n"
TITLE_FOCUSABLE = "        .id('search_price_title')\n        .focusable(true)\n"
TITLE_FOCUS = "          this.sheetFocus = CouliFocusReturn.to(this.getUIContext(), 'search_price_title');\n"
# v3（Codex r2 S2）：标题移焦与关闭回焦都复核「页面仍在且没被盖住」（参照件 sheetCovered，setCovered 里记）
SHEET_LIVE = "this.config.life.alive && !this.sheetCovered"
TITLE_GUARD = "          if (!this.config.life.alive || this.sheetCovered) {\n            return;\n          }\n"
TITLE_APPEAR = ("        .onAppear(() => {\n" + TITLE_GUARD + "          CouliFocusReturn.cancel(this.sheetFocus);\n" + TITLE_FOCUS + "        })\n")
SHEET_OUT_LINE = "          this.sheetFocus = CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE);\n"
SHEET_OUT_IF = "        if (" + SHEET_LIVE + ") {\n" + SHEET_OUT_LINE + "        }\n"
COVERED_SET = "    this.sheetCovered = covered;\n"
COVERED_FIELD = "  private sheetCovered: boolean = false;\n"
SHEET_OUT = "        CouliFocusReturn.cancel(this.sheetFocus);\n" + SHEET_OUT_IF
# v2 参照件（REFERENCE_ONLY）：底层可作废（Overlays 票据，新请求取代旧请求）+ 调用方存票据、在关闭 / 重开 / 离页 / 被盖住时 cancel
TICKET_CHECK = "      if (CouliFocusReturn.pending !== ticket) {\n        return;\n      }\n"
CANCEL_BODY = ("    if (ticket !== 0 && CouliFocusReturn.pending === ticket) {\n      CouliFocusReturn.pending = 0;\n    }\n")
DETACH_CANCEL = "    };\n    CouliFocusReturn.cancel(this.sheetFocus);\n  }\n"
COVER_CANCEL = "    if (covered) {\n      CouliFocusReturn.cancel(this.sheetFocus);\n"
OPEN_CANCEL = "    this.model.sheetOpen = true;\n    CouliFocusReturn.cancel(this.sheetFocus);\n"
POPUP_CANCEL = "  aboutToDisappear(): void {\n    CouliFocusReturn.cancel(this.closeFocus);\n  }\n"
# abd347c 的 CouliFocusReturn（读屏请求无条件延时执行），给「调用方复核」良性写法与变异用
OLD_FOCUS_RETURN = """export class CouliFocusReturn {
  static to(ui: UIContext, id: string): void {
    if (id.length === 0) {
      return;
    }
    try {
      ui.getFocusController().requestFocus(id);
    } catch (e) {
      // 触发控件已不在页面上时忽略。
    }
    setTimeout(() => {
      CouliFocusReturn.accessibilityFocus(ui, id);
    }, A11Y_FOCUS_DELAY_MS);
  }

  /** 只移读屏焦点（不动键盘焦点）。 */
  static accessibilityFocus(ui: UIContext, id: string): void {
    try {
      const bundle: string = ui.getHostContext()?.applicationInfo?.name ?? '';
      const event: accessibility.EventInfo =
        new accessibility.EventInfo('requestFocusForAccessibility', bundle, 'common');
      event.customId = id;
      accessibility.sendAccessibilityEvent(event).catch(() => {
        // 读屏未开启或节点已不在时忽略。
      });
    } catch (e) {
      // 同上。
    }
  }
}

"""
SAY = "      CouliAnnounce.say(this.getUIContext(), this.model.sheetError);\n"
DESC = "      .accessibilityDescription(this.model.sheetError)\n"
LABEL = "          .accessibilityText(this.t(SearchKeys.INPUT_LABEL))\n"
DRAFT_LABEL = "    m.set('search.input_label', '搜索商品');\n"
INVALID = "      this.model.sheetError = this.t(SearchKeys.SHEET_INVALID);\n"
OPEN_SHEET = "    this.model.sheetError = '';\n    this.model.sheetOpen = true;\n"

# （名字，文件，原串，新串，应报的规则前缀）；原串在参照件里必须唯一
MUTATIONS = [
    # AH1 首页弹窗
    ("弹窗回退 getFocusController().requestFocus（abd347c 写法，只键盘焦点）", HOME, POPUP_GOOD, POPUP_OLD, "AH1-a11y"),
    ("弹窗读屏焦点移到图片而不是关闭", HOME, POPUP_GOOD,
     POPUP_GOOD.replace("CouliFocusReturn.to(this.getUIContext(), 'home_popup_close')",
                        "CouliFocusReturn.to(this.getUIContext(), 'home_popup_image')"), "AH1"),
    ("弹窗只发读屏焦点、键盘焦点不移了", HOME, POPUP_GOOD,
     "      CouliFocusReturn.accessibilityFocus(this.getUIContext(), 'home_popup_close');\n", "AH1-kbd"),
    ("弹窗先到关闭、又把读屏焦点移到图片", HOME, POPUP_GOOD,
     POPUP_GOOD + "      CouliFocusReturn.accessibilityFocus(this.getUIContext(), 'home_popup_image');\n", "AH1-wrong"),
    ("弹窗移焦整段删掉", HOME, POPUP_GOOD, "", "AH1-a11y"),
    # AH2 公告关闭
    ("公告关闭名回到常量「关闭公告」（现树写法）", HOME, NOTICE_GOOD, "        .accessibilityText(HomeDraftTexts.text('home.notice.close'))\n", "AH2-label"),
    ("公告关闭名 closeLabel 传空串", HOME, NOTICE_GOOD, "        .accessibilityText(HomeNoticeA11y.closeLabel(''))\n", "AH2-row"),
    ("公告关闭名 closeLabel 传条目 id 不是正文", HOME, NOTICE_GOOD, "        .accessibilityText(HomeNoticeA11y.closeLabel(row.item.itemId))\n", "AH2-row"),
    ("公告关闭名直接拼整条正文（不经 closeLabel、不截断）", HOME, NOTICE_GOOD,
     "        .accessibilityText(HomeDraftTexts.text('home.notice.close') + row.item.text)\n", "AH2-label"),
    ("公告关闭名只在有点击目标时带行标识", HOME, NOTICE_GOOD,
     "        .accessibilityText(row.tap !== null ? HomeNoticeA11y.closeLabel(row.item.text) : HomeDraftTexts.text('home.notice.close'))\n", "AH2-label"),
    ("公告关闭没有读屏名", HOME, NOTICE_GOOD, "", "AH2-label"),
    # AH3 价格半屏：进
    ("半屏标题没有 id（现树写法）", SEARCH, TITLE_ID, "", "AH3-in-id"),
    ("半屏标题 id 改成别的名字", SEARCH, TITLE_ID, "        .id('search_price_head')\n", "AH3-in-id"),
    ("半屏标题不可获焦", SEARCH, TITLE_FOCUSABLE, "        .id('search_price_title')\n", "AH3-in-focusable"),
    ("半屏标题 onAppear 删掉（不移焦）", SEARCH, TITLE_APPEAR, "", "AH3-in"),
    ("半屏打开焦点移到最低价框而不是标题", SEARCH, TITLE_APPEAR,
     TITLE_APPEAR.replace("'search_price_title');", "'search_price_min');"), "AH3-in"),
    # AH3 价格半屏：出
    ("半屏关闭不回焦（abd347c 写法）", SEARCH, SHEET_OUT, "", "AH3-out"),
    ("半屏关闭焦点回到【只看有券】", SEARCH, SHEET_OUT, SHEET_OUT.replace("ID_FILTER_PRICE", "ID_FILTER_COUPON"), "AH3-out"),
    ("半屏关闭只回读屏焦点（键盘焦点没回）", SEARCH, SHEET_OUT,
     "        CouliFocusReturn.accessibilityFocus(this.getUIContext(), ID_FILTER_PRICE);\n", "AH3-out"),
    ("半屏关闭只回键盘焦点（读屏焦点没回）", SEARCH, SHEET_OUT,
     "        this.getUIContext().getFocusController().requestFocus(ID_FILTER_PRICE);\n", "AH3-out"),
    # AH3 校验错误播报
    ("校验失败不播报（现树写法）", SEARCH, SAY, "", "AH3-say"),
    ("校验失败播报的是说明句不是错误", SEARCH, SAY, "      CouliAnnounce.say(this.getUIContext(), this.t(SearchKeys.SHEET_NOTE));\n", "AH3-say"),
    ("校验失败播报放进另一个分支（不同路）", SEARCH, SAY,
     "      if (this.model.sheetOpen) {\n        CouliAnnounce.say(this.getUIContext(), this.model.sheetError);\n      }\n", "AH3-say"),
    ("另加一处校验错误赋值、不播报", SEARCH, OPEN_SHEET,
     "    this.model.sheetError = '';\n    if (this.model.blocked) {\n      this.model.sheetError = this.t(SearchKeys.SHEET_INVALID);\n    }\n"
     "    this.model.sheetOpen = true;\n", "AH3-say"),
    ("校验失败不再给错误文字", SEARCH, INVALID + SAY, "", "AH3-none"),
    # AH3 错误关联到价格框
    ("两个价格框都不关联错误（现树写法）", SEARCH, DESC, "", "AH3-desc"),
    ("只有最低价框关联错误（漏最高价）", SEARCH, DESC,
     "      .accessibilityDescription(id === 'search_price_min' ? this.model.sheetError : '')\n", "AH3-desc"),
    ("价格框说明是说明句不是错误", SEARCH, DESC, "      .accessibilityDescription(this.t(SearchKeys.SHEET_NOTE))\n", "AH3-desc"),
    ("价格框说明只在没错误时有字（反了）", SEARCH, DESC,
     "      .accessibilityDescription(this.model.sheetError.length === 0 ? this.model.sheetError : '')\n", "AH3-desc"),
    # AH4 搜索框标签
    ("搜索框读屏名回到占位（现树写法）", SEARCH, LABEL, "          .accessibilityText(this.t(SearchKeys.PLACEHOLDER))\n", "AH4-label"),
    ("搜索框读屏名写成占位字面键", SEARCH, LABEL, "          .accessibilityText(this.t('search.placeholder'))\n", "AH4-label"),
    ("搜索框没有读屏名", SEARCH, LABEL, "", "AH4-label"),
    ("标签键在草稿表里没有文字", DRAFT, DRAFT_LABEL, "", "AH4-text"),
    ("标签文字与占位相同", DRAFT, DRAFT_LABEL, "    m.set('search.input_label', '搜商品名，或粘贴商品链接');\n", "AH4-label"),
    ("占位不再显示（占位换成标签键）", SEARCH,
     "        TextInput({ text: this.model.inputText, placeholder: this.t(SearchKeys.PLACEHOLDER),",
     "        TextInput({ text: this.model.inputText, placeholder: this.t(SearchKeys.INPUT_LABEL),", "AH4-placeholder"),
]

# 「漏一框」变异要同时把 priceInput 的形参用起来：本身已用 id 形参，无需附加编辑
EXTRA_EDITS = {}

# 良性改写（重构但口径不变），必须仍然全绿——防判据收紧过头。（名字，[(文件，原串，新串)…]）
BENIGN = [
    ("弹窗：读屏焦点用 accessibilityFocus、键盘焦点照旧 requestFocus（id 用模块常量）", [
        (HOME, POPUP_GOOD,
         "      CouliFocusReturn.accessibilityFocus(this.getUIContext(), ID_POPUP_CLOSE);\n"
         "      try {\n        this.getUIContext().getFocusController().requestFocus(ID_POPUP_CLOSE);\n      } catch (e) {\n"
         "        // 焦点请求失败不影响弹窗。\n      }\n"),
        (HOME, "/** 首页卡片的外框", "/** 弹窗关闭按钮 id。 */\nconst ID_POPUP_CLOSE: string = 'home_popup_close';\n\n/** 首页卡片的外框"),
    ]),
    ("弹窗：移焦挪到关闭按钮自己的 onAppear、经 this.<方法>()", [
        (HOME, POPUP_GOOD, ""),
        (HOME, "      .id('home_popup_close')\n", "      .id('home_popup_close')\n      .onAppear(() => this.focusClose())\n"),
        (HOME, "  private tickets(): HomePopupTicket[] {",
         "  private focusClose(): void {\n    this.closeFocus = CouliFocusReturn.to(this.getUIContext(), 'home_popup_close');\n  }\n\n"
         "  private tickets(): HomePopupTicket[] {"),
    ]),
    ("公告：读屏名经 this.closeName(row)（单 return）", [
        (HOME, NOTICE_GOOD, "        .accessibilityText(this.closeName(row))\n"),
        (HOME, "  private display(): HomeNoticeDisplay {",
         "  private closeName(r: HomeNoticeRow): string {\n    return HomeNoticeA11y.closeLabel(r.item.text);\n  }\n\n  private display(): HomeNoticeDisplay {"),
    ]),
    ("半屏：标题 id 用模块常量、移焦挪到 bindSheet 选项 onAppear", [
        (SEARCH, TITLE_ID, "        .id(ID_PRICE_TITLE)\n"),
        (SEARCH, TITLE_APPEAR, ""),
        (SEARCH, "const CHIP_HEIGHT: number = 36;\n", "const CHIP_HEIGHT: number = 36;\nconst ID_PRICE_TITLE: string = 'search_price_title';\n"),
        (SEARCH, "      showClose: false,\n",
         "      showClose: false,\n      onAppear: () => {\n        CouliFocusReturn.cancel(this.sheetFocus);\n"
         "        if (this.config.life.alive && !this.sheetCovered) {\n"
         "          this.sheetFocus = CouliFocusReturn.to(this.getUIContext(), ID_PRICE_TITLE);\n        }\n      },\n"),
    ]),
    ("半屏：关闭回焦经 this.returnPriceFocus()", [
        (SEARCH, SHEET_OUT, "        this.returnPriceFocus();\n"),
        (SEARCH, "  private confirmSheet(): void {",
         "  private returnPriceFocus(): void {\n    CouliFocusReturn.cancel(this.sheetFocus);\n    if (!this.config.life.alive || this.sheetCovered) {\n      return;\n    }\n"
         "    this.sheetFocus = CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE);\n  }\n\n  private confirmSheet(): void {"),
    ]),
    ("校验失败：错误先放局部常量再赋值与播报", [
        (SEARCH, INVALID + SAY,
         "      const err: string = this.t(SearchKeys.SHEET_INVALID);\n      this.model.sheetError = err;\n"
         "      CouliAnnounce.say(this.getUIContext(), err);\n"),
    ]),
    ("价格框：说明只在有错误时带（length > 0 ? 错误 : ''）", [
        (SEARCH, DESC, "      .accessibilityDescription(this.model.sheetError.length > 0 ? this.model.sheetError : '')\n"),
    ]),
    ("价格框：说明作为 priceInput 形参、两个调用点都传 sheetError", [
        (SEARCH, DESC, "      .accessibilityDescription(desc)\n"),
        (SEARCH, "  priceInput(value: string, placeholder: string, id: string, onValue: (v: string) => void) {",
         "  priceInput(value: string, placeholder: string, id: string, desc: string, onValue: (v: string) => void) {"),
        (SEARCH, "this.t(SearchKeys.SHEET_MIN), 'search_price_min', (v: string) => {",
         "this.t(SearchKeys.SHEET_MIN), 'search_price_min', this.model.sheetError, (v: string) => {"),
        (SEARCH, "this.t(SearchKeys.SHEET_MAX), 'search_price_max', (v: string) => {",
         "this.t(SearchKeys.SHEET_MAX), 'search_price_max', this.model.sheetError, (v: string) => {"),
    ]),
    ("搜索框标签经 this.config.texts.text(SearchKeys.INPUT_LABEL)", [
        (SEARCH, LABEL, "          .accessibilityText(this.config.texts.text(SearchKeys.INPUT_LABEL))\n"),
    ]),
]

# 「价格框说明作为形参，最高价调用点传空串」：形参代入后漏一框，必须杀（与良性改写同结构，证明是按调用点分别判的）
MUTATIONS.append(("价格框说明作为形参、最高价调用点传空串", SEARCH, DESC, "      .accessibilityDescription(desc)\n", "AH3-desc"))
EXTRA_EDITS["价格框说明作为形参、最高价调用点传空串"] = [
    (SEARCH, "  priceInput(value: string, placeholder: string, id: string, onValue: (v: string) => void) {",
     "  priceInput(value: string, placeholder: string, id: string, desc: string, onValue: (v: string) => void) {"),
    (SEARCH, "this.t(SearchKeys.SHEET_MIN), 'search_price_min', (v: string) => {",
     "this.t(SearchKeys.SHEET_MIN), 'search_price_min', this.model.sheetError, (v: string) => {"),
    (SEARCH, "this.t(SearchKeys.SHEET_MAX), 'search_price_max', (v: string) => {",
     "this.t(SearchKeys.SHEET_MAX), 'search_price_max', '', (v: string) => {"),
]


# ---------------------------------------------------------------- v2（Codex r1 S2-2）：不可执行的移焦 / 播报不算
DEAD_MUTATIONS = [
    ("关闭回焦写进 if (false)（Codex r1 原变异）", SEARCH, SHEET_OUT,
     "        if (false) {\n          CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE);\n        }\n", "AH3-out"),
    ("关闭回焦的页面复核换成 if (false)", SEARCH, SHEET_OUT_IF, SHEET_OUT_IF.replace(SHEET_LIVE, "false"), "AH3-out"),
    ("关闭回焦在 return 之后", SEARCH, SHEET_OUT, "        return;\n" + SHEET_OUT, "AH3-out"),
    ("关闭回焦在两支都 return 的 if / else 之后", SEARCH, SHEET_OUT,
     "        if (this.model.blocked) {\n          return;\n        } else {\n          return;\n        }\n" + SHEET_OUT, "AH3-out"),
    ("关闭回焦在 if (true) 的 else 里", SEARCH, SHEET_OUT,
     "        if (true) {\n          this.persist();\n        } else {\n" + SHEET_OUT_LINE + "        }\n", "AH3-out"),
    ("关闭回焦写成 false && …", SEARCH, SHEET_OUT_LINE, "          false && CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE);\n", "AH3-out"),
    ("关闭回焦写成 false ? … : undefined", SEARCH, SHEET_OUT_LINE,
     "          this.sheetFocus = false ? CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE) : 0;\n", "AH3-out"),
    ("关闭回焦写进 while (false)", SEARCH, SHEET_OUT,
     "        while (false) {\n          CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE);\n        }\n", "AH3-out"),
    ("关闭回焦写进从不调用的局部箭头函数", SEARCH, SHEET_OUT,
     "        const back = (): number => CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE);\n", "AH3-out"),
    ("关闭回焦写成裸箭头语句（从不调用）", SEARCH, SHEET_OUT,
     "        (): number => CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE);\n", "AH3-out"),
    ("关闭回焦经 this.<方法>()，方法里先 return", SEARCH, SHEET_OUT, "        this.returnPriceFocus();\n", "AH3-out"),
    ("关闭回焦条件是模块常量 false", SEARCH, SHEET_OUT_IF, SHEET_OUT_IF.replace(SHEET_LIVE, "SHEET_FOCUS_ON"), "AH3-out"),
    ("标题移焦写进 if (false)", SEARCH, TITLE_FOCUS,
     "          if (false) {\n  " + TITLE_FOCUS + "          }\n", "AH3-in"),
    ("弹窗移焦在 return 之后", HOME, POPUP_GOOD, "      return;\n" + POPUP_GOOD, "AH1-a11y"),
    ("弹窗移焦条件 1 > 2", HOME, POPUP_GOOD, "      if (1 > 2) {\n  " + POPUP_GOOD + "      }\n", "AH1-a11y"),
    ("校验失败播报在 return 之后", SEARCH, SAY, "      return;\n" + SAY, "AH3-say"),
]
MUTATIONS.extend(DEAD_MUTATIONS)
EXTRA_EDITS["关闭回焦经 this.<方法>()，方法里先 return"] = [
    (SEARCH, "  private confirmSheet(): void {",
     "  private returnPriceFocus(): void {\n    return;\n    CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE);\n  }\n\n  private confirmSheet(): void {"),
]
EXTRA_EDITS["关闭回焦条件是模块常量 false"] = [
    (SEARCH, "const CHIP_HEIGHT: number = 36;\n", "const CHIP_HEIGHT: number = 36;\nconst SHEET_FOCUS_ON: boolean = false;\n"),
]
BENIGN.extend([
    ("会执行的写法照算：if (true) 包着、do { } while (false) 包着、条件为模块常量 true", [
        (SEARCH, SHEET_OUT_IF, "        if (true && SHEET_FOCUS_ON && " + SHEET_LIVE + ") {\n          do {\n  " + SHEET_OUT_LINE +
         "          } while (false);\n        }\n"),
        (SEARCH, "const CHIP_HEIGHT: number = 36;\n", "const CHIP_HEIGHT: number = 36;\nconst SHEET_FOCUS_ON: boolean = true;\n"),
    ]),
    ("局部箭头函数声明后调用（会执行）", [
        (SEARCH, SHEET_OUT_IF, "        const back = (): void => {\n          if (" + SHEET_LIVE + ") {\n  " + SHEET_OUT_LINE +
         "          }\n        };\n        back();\n"),
    ]),
    ("不可执行的错误移焦不算「移到别处」（if (false) 里移到【只看有券】）", [
        (SEARCH, SHEET_OUT, SHEET_OUT + "        if (false) {\n          CouliFocusReturn.accessibilityFocus(this.getUIContext(), ID_FILTER_COUPON);\n        }\n"),
    ]),
])

# ---------------------------------------------------------------- v2（Codex r1 S2-1）：延时读屏移焦的过期请求（AH5，执行级）
STALE_MUTATIONS = [
    ("底层回到无条件执行（abd347c 的 CouliFocusReturn，调用方不复核）", OVERLAYS, TICKET_CHECK, "", "AH5"),
    ("底层 cancel 什么都不做", OVERLAYS, CANCEL_BODY, "", "AH5"),
    ("底层到点不再查票据、cancel 也不做（全部旧请求照发）", OVERLAYS, TICKET_CHECK + "      CouliFocusReturn.pending = 0;\n", "", "AH5"),
    ("关闭回焦不看页面仍在（离页时半屏随页收起又排一个）", SEARCH, SHEET_OUT_IF, SHEET_OUT_LINE.replace("          ", "        ", 1), "AH5-sheet-leave-open"),
    ("离页（life.exit → detach）不作废", SEARCH, DETACH_CANCEL, "    };\n  }\n", "AH5-sheet-leave"),
    ("被详情盖住不作废", SEARCH, COVER_CANCEL, "    if (covered) {\n", "AH5-sheet-cover"),
    ("关闭回焦不存票据（离页 / 盖住时作废不到）", SEARCH, SHEET_OUT_LINE,
     "          CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE);\n", "AH5"),
    ("弹窗收起（aboutToDisappear）不作废", HOME, POPUP_CANCEL, "", "AH5-popup"),
    ("弹窗不存票据", HOME, POPUP_GOOD, "      CouliFocusReturn.to(this.getUIContext(), 'home_popup_close');\n", "AH5-popup"),
    ("标题移焦改成调用方无条件 setTimeout(accessibilityFocus)", SEARCH, TITLE_FOCUS,
     "          const ui: UIContext = this.getUIContext();\n"
     "          setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, 'search_price_title'), 120);\n", "AH5-sheet-fastclose"),
    ("弹窗移焦改成调用方无条件 setTimeout(accessibilityFocus) + requestFocus", HOME, POPUP_GOOD,
     "      const ui: UIContext = this.getUIContext();\n      try {\n        ui.getFocusController().requestFocus('home_popup_close');\n"
     "      } catch (e) {\n        // 忽略。\n      }\n      setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, 'home_popup_close'), 120);\n", "AH5-popup"),
    ("底层作废但调用方从不 cancel（只靠新请求取代）", SEARCH, DETACH_CANCEL, "    };\n  }\n", "AH5"),
]
EXTRA_EDITS["底层作废但调用方从不 cancel（只靠新请求取代）"] = [
    (SEARCH, COVER_CANCEL, "    if (covered) {\n"),
    (SEARCH, OPEN_CANCEL, "    this.model.sheetOpen = true;\n"),
    (SEARCH, "        CouliFocusReturn.cancel(this.sheetFocus);\n" + SHEET_OUT_IF, SHEET_OUT_LINE.replace("          ", "        ", 1)),
    (SEARCH, "          CouliFocusReturn.cancel(this.sheetFocus);\n" + TITLE_FOCUS, TITLE_FOCUS),
    (HOME, POPUP_CANCEL, ""),
]

# 「调用方执行时复核」写法：底层保持 abd347c 的无条件 to，调用方不用 to 的延时，自己移键盘焦点 + setTimeout 里复核后 accessibilityFocus。
CALLER_FIELDS_OLD = "  private sheetFocus: number = 0;\n"
CALLER_FIELDS = "  private sheetFocus: number = 0;\n  private sheetRound: number = 0;\n"
# v3：执行时复核也要看「没被盖住」（开着被盖住再收起时，盖住换轮次之后收起又排了新轮次，只看轮次拦不住）
CALLER_COND = "this.config.life.alive && !this.sheetCovered && this.sheetRound === round"
CALLER_OUT = ("        this.sheetRound++;\n        const round: number = this.sheetRound;\n        const ui: UIContext = this.getUIContext();\n"
              "        try {\n          ui.getFocusController().requestFocus(ID_FILTER_PRICE);\n        } catch (e) {\n          // 忽略。\n        }\n"
              "        setTimeout(() => {\n          if (" + CALLER_COND + ") {\n"
              "            CouliFocusReturn.accessibilityFocus(ui, ID_FILTER_PRICE);\n          }\n        }, 120);\n")
CALLER_TITLE = ("          const round: number = this.sheetRound;\n          const ui: UIContext = this.getUIContext();\n"
                "          try {\n            ui.getFocusController().requestFocus('search_price_title');\n          } catch (e) {\n            // 忽略。\n          }\n"
                "          setTimeout(() => {\n            if (" + CALLER_COND + ") {\n"
                "              CouliFocusReturn.accessibilityFocus(ui, 'search_price_title');\n            }\n          }, 120);\n")
CALLER_POPUP = ("      this.shown = true;\n      const ui: UIContext = this.getUIContext();\n      try {\n"
                "        ui.getFocusController().requestFocus('home_popup_close');\n      } catch (e) {\n        // 忽略。\n      }\n"
                "      setTimeout(() => {\n        if (this.shown) {\n          CouliFocusReturn.accessibilityFocus(ui, 'home_popup_close');\n        }\n      }, 120);\n")


def _overlays_block():
    with open(os.path.join(GOOD, OVERLAYS), encoding="utf-8") as f:
        text = f.read()
    start = text.index("export class CouliFocusReturn {")
    return text[start:text.index("/**\n * 弹窗面板", start)]


def caller_recheck_edits(out=CALLER_OUT, title=CALLER_TITLE, popup=CALLER_POPUP, cover="    if (covered) {\n      this.sheetRound++;\n",
                         open_=OPEN_CANCEL.replace("CouliFocusReturn.cancel(this.sheetFocus)", "this.sheetRound++"),
                         popup_leave="  aboutToDisappear(): void {\n    this.shown = false;\n  }\n"):
    return [
        (OVERLAYS, _overlays_block(), OLD_FOCUS_RETURN),
        (SEARCH, CALLER_FIELDS_OLD, CALLER_FIELDS),
        (SEARCH, DETACH_CANCEL, "    };\n  }\n"),
        (SEARCH, COVER_CANCEL, cover),
        (SEARCH, OPEN_CANCEL, open_),
        (SEARCH, SHEET_OUT, out),
        (SEARCH, "          CouliFocusReturn.cancel(this.sheetFocus);\n" + TITLE_FOCUS, title),
        # v3：标题出现时不预先复核，全靠 setTimeout 里执行时复核（页面仍在、没被盖住、轮次没变）
        (SEARCH, TITLE_GUARD, ""),
        (HOME, "  private closeFocus: number = 0;\n", "  private shown: boolean = false;\n"),
        (HOME, POPUP_CANCEL, popup_leave),
        (HOME, POPUP_GOOD, popup),
    ]


BENIGN.extend([
    ("AH5 调用方执行时复核（底层仍是 abd347c 无条件 to；页面仍在 + 半屏轮次 + 被盖住换轮次；弹窗出现标志）", caller_recheck_edits()),
    ("AH5 底层票据集合（不做新取代旧），调用方逐个 cancel", [
        (OVERLAYS, "  private static pending: number = 0;\n", "  private static live: Set<number> = new Set<number>();\n"),
        (OVERLAYS, "    CouliFocusReturn.pending = ticket;\n", "    CouliFocusReturn.live.add(ticket);\n"),
        (OVERLAYS, TICKET_CHECK + "      CouliFocusReturn.pending = 0;\n",
         "      if (!CouliFocusReturn.live.delete(ticket)) {\n        return;\n      }\n"),
        (OVERLAYS, CANCEL_BODY, "    CouliFocusReturn.live.delete(ticket);\n"),
        (OVERLAYS, "    CouliFocusReturn.pending = 0;\n    CouliFocusReturn.send(ui, id);\n  }\n", "    CouliFocusReturn.send(ui, id);\n  }\n"),
    ]),
    ("AH5 底层带执行时复核回调 to(ui, id, valid)，调用方传「页面仍在且轮次没变」", [
        (OVERLAYS, "  static to(ui: UIContext, id: string): number {", "  static to(ui: UIContext, id: string, valid: () => boolean = () => true): number {"),
        (OVERLAYS, TICKET_CHECK, "      if (CouliFocusReturn.pending !== ticket || !valid()) {\n        return;\n      }\n"),
        (SEARCH, CALLER_FIELDS_OLD, CALLER_FIELDS),
        (SEARCH, DETACH_CANCEL, "    };\n  }\n"),
        (SEARCH, COVER_CANCEL, "    if (covered) {\n      this.sheetRound++;\n"),
        (SEARCH, OPEN_CANCEL, "    this.model.sheetOpen = true;\n    this.sheetRound++;\n"),
        (SEARCH, SHEET_OUT, "        this.sheetRound++;\n        const r: number = this.sheetRound;\n"
         "        CouliFocusReturn.to(this.getUIContext(), ID_FILTER_PRICE, () => " + SHEET_LIVE + " && this.sheetRound === r);\n"),
        (SEARCH, "          CouliFocusReturn.cancel(this.sheetFocus);\n" + TITLE_FOCUS,
         "          const r: number = this.sheetRound;\n"
         "          CouliFocusReturn.to(this.getUIContext(), 'search_price_title', () => " + SHEET_LIVE + " && this.sheetRound === r);\n"),
    ]),
    ("AH5 弹窗改在外框组件 onDisAppear 里作废（不写 aboutToDisappear）", [
        (HOME, POPUP_CANCEL, ""),
        (HOME, "    .id('home_popup')\n", "    .id('home_popup')\n    .onDisAppear(() => {\n      CouliFocusReturn.cancel(this.closeFocus);\n    })\n"),
    ]),
])

# 「调用方执行时复核」写法的缺陷变异（底层无条件 to）：（名字，{caller_recheck_edits 的参数}，应报的规则）
CALLER_MUTANTS = [
    ("调用方复核只看页面仍在与覆盖、不看半屏轮次", {"out": CALLER_OUT.replace(CALLER_COND, SHEET_LIVE)}, "AH5-sheet-reopen"),
    ("调用方复核的轮次在回调里现取（永远相等）", {"title":
     CALLER_TITLE.replace("          const round: number = this.sheetRound;\n", "").replace(
         "          setTimeout(() => {\n", "          setTimeout(() => {\n            const round: number = this.sheetRound;\n")}, "AH5-sheet-fastclose"),
    ("调用方复核条件在排队时算好（执行时不再查）", {"out":
     CALLER_OUT.replace("        setTimeout(() => {\n          if (" + CALLER_COND + ") {\n",
                        "        const ok: boolean = " + CALLER_COND + ";\n"
                        "        setTimeout(() => {\n          if (ok) {\n")}, "AH5-sheet-leave"),
    ("调用方复核不看覆盖、被盖住也不换轮次", {"out": CALLER_OUT.replace(" && !this.sheetCovered", ""), "cover": "    if (covered) {\n"},
     "AH5-sheet-cover"),
    ("调用方关闭复核不看覆盖（盖住换了轮次，收起又排新轮次：Codex r2 S2）", {"out": CALLER_OUT.replace(" && !this.sheetCovered", "")},
     "AH5-sheet-cover-open"),
    ("调用方标题复核不看覆盖（迟到的出现回调）", {"title": CALLER_TITLE.replace(" && !this.sheetCovered", "")}, "AH5-sheet-late-appear-cover"),
    ("调用方弹窗收起不清出现标志", {"popup_leave": ""}, "AH5-popup"),
    ("调用方重开不换轮次", {"open_": "    this.model.sheetOpen = true;\n"}, "AH5-sheet-reopen"),
]
for _name, _kw, _want in CALLER_MUTANTS:
    _edits = caller_recheck_edits(**_kw)
    _rel, _old, _new = _edits[0]
    MUTATIONS.append((_name, _rel, _old, _new, _want))
    EXTRA_EDITS[_name] = _edits[1:]

# ---------------------------------------------------------------- v3（Codex r2 S2）：被详情盖住算离页，盖住期间旧 / 新回焦请求都不得发出
COVER_MUTATIONS = [
    ("关闭回焦只看页面仍在、不看覆盖（实现 r2 写法，Codex r2 S2）", SEARCH, SHEET_OUT_IF,
     SHEET_OUT_IF.replace(SHEET_LIVE, "this.config.life.alive"), "AH5-sheet-cover-open"),
    ("setCovered 不记覆盖状态（覆盖判断恒假）", SEARCH, COVERED_SET, "", "AH5-sheet-cover-open"),
    ("覆盖判断整段删掉（字段、记录、关闭与标题的复核都回到 r2）", SEARCH, COVERED_SET, "", "AH5-sheet-cover-open"),
    ("解除覆盖不清覆盖状态（只在 covered 时记）", SEARCH, COVERED_SET,
     "    if (covered) {\n      this.sheetCovered = true;\n    }\n", "AH5-sheet-uncover"),
    ("覆盖状态记反（!covered）", SEARCH, COVERED_SET, "    this.sheetCovered = !covered;\n", "AH5"),
    ("关闭回焦复核写成「或」（alive || !covered）", SEARCH, SHEET_OUT_IF,
     SHEET_OUT_IF.replace(SHEET_LIVE, "this.config.life.alive || !this.sheetCovered"), "AH5-sheet-cover-open"),
    ("标题移焦只看页面仍在、不看覆盖", SEARCH, TITLE_GUARD, TITLE_GUARD.replace(" || this.sheetCovered", ""), "AH5-sheet-late-appear-cover"),
    ("标题移焦只看覆盖、不看页面仍在", SEARCH, TITLE_GUARD, TITLE_GUARD.replace("!this.config.life.alive || ", ""),
     "AH5-sheet-late-appear-leave"),
    ("标题移焦不复核（实现 r2 写法）", SEARCH, TITLE_GUARD, "", "AH5-sheet-late-appear"),
]
EXTRA_EDITS["覆盖判断整段删掉（字段、记录、关闭与标题的复核都回到 r2）"] = [
    (SEARCH, COVERED_FIELD, ""),
    (SEARCH, SHEET_OUT_IF, SHEET_OUT_IF.replace(SHEET_LIVE, "this.config.life.alive")),
    (SEARCH, TITLE_GUARD, ""),
]
MUTATIONS.extend(COVER_MUTATIONS)
MUTATIONS.extend(STALE_MUTATIONS)


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
    """参照件 + 仓库契约快照（契约是生成物、不进参照件）。"""
    root = os.path.join(tmp, name)
    shutil.copytree(GOOD, root)
    os.makedirs(os.path.dirname(os.path.join(root, CONTRACT)), exist_ok=True)
    shutil.copyfile(os.path.join(REPO_ROOT, CONTRACT), os.path.join(root, CONTRACT))
    # AH5 按 designsystem Index.ets 找 CouliFocusReturn 的源文件（参照件只带 Overlays.ets）
    if not os.path.exists(os.path.join(root, DS_INDEX)):
        shutil.copyfile(os.path.join(REPO_ROOT, DS_INDEX), os.path.join(root, DS_INDEX))
    return root


INT_SUITE = ("import { describe } from '@ohos/hypium';\nimport { " + SEG_FN + " } from './A11yHomeSearchSeg';\n\n"
             "export default function hmA11yUiTest() {\n  describe('HmA11yUi', () => {\n    // FU-HM-A11Y-HOME-SEARCH\n    "
             + SEG_FN + "();\n  });\n}\n")
INT_IMPORT = "import hmA11yUiTest from './HmA11yUi.test';\n"
INT_CALL = "  hmA11yUiTest();\n"
TESTSUITE = "export default function testsuite() {\n"


def _registration_base():
    """登记自测底本：本仓库真实的 verify.sh、core List / 逻辑单测、entry ohosTest 全部 .ets（不是参照件——底本不过即说明真实登记坏了）。"""
    files = {}
    for rel in (VERIFY, CORE_LIST, CORE_TEST):
        text = read(REPO_ROOT, rel)
        if text is None:
            raise Incomplete("%s: 文件不存在，登记自测没有底本" % rel)
        files[rel] = text
    for name in sorted(os.listdir(os.path.join(REPO_ROOT, ENTRY_DIR))):
        if name.endswith(".ets"):
            files[ENTRY_DIR + "/" + name] = read(REPO_ROOT, ENTRY_DIR + "/" + name)
    return files


def _integrated(files):
    """集成形态（HmA11yUi 在、entry List 登记它）：本树没有，按 README ⑪ / COMMON 的写法合成，供 AH6-entry 的登记变异用。"""
    if ENTRY_SUITE in files:
        # HM-BATCH1-FREEZE 集成 3（#24 只换定位）：集成头上 HmA11yUi 与 entry List 登记已真实存在，直接以真实集成形态为底本
        # （再合成会让 entry List 出现两行 import / 两处调用）；下面同一批集成形态变异与良性改写照原样作用在真实文件上。
        return dict(files)
    out = dict(files)
    out[ENTRY_SUITE] = INT_SUITE
    out[ENTRY_LIST] = files[ENTRY_LIST].replace(TESTSUITE, INT_IMPORT + "\n" + TESTSUITE + INT_CALL, 1)
    return out


def _registration_cases(files):
    """[(名, 底本, {rel: 变换}, 期望规则 | 'INCOMPLETE' | None=良性)]。"""
    vs = files[VERIFY]

    def line_of(prefix):
        hits = [line for line in vs.split("\n") if line.startswith(prefix)]
        if len(hits) != 1:
            raise Incomplete("登记自测：verify.sh 里以「%s」开头的行应恰 1 行，实际 %d 行" % (prefix, len(hits)))
        return hits[0] + "\n"

    start = vs.find('step "%s"\n' % HOST_STEP)
    rec = vs.find('record "%s" PASS ' % HOST_STEP)
    if start < 0 or rec < 0:
        raise Incomplete("登记自测：真实 verify.sh 里找不到宿主步（step / record），没有底本可变异")
    block = vs[start:vs.index("\n", rec) + 1]
    body = line_of(HOST_CMDS[1] + " ||")
    selft = line_of(HOST_CMDS[0] + " ||")
    after_fast = 'build_config Release default release "凑狸"\n'
    core_import = "import a11yHomeNoticeTest from './A11yHomeNotice.test';\n"
    core_call = "  a11yHomeNoticeTest();\n"
    core_note = [line + "\n" for line in files[CORE_LIST].split("\n") if line.startswith("  // FU-HM-A11Y-HOME-SEARCH")]
    seg_call = "    " + SEG_FN + "();\n"

    def sub(old, new):
        return lambda s: s.replace(old, new, 1) if s.count(old) == 1 else None

    def drop(old):
        return sub(old, "")

    def V(fn):
        return {VERIFY: fn}

    def C(fn):
        return {CORE_LIST: fn}

    base, integ = files, _integrated(files)
    return [
        # ---- verify.sh：复核 M1 / M3 及同类
        ("摘宿主步整段（复核 M1）", base, V(drop(block)), "AH6-step"),
        ("只摘本体行（复核 M3）", base, V(drop(body)), "AH6-cmd"),
        ("摘自测行", base, V(drop(selft)), "AH6-cmd"),
        ("摘逻辑自测行", base, V(drop(line_of(HOST_CMDS[2] + " ||"))), "AH6-cmd"),
        ("摘逻辑行", base, V(drop(line_of(HOST_CMDS[3] + " ||"))), "AH6-cmd"),
        ("摘 ArkTS 参照行", base, V(drop(line_of(HOST_CMDS[4] + " ||"))), "AH6-cmd"),
        ("摘 ArkTS 真实产品行", base, V(drop(line_of(HOST_CMDS[5] + " ||"))), "AH6-cmd"),
        ("本体行注释掉", base, V(sub(body, "# " + body)), "AH6-cmd"),
        ("本体行改 || true", base, V(sub(body, HOST_CMDS[1] + " || true\n")), "AH6-chain"),
        ("本体行 fail_fast 后挂 || true", base, V(sub(body, body.rstrip("\n") + " || true\n")), "AH6-chain"),
        ("本体行挪进 if false", base, V(sub(body, "if false; then\n" + body + "fi\n")), "AH6-cmd"),
        ("本体行挪进函数", base, V(sub(body, "a11yhome_host() {\n" + body + "}\n")), "AH6-cmd"),
        ("本体行改参数 --help", base, V(sub(body, body.replace('.py" ||', '.py" --help ||'))), "AH6-cmd"),
        ("自测与本体两行对调", base, V(sub(selft + body, body + selft)), "AH6-chain"),
        ("整步挪到 --fast 早退之后", base, V(lambda s: drop(block)(s) and sub(after_fast, after_fast + block)(drop(block)(s))), "AH6-fast"),
        ("步前插顶层 exit 0", base, V(sub('step "%s"\n' % HOST_STEP, 'exit 0\nstep "%s"\n' % HOST_STEP)), "AH6-fast"),
        ("record 改 FAIL", base, V(sub('record "%s" PASS ' % HOST_STEP, 'record "%s" FAIL ' % HOST_STEP)), "AH6-step"),
        ("步名改掉", base, V(sub('step "%s"\n' % HOST_STEP, 'step "A11Y-HOME 宿主检查"\n')), "AH6-step"),
        ("整步重复一份", base, V(sub(block, block + block)), "AH6-step"),
        ("verify 块没闭合（fail-closed）", base, V(sub(FAST_EXIT + "\n", FAST_EXIT + "\nif true; then\n")), "INCOMPLETE"),
        # ---- core List.test.ets：复核 M2 及同类
        ("删 core List 登记（import + 注释 + 调用，复核 M2）", base,
         C(lambda s: s.replace(core_import, "", 1).replace("".join(core_note) + core_call, "", 1)
           if len(core_note) == 1 and s.count(core_import) == 1 and s.count(core_note[0] + core_call) == 1 else None), "AH6-core"),
        ("core 只删调用", base, C(drop(core_call)), "AH6-core"),
        ("core 只删 import", base, C(drop(core_import)), "AH6-core"),
        ("core 调用注释掉", base, C(sub(core_call, "  // a11yHomeNoticeTest();\n")), "AH6-core"),
        ("core 调用包进块注释", base, C(sub(core_call, "  /* a11yHomeNoticeTest(); */\n")), "AH6-core"),
        ("core 调用挪进 if (false)", base, C(sub(core_call, "  if (false) {\n  " + core_call + "  }\n")), "AH6-core"),
        ("core 调用挪到别的函数", base, C(lambda s: drop(core_call)(s) and drop(core_call)(s) + "\nfunction later() {\n" + core_call + "}\n"), "AH6-core"),
        ("core 调用两次", base, C(sub(core_call, core_call + core_call)), "AH6-core"),
        ("core import 路径改错", base, C(sub(core_import, core_import.replace("A11yHomeNotice.test", "A11yHomeNotice"))), "AH6-core"),
        ("core 逻辑单测去掉 export default", base,
         {CORE_TEST: sub("export default function a11yHomeNoticeTest()", "export function a11yHomeNoticeTest()")}, "AH6-core"),
        # ---- entry 设备段（本树待集成形态）
        ("无 HmA11yUi 时 entry List 直接调段函数", base,
         {ENTRY_LIST: sub(TESTSUITE, "import { %s } from './A11yHomeSearchSeg';\n\n%s  %s();\n" % (SEG_FN, TESTSUITE, SEG_FN))}, "AH6-entry"),
        ("段函数改名", base, {ENTRY_SEG: sub("export function %s(): void" % SEG_FN, "export function a11yHomeCases(): void")}, "AH6-entry"),
        # ---- entry 设备段（集成形态，合成 HmA11yUi）
        ("HmA11yUi 删段函数调用", integ, {ENTRY_SUITE: drop(seg_call)}, "AH6-entry"),
        ("段函数调用挪出 describe", integ, {ENTRY_SUITE: lambda s: drop(seg_call)(s).replace("  });\n", "  });\n" + seg_call, 1)}, "AH6-entry"),
        ("段函数调两次", integ, {ENTRY_SUITE: sub(seg_call, seg_call + seg_call)}, "AH6-entry"),
        ("段函数调用注释掉", integ, {ENTRY_SUITE: sub(seg_call, "    // " + SEG_FN + "();\n")}, "AH6-entry"),
        ("HmA11yUi 删段 import", integ, {ENTRY_SUITE: lambda s: s.replace("import { %s } from './A11yHomeSearchSeg';\n" % SEG_FN, "", 1)}, "AH6-entry"),
        ("entry List 删 hmA11yUiTest() 调用", integ, {ENTRY_LIST: drop(INT_CALL)}, "AH6-entry"),
        ("entry List 删 HmA11yUi import", integ, {ENTRY_LIST: drop(INT_IMPORT)}, "AH6-entry"),
        ("集成后 entry List 又直接调段函数", integ,
         {ENTRY_LIST: sub(INT_CALL, INT_CALL + "  %s();\n" % SEG_FN)}, "AH6-entry"),
        ("describe 名改掉（fail-closed）", integ, {ENTRY_SUITE: sub("describe('HmA11yUi'", "describe('HmA11y'")}, "INCOMPLETE"),
        # ---- 良性改写（0 违反）
        ("改 fail_fast 文案", base, V(sub('"a11yhome-host" "见上方违反项"', '"a11yhome-host" "见上方违反项（AH1–AH6）"')), None),
        ("宿主步内加注释与空行", base, V(sub(body, "# 本体\n\n" + body)), None),
        ("core 调用前加注释与空行", base, C(sub(core_call, "\n  // 首页公告关闭名\n" + core_call)), None),
        ("core import 挪到 import 块首", base, C(lambda s: drop(core_import)(s) and core_import + drop(core_import)(s)), None),
        ("集成形态（合成 HmA11yUi + entry List 登记）", integ, {}, None),
        ("集成形态：段函数前后还有别单段", integ,
         {ENTRY_SUITE: sub(seg_call, "    a11yCommonCases();\n" + seg_call + "    a11yFundsCases();\n")}, None),
    ]


def _registration_self_test(tmp, failures):
    """AH6 登记自测：真实登记 0 违反（--self-test 这一行因此也守住本体行 / List 登记）+ 变异全杀 + 良性改写 0 违反。返回 (变异数, 良性数)。"""
    try:
        files = _registration_base()
        cases = _registration_cases(files)
    except Incomplete as e:
        failures.append("登记自测没有底本：%s" % e)
        return 0, 0

    def tree(name, src):
        root = os.path.join(tmp, name)
        for rel, text in src.items():
            path = os.path.join(root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        return root

    try:
        got, notes = registration(tree("r-real", files))
        if got:
            failures.append("真实登记不过（verify 宿主步 / core / entry 登记被改坏）：%s" % [(v["rule"], v["file"], v["line"], v["msg"]) for v in got])
        else:
            print("REAL ok 登记 0 违反%s" % ("；" + "；".join(notes) if notes else ""))
    except Incomplete as e:
        failures.append("真实登记判不了：%s" % e)
    n_mut = n_benign = 0
    for idx, (name, src, edits, want) in enumerate(cases):
        cur = dict(src)
        broken = False
        for rel, fn in edits.items():
            new = fn(cur[rel]) if rel in cur else None
            if new is None or new == cur[rel]:
                failures.append("登记%s「%s」原串没对上（%s）" % ("变异" if want else "良性改写", name, rel))
                broken = True
                break
            cur[rel] = new
        if broken:
            continue
        root = tree("r%02d" % idx, cur)
        try:
            got, _ = registration(root)
            rules = sorted({v["rule"] for v in got})
            outcome = None
        except Incomplete as e:
            got, rules, outcome = None, [], "INCOMPLETE"
        if want is None:
            n_benign += 1
            if outcome or got:
                failures.append("登记良性改写「%s」被误报：%s" % (name, outcome or [(v["rule"], v["msg"]) for v in got]))
            else:
                print("BENIGN ok 登记 %s" % name)
        else:
            n_mut += 1
            if (want == "INCOMPLETE" and outcome == want) or (want != "INCOMPLETE" and want in rules):
                print("KILLED 登记 %s ← %s" % (name, outcome or ", ".join(rules)))
            else:
                failures.append("登记变异「%s」没被 %s 杀（实际 %s）" % (name, want, outcome or rules))
        shutil.rmtree(root)
    return n_mut, n_benign


def self_test():
    failures = []
    with tempfile.TemporaryDirectory(prefix="a11yhome-selftest-") as tmp:
        good = _good_tree(tmp, "good")
        got = check(good)
        if got:
            failures.append("参照件不过：%s" % [(v["rule"], v["file"], v["line"], v["msg"]) for v in got])
        for idx, (name, rel, old, new, want) in enumerate(MUTATIONS):
            root = _good_tree(tmp, "m%02d" % idx)
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
            root = _good_tree(tmp, "b%02d" % idx)
            for rel, old, new in edits:
                _apply(root, rel, old, new, failures, "良性改写「%s」" % name)
            try:
                got = check(root)
            except Incomplete as e:
                failures.append("良性改写「%s」解析不完整：%s" % (name, e))
                continue
            if got:
                failures.append("良性改写「%s」被误报：%s" % (name, [(v["rule"], v["msg"]) for v in got]))
            else:
                print("BENIGN ok %s" % name)
            shutil.rmtree(root)
        # 语法错误 / 缺文件 / struct 改名 / 契约坏 必须 4（Incomplete），不算断言红
        fail_closed = [
            ("语法错误", lambda r: open(os.path.join(r, SEARCH), "a", encoding="utf-8").write("\nexport struct {\n")),
            ("缺 HomeCards", lambda r: os.remove(os.path.join(r, HOME))),
            ("缺草稿表", lambda r: os.remove(os.path.join(r, DRAFT))),
            ("struct 改名", lambda r: _apply(r, HOME, "export struct HomeNoticeCard {", "export struct HomeNoticeBar {", failures, "struct 改名")),
            ("契约 JSON 坏", lambda r: open(os.path.join(r, CONTRACT), "w", encoding="utf-8").write("{")),
            ("缺 Overlays.ets（AH5 找不到 CouliFocusReturn 源文件）", lambda r: os.remove(os.path.join(r, OVERLAYS))),
            ("bindSheet 选项改成变量（AH5 模拟不了）", lambda r: _apply(r, SEARCH, ".bindSheet(this.model.sheetOpen, this.priceSheet(), {",
                                                                     ".bindSheet(this.model.sheetOpen, this.priceSheet(), this.sheetOptions(), {",
                                                                     failures, "bindSheet 选项")),
        ]
        for idx, (name, act) in enumerate(fail_closed):
            root = _good_tree(tmp, "f%02d" % idx)
            act(root)
            try:
                check(root)
                failures.append("%s 应该按 Incomplete 退出，却正常返回" % name)
            except Incomplete:
                pass
        reg_mut, reg_benign = _registration_self_test(tmp, failures)
    total = len(MUTATIONS) + len(BENIGN) + 8 + 1 + reg_mut + reg_benign
    if failures:
        for f in failures:
            print("SELFTEST FAIL: %s" % f)
        print("A11YHOME_SELFTEST 失败 %d / %d" % (len(failures), total))
        return 1
    print("A11YHOME_SELFTEST 通过：参照件 1 + 变异 %d 全杀 + 良性改写 %d 全绿 + 语法错误 / 缺文件 ×2 / 缺 struct / 契约坏 / 缺 Overlays / "
          "半屏选项不可模拟 fail-closed；AH6 登记：真实登记 0 违反 + 变异 %d 全杀 + 良性改写 %d 全绿"
          % (len(MUTATIONS), len(BENIGN), reg_mut, reg_benign))
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
        root = os.path.abspath(args.root)
        violations = check(root)
        reg, notes = registration(root)
        violations += reg
    except lint.HM10ToolchainError as e:
        print("A11YHOME 工具链不可用：%s" % e)
        return 3
    except Incomplete as e:
        print("A11YHOME 无法保证判定完整：%s" % e)
        return 4
    render(violations)
    for note in notes:
        print("  说明 " + note)
    if violations:
        print("A11YHOME_HOST 失败：%d 处违反" % len(violations))
        return 1
    print("A11YHOME_HOST 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
