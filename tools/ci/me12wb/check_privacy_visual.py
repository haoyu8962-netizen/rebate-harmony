#!/usr/bin/env python3
"""APP-12w-b-harmony（隐私中心 / 关于 / 联系客服半屏视觉）宿主检查（测试作者 v1）。依据 NATIVE/APP-12w/brief-b-harmony.md §2、§2.1、§3、
§4.3、§6（H-P01–H-P16，D10-615 全照推荐）。照 tools/ci/me12wa/check_settings_visual.py 的写法；与 me12v / me12wa 两份守卫共存（它们钉的文件
这里也钉，基线各自独立，不互相改）。只用 Python 3 标准库；不调 git（基线是仓库里的 fixture，其 sha256 钉在本文件里，改 fixture 即红）。

检查项：
  G0 fixture privacy-baseline-8699e5a.json 的 sha256 钉在本文件；从 fixture 抽不到守卫符号也报红
  G1 逻辑与边界文件 sha256 与 REV（8699e5a）一致（§3.1）：Core 执行器 / 纯规则 / 客服出口 / 会话 / JSON、entry 的 AppMe / MePages /
     AppCsSheet / AppMeTexts / AppClipboard、contract.lock、specs/me-vectors.json；整树：core me/**（含 account）、core privacy/**、
     core clipboard/**、entry me/** / privacy/** / clipboard/** / update/**（强更页）/ permission/**、features/me/**（只豁免三视图与新私有件
     PrivacyAboutCsParts.ets；SettingsParts / SettingsView / MeKit 在内；不许新增别的文件）；common/designsystem 清单内 8 项（D10-951 ② 从整树收窄，
     frozen_deps.py 实算；清单外增删改不报）
  G2 只许插入行（REV 的每一行按原顺序仍在）：MeDraftTexts.ets（H-P07 推荐零改动）、staging DebugFakeMe / BuildVariant（H-P15 场景、同意记录计数）
  G3 RootPage.ets：客服半屏 bindSheet(this.cs.shown, …) 的选项对象只多 `maskColor: CouliColors.overlayScrim,` 一行，其余逐字节同 REV（H-P06 / P27）
  G4 三视图守卫区（§3.2，按符号）与 REV 逐字节一致：类、方法（confirmWithdraw / aboutToDisappear / apply 等）、content 分支条件、
     回调体与关键表达式（四个协议去向按行 id 配对、个性化 onToggle、撤回 / 开启完整功能按钮、复制回调、客服四个动作按按钮 id 配对、go_help 键选择、
     ForEach 与键函数、onClose）
  S1–S12 视觉与红线静态规则：私有件在 PrivacyAboutCsParts.ets（@ComponentV2、只收值与 @Event、不读 config / 控制器 / actions、无中文 / 色值字面量、
     不发跳转 / Toast、无注销 / 权限申请）；清单行复用 AgreementSheetRow、个性化用 PrivacySwitchRow（说明进 accessibilityDescription，H-P03）、
     提示条 PrivacyBasicNotice、不再渲染 basic_desc、撤回 / 开启完整功能各一张卡且标题有 TITLE_BAR；视图无 onClick / 手势（说明句不可点、
     无删除入口）、不调 openSystemSettings（H-P16）；关于用 AboutAppIcon / AboutCopyButton / MeGroupTitle、名字不再是 title 22、说明居中；
     客服用 CsSheetPanel / CsBadge / CsSafetyStrip / CsHelpLink、无 TEXT 变体、安全句取契约 cs.no_code_notice（H-P07）、中段高按
     CouliSheetPanel.maxHeight（P28）、按钮间 12；新图标用 SymbolGlyph（H-P10）；不新增 Toggle / TextInput / bindSheet / showToast 直用；
     设备用例依赖的 id；staging H-P15 五个场景与同意记录计数键；privacy-visual-vectors.json 与 Android / iOS 逐字节相同（H-P14）
  C1–C3 设备名单三处一致、describe 名；verify 主步排除 Me12wbUi、第八个 entry 设备步 entry-me12wb、本宿主步四条命令；check_device_result /
     device-test 认 me12wb；core / entry 两个 List 登记（entry 在 hm07vHomeUiTest 之前）

用法：
  check_privacy_visual.py               本仓库
  check_privacy_visual.py --self-test   层一：参考桩树（逻辑文件为合成件、基线随之合成；三视图用 REV 原文按 §3.2「允许改」打补丁成参考实现）
                                        全过 + 每种错误实现各自打红（定位串必须恰好一次）；层二：本仓库检查通过时把真实文件拷出再逐个变异
                                        （未通过时跳过并说明）
"""
import hashlib
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REV = '8699e5a'
FIXTURE = 'tools/ci/me12wb/fixtures/privacy-baseline-' + REV + '.json'
# fixture 指纹（NATIVE/APP-12w/tests-b-harmony-v1-aux/make_baseline_b.py 由 git show REV 生成；改 fixture 来迁就实现即红）。
FIXTURE_SHA256 = 'cf0fd2d83ff99c8947c8ba7ac00a06b181fbea1067cd4549dce792a489bd2b17'

ME = 'features/me/src/main/ets/'
V_PRIVACY = ME + 'PrivacyCenterView.ets'
V_ABOUT = ME + 'AboutView.ets'
V_CS = ME + 'CsSheetView.ets'
PARTS = ME + 'PrivacyAboutCsParts.ets'
ROOT_PAGE = 'entry/src/main/ets/pages/RootPage.ets'
FAKE_ME = 'entry/src/staging/ets/variant/DebugFakeMe.ets'
VECTORS = 'specs/privacy-visual-vectors.json'
# H-P14：Android 56192eb / iOS f2d2209 的 specs/privacy-visual-vectors.json（两端逐字节相同）。
VECTORS_SHA256 = '9306dfda11365c910dce4829dd7fb7b7e7bb8ee10779093048f7a63826936605'
SKIP_PARTS = {'build', '.test', 'oh_modules', '.hvigor', '.preview', 'node_modules'}
TREE_SKIP = ('src/test/', 'src/ohosTest/')
MASK_LINE = 'maskColor: CouliColors.overlayScrim,'

GUARD = {
    V_PRIVACY: {
        'classes': ['PrivacyCenterConfig', 'PrivacyModel'],
        'methods': ['aboutToAppear', 'aboutToDisappear', 't', 'refresh', 'apply', 'confirmWithdraw', 'basic', 'shows', 'agreement', 'rows',
                    'permissionTitle'],
        # content 的分支条件（整行去缩进后逐字节）。
        'lines': ['if (this.basic() && !this.model.forceUpdate) {', "if (this.shows('personalizationSwitch')) {",
                  "if (this.shows('permissionSection')) {", "if (this.shows('enableFullButton')) {",
                  "} else if (this.shows('withdrawButton')) {"],
        # 去注释、去空白后必须出现的次数（None = 至少一次）。
        'calls': {
            'this.config.controller.setPersonalization(target, this.config.controller.identity);': 1,
            'onToggle: (target: boolean) => {': 1,
            'on: this.model.personalizationOn,': 1,
            'disabled: this.model.withdrawing,': 2,
            'loading: this.model.withdrawing,': 1,
            "rowId: 'privacy_personalization',": 1,
            "spoken: switchSpoken(this.config.texts, this.t('privacy_center.personalization'), this.model.personalizationOn),": 1,
            "desc: this.t('privacy_center.personalization_desc'),": 1,
            'this.confirmWithdraw()': 2,
            'this.config.enableFull()': 1,
            "(row: MeRecord) => (row['type'] as string) + '_' + (row['statusKey'] as string))": 1,
            "this.t('privacy.basic_mode.notice')": 1,
        },
        # 字面量 → 所在组件调用里必须有的表达式（行 id 与去向 / 动作配对）。
        'owners': [
            ("'privacy_collect_list'", ["this.agreement('privacy')", "this.t('privacy_center.collect_list')"]),
            ("'privacy_share_list'", ["this.agreement('sdk_list')", "this.t('privacy_center.share_list')"]),
            ("'privacy_policy'", ["this.agreement('privacy')", "this.t('privacy_center.privacy_policy')"]),
            ("'privacy_agreement'", ["this.agreement('agreement')", "this.t('privacy_center.agreement')"]),
            ("'privacy_withdraw'", ['CouliButton', "text: this.t('privacy_center.withdraw'),", 'variant: CouliButtonVariant.SECONDARY,',
                                    'fullWidth: true,', 'loading: this.model.withdrawing,', 'disabled: this.model.withdrawing,',
                                    'onTap: () => this.confirmWithdraw()']),
            ("'privacy_enable_full'", ['CouliButton', "text: this.t('privacy.basic_mode.enable'),", 'fullWidth: true,',
                                       'onTap: () => this.config.enableFull()']),
        ],
        # 四个协议去向的顺序（收集清单、共享清单、隐私政策、用户协议）。
        'agreement_order': ['privacy', 'sdk_list', 'privacy', 'agreement'],
        'row_order': ["'privacy_collect_list'", "'privacy_share_list'", "'privacy_policy'", "'privacy_agreement'"],
    },
    V_ABOUT: {
        'classes': ['AboutConfig'],
        'methods': ['aboutToAppear', 't', 'versionText'],
        'lines': ['if (this.filing !== null) {'],
        'calls': {
            "const ui: UIContext = this.getUIContext(); this.config.copyDiagnostics().then((ok: boolean): void => {"
            " CouliToast.show(ui, this.t(ok ? 'about.copy_diagnostics.done' : 'me.copy_failed')); });": 1,
            'this.config.copyDiagnostics()': 1,
            "Text(this.filing ?? '')": 1,
            'Text(this.versionText())': 1,
            "'about_copy_diagnostics'": 1,
            "'about_version'": 1,
            "'about_filing_text'": 1,
        },
        'owners': [],
    },
    V_CS: {
        'classes': ['CsSheetActions'],
        'methods': ['t', 'sheet', 'buttons', 'title', 'body'],
        'lines': ["if (name === 'open_wechat') {", "} else if (name === 'retry') {", "} else if (name === 'copy_link') {"],
        'calls': {
            'onTap: () => this.actions.openWechat()': 2,
            'onTap: () => this.actions.copyLink()': 1,
            'onTap: () => this.actions.goHelp()': None,
            'onClose: () => this.actions.close()': 1,
            'ForEach(this.buttons(), (name: string, index: number) => {': 1,
            'this.buttonFor(name, index === 0)': 1,
            "(name: string) => this.sheet() + '_' + name)": 1,
            'this.body()': 1,
            'this.title()': 1,
            "this.t('me.close')": 1,
            "'cs_sheet_title'": 1,
            "'cs_body'": 1,
            "'cs_safety'": 1,
        },
        'owners': [
            ("'cs_open_wechat'", ["this.t('cs.open_wechat')", 'onTap: () => this.actions.openWechat()']),
            ("'cs_retry'", ["this.t('cs.retry')", 'onTap: () => this.actions.openWechat()']),
            ("'cs_copy_link'", ["this.t('cs.copy_link')", 'variant: first ? CouliButtonVariant.PRIMARY : CouliButtonVariant.SECONDARY,',
                                'onTap: () => this.actions.copyLink()']),
            ("'cs_go_help'", ["this.t(this.sheet() === CsEntryDecision.HANDOFF ? 'cs.handoff.go_help' : 'cs.go_help')",
                              'onTap: () => this.actions.goHelp()']),
        ],
    },
}
# buttonFor 的三个分支条件须按此顺序出现在 buttonFor 里（第四支 else = go_help）。
CS_BRANCH_ORDER = ["if (name === 'open_wechat') {", "} else if (name === 'retry') {", "} else if (name === 'copy_link') {"]
PARTS_STRUCTS = ['PrivacySwitchRow', 'PrivacyBasicNotice', 'AboutAppIcon', 'AboutCopyButton', 'CsSheetPanel', 'CsBadge', 'CsSafetyStrip',
                 'CsHelpLink']
# 私有件不得读 / 调的（只收渲染时的值与 @Event，§3.2）。
PARTS_FORBIDDEN = ['config', 'controller', 'Controller', 'actions', 'AppMe', 'AppCsSheet', 'AppPrivacy', 'CouliToast', 'showToast',
                   'Router', 'openInApp', 'DeleteAccount', 'requestPermission', 'PermissionRequester', 'setPersonalization',
                   'withdraw(', 'copyDiagnostics', 'this.model', 'Config', "from './PrivacyCenterView'", "from './AboutView'",
                   "from './CsSheetView'"]
# 三视图与私有件都不得出现（红线：无删除入口、只查不申请；H-P16 系统设置未接线不在本单改）。
RED_FORBIDDEN = ['DeleteAccount', 'requestPermission', 'PermissionRequester', 'requestPermissionsFromUser']
NEW_DIRECT = {'Toggle(': 0, 'TextInput(': 0, '.bindSheet(': 0, 'showToast(': 0}
DEVICE_IDS = {
    V_PRIVACY: ['privacy_scroll', 'privacy_lists_card', 'privacy_personalization_card', 'privacy_withdraw_card', 'privacy_withdraw_title',
                'privacy_withdraw_desc', 'privacy_enable_full_card', 'privacy_enable_full_title', 'privacy_basic_notice',
                'privacy_system_permissions'],
    V_ABOUT: ['about_scroll', 'about_app_icon', 'about_app_name', 'about_filing_title', 'about_filing_card', 'about_copy_desc'],
    V_CS: ['cs_sheet_panel', 'cs_badge', 'cs_sheet_close'],
}
PARTS_IDS = ["'_knob_'", "'_icon'"]
STAGING_SCENES = ["'about_filed'", "'about_unfiled'", "'cs_no_kf'", "'cs_http'", "'consent_fail'"]
STAGING_COUNTERS = ["'me.consents_count'", "'me.consents_last_type'"]
SUITE = 'entry/src/ohosTest/ets/test/Me12wbUi.test.ets'
CASES = 'tools/ci/me12wb/fixtures/device-cases.txt'


# ---------------------------------------------------------------- 读取与抽取

def read(root, rel):
    p = root / rel
    return p.read_text(encoding='utf-8') if p.is_file() else ''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def line_key(line):
    return sha(line.encode('utf-8'))[:16]


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'(?m)(^|[^:])//.*$', r'\1', text)


def squash(text):
    return re.sub(r'\s+', '', text)


def skipped(rel):
    parts = rel.split('/')
    return any(p in SKIP_PARTS for p in parts) or any(s in rel for s in TREE_SKIP)


def match_close(text, start, open_ch='{', close_ch='}'):
    """text[start] 是 open_ch；返回配对 close_ch 的下标（跳过字符串与行注释）。找不到为 -1。"""
    depth = 0
    i = start
    quote = None
    while i < len(text):
        c = text[i]
        if quote:
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in '\'"`':
            quote = c
        elif text.startswith('//', i):
            nl = text.find('\n', i)
            i = len(text) if nl < 0 else nl
            continue
        elif c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def class_text(text, name):
    m = re.search(r'(?m)^(?:export\s+)?class\s+' + name + r'\b[^{]*\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else text[m.start():end + 1]


def method_text(text, name):
    m = re.search(r'(?m)^[ \t]*(?:(?:private|public|protected|static|async)\s+)*' + re.escape(name) +
                  r'\s*\([^)]*\)\s*(?::\s*[^{;]+)?\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else text[m.start():end + 1]


def struct_text(text, name):
    m = re.search(r'(?m)^(?:export\s+)?struct\s+' + name + r'\b[^{]*\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else text[m.start():end + 1]


def guard_symbols(view, spec):
    out = {}
    for name in spec['classes']:
        out['class.' + name] = class_text(view, name)
    for name in spec['methods']:
        out['method.' + name] = method_text(view, name)
    return out


def owner_chunk(src, at):
    """下标 at 处字面量所在的组件调用（往前找最近的「大写开头名字({」，到配对的「)」）：(组件名, 调用全文)；找不到为 (None, '')。"""
    best = None
    for m in re.finditer(r'\b([A-Z]\w*)\s*\(\s*\{', src[:at]):
        end = match_close(src, m.end() - 2, '(', ')')
        if end > at:
            best = (m.group(1), src[m.start():end + 1])
    return best if best else (None, '')


def literal_owners(src, literal):
    return [owner_chunk(src, m.start()) for m in re.finditer(re.escape(literal), src)]


def load_fixture(root):
    p = root / FIXTURE
    if not p.is_file():
        return None, 'G0 fixture 缺失 ' + FIXTURE
    data = p.read_bytes()
    if sha(data) != FIXTURE_SHA256:
        return None, 'G0 fixture 被改 ' + FIXTURE + '（sha256 ' + sha(data)[:12] + ' ≠ 钉住的 ' + FIXTURE_SHA256[:12] + '）'
    return json.loads(data.decode('utf-8')), None


# ---------------------------------------------------------------- 检查

def check_logic(root, base):
    v = []
    for want, rel in base['strict']:
        p = root / rel
        if not p.is_file():
            v.append('G1 逻辑文件缺失 ' + rel)
        elif sha(p.read_bytes()) != want:
            v.append('G1 逻辑 / 边界文件被改 ' + rel + '（§3.1 合入前后 sha256 必须一致）')
    tree = {rel: s for s, rel in base['tree']}
    exempt = set(base['tree_exempt']) | set(base['append_only'].keys()) | {rel for _, rel in base['strict']}
    for top in base['trees']:
        base_dir = root / top
        now = {}
        if base_dir.is_dir():
            for p in base_dir.rglob('*'):
                rel = p.relative_to(root).as_posix()
                if p.is_file() and not skipped(rel) and rel not in exempt:
                    now[rel] = sha(p.read_bytes())
        want = {rel: s for rel, s in tree.items() if rel.startswith(top + '/')}
        for rel in sorted(set(want) | set(now)):
            if want.get(rel) != now.get(rel):
                kind = '新增' if rel not in want else ('删除' if rel not in now else '改动')
                hint = {'features/me': '（H-P01：私有件只放 PrivacyAboutCsParts.ets，MeKit / SettingsParts 等不动）'}.get(top, '（§3.1 逻辑零改动）')
                v.append('G1 ' + top + ' 有' + kind + '：' + rel + hint)
    # FU-HM-G1-SYSTEM-CONTROLS（D10-951 ② / #24）：designsystem（me12wa 另有 staging）不再整树冻结，只守 fixture tree 里不属于任何整树的清单文件（frozen_deps.py 实算）；清单外增删改不报。
    covered = tuple(t + '/' for t in base['trees'])
    for rel, want_sha in sorted(tree.items()):
        if rel.startswith(covered):
            continue
        p = root / rel
        if not p.is_file():
            v.append('G1 清单内文件被删：' + rel)
        elif sha(p.read_bytes()) != want_sha:
            v.append('G1 清单内文件被改：' + rel)
    for rel, keys in sorted(base['append_only'].items()):
        now = [line_key(l) for l in read(root, rel).split('\n')]
        i = 0
        for k in now:
            if i < len(keys) and k == keys[i]:
                i += 1
        if i < len(keys):
            v.append('G2 ' + rel + ' 只许插入行：' + REV + ' 的第 %d 行被改 / 删 / 挪位' % (i + 1))
    return v


def cs_sheet_options(text):
    """RootPage 里 .bindSheet(this.cs.shown, this.csSheet(), {…}) 的选项对象（含花括号）在全文里的 [起, 止]；找不到为 None。"""
    m = re.search(r'\.bindSheet\(\s*this\.cs\.shown\s*,\s*this\.csSheet\(\)\s*,\s*\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else (m.end() - 1, end + 1)


def check_root_page(root, base):
    now = read(root, ROOT_PAGE)
    span = cs_sheet_options(now)
    if span is None:
        return ['G3 RootPage 找不到客服半屏 .bindSheet(this.cs.shown, this.csSheet(), {…})']
    opts = now[span[0]:span[1]]
    lines = opts.split('\n')
    hits = [i for i, l in enumerate(lines) if l.strip() == MASK_LINE]
    v = []
    if len(hits) != 1:
        v.append('G3 客服半屏 bindSheet 选项须恰好一行 `' + MASK_LINE + '`（H-P06 / P27，旧为系统遮罩），现 %d 行' % len(hits))
    if hits:
        rest = '\n'.join(l for i, l in enumerate(lines) if i != hits[0])
        if now[:span[0]] + rest + now[span[1]:] != base['root_page']:
            v.append('G3 RootPage 除客服半屏 maskColor 一行外有别的改动（§3.1：csSheet() 与文件其余部分逐字节同 ' + REV + '）')
    return v


def check_guard(root, base):
    v = []
    for rel, spec in GUARD.items():
        view = read(root, rel)
        name = rel.rsplit('/', 1)[1]
        if not view:
            v.append('G4 缺 ' + rel)
            continue
        want = guard_symbols(base['views'][rel], spec)
        for sym, text in sorted(want.items()):
            if text is None:
                v.append('G0 fixture 里抽不到守卫符号 ' + name + ' ' + sym + '（抽取规则与基线不符）')
        now = guard_symbols(view, spec)
        for sym, text in sorted(want.items()):
            if text is not None and now.get(sym) != text:
                v.append('G4 ' + name + ' 守卫区被改：' + sym + '（§3.2 与 ' + REV + ' 逐字节一致）')
        flat = [line.strip() for line in view.split('\n')]
        for line in spec['lines']:
            if line not in flat:
                v.append('G4 ' + name + ' 分支条件被改（缺这一行：' + line + '）')
        clean = strip_comments(view)
        body = squash(clean)
        for call, n in spec['calls'].items():
            got = body.count(squash(call))
            if (n is None and got < 1) or (n is not None and got != n):
                v.append('G4 ' + name + ' 回调体 / 关键表达式被改或挪出视图：' + call + '（应 ' + ('≥1' if n is None else str(n)) +
                         ' 处，现 %d 处）' % got)
        for literal, needs in spec['owners']:
            # 只看挂在组件调用里的那几处（如 confirmWithdraw 的 returnFocusId = 'privacy_withdraw' 不是控件）。
            owners = [o for o in literal_owners(clean, literal) if o[0] is not None]
            if not owners:
                v.append('G4 ' + name + ' 缺挂在控件上的 ' + literal)
            for comp, chunk in owners:
                flat_chunk = squash(chunk)
                for need in needs:
                    if need == 'CouliButton':
                        if comp != 'CouliButton':
                            v.append('G4 ' + name + ' ' + literal + ' 应仍挂在 CouliButton 上（§3.2 逐字原样），现在 ' + str(comp))
                    elif squash(need) not in flat_chunk:
                        v.append('G4 ' + name + ' ' + literal + ' 所在控件缺 ' + need + '（去向 / 动作与 id 配对被改）')
        if 'agreement_order' in spec:
            got = re.findall(r"this\.agreement\('([a-z_]+)'\)", clean)
            if got != spec['agreement_order']:
                v.append('G4 PrivacyCenterView 四个协议去向被改：' + str(got) + '（应 ' + str(spec['agreement_order']) + '，G21）')
            at = [clean.find(x) for x in spec['row_order']]
            if any(i < 0 for i in at) or at != sorted(at) or any(clean.count(x) != 1 for x in spec['row_order']):
                v.append('G4 PrivacyCenterView 四行 id 须各一处、顺序为 收集 / 共享 / 隐私政策 / 用户协议')
    cs = strip_comments(read(root, V_CS))
    bf = method_text(cs, 'buttonFor') or ''
    at = [bf.find(x) for x in CS_BRANCH_ORDER]
    if any(i < 0 for i in at) or at != sorted(at):
        v.append('G4 CsSheetView buttonFor 的三个分支条件须按 open_wechat / retry / copy_link 顺序（第四支为 go_help）')
    return v


def check_static(root):
    v = []
    pc = strip_comments(read(root, V_PRIVACY))
    ab = strip_comments(read(root, V_ABOUT))
    cs = strip_comments(read(root, V_CS))
    parts = strip_comments(read(root, PARTS))
    views = pc + '\n' + ab + '\n' + cs
    everything = views + '\n' + parts
    # S1 私有件（H-P01）：新文件、@ComponentV2、八个私有件、只收值与 @Event、无中文 / 色值字面量。
    if not parts:
        v.append('S1 缺 ' + PARTS + '（H-P01：本组私有件放新文件，MeKit / DS 一字不动）')
    else:
        if '@ComponentV2' not in parts:
            v.append('S1 PrivacyAboutCsParts 私有件须是 @ComponentV2（状态管理只用 V2）')
        for s in PARTS_STRUCTS:
            if not re.search(r'\bstruct\s+' + s + r'\b', parts):
                v.append('S1 PrivacyAboutCsParts 里没有 ' + s)
        for bad in PARTS_FORBIDDEN:
            if bad in parts:
                v.append('S1 私有件读 / 调了 ' + bad + '（只收渲染时的值与 @Event 回调，§3.2）')
        if re.search(r"'[^'\n]*[一-鿿][^'\n]*'", parts) or re.search(r'"[^"\n]*[一-鿿][^"\n]*"', parts):
            v.append('S1 私有件写了中文字面量（HM-LINT-1：文案经字典取键，由页面传入）')
        if re.search(r"#[0-9A-Fa-f]{6,8}\b|\brgba?\(|Color\.(?!Transparent\b)[A-Z]\w*", parts):
            v.append('S1 私有件写了色值字面量（颜色一律取 CouliColors 令牌）')
    # S2 隐私中心：清单行复用 AgreementSheetRow（48 / 节距 49，H-P02）、个性化 PrivacySwitchRow、提示条 PrivacyBasicNotice。
    if pc.count('AgreementSheetRow(') != 4 or 'MeRow(' in pc:
        v.append('S2 隐私中心清单四行应复用 SettingsParts.AgreementSheetRow（P2 / H-P02：48vp），现 AgreementSheetRow %d 处、MeRow %d 处'
                 % (pc.count('AgreementSheetRow('), pc.count('MeRow(')))
    if pc.count('PrivacySwitchRow(') != 1 or 'MeSwitchRow(' in pc:
        v.append('S2 个性化开关应是私有 PrivacySwitchRow（H-P03：说明进读屏），不再是 MeSwitchRow')
    switch = struct_text(parts, 'PrivacySwitchRow') or ''
    for need, what in [('accessibilityDescription(', '说明进 accessibilityDescription（H-P03）'),
                       ('AccessibilityRoleType.SWITCH', '整行 SWITCH 角色'), ('accessibilityChecked(', '读屏状态'), ("'_knob_'", '开关视觉 id')]:
        if need not in switch:
            v.append('S2 PrivacySwitchRow 缺 ' + need + '（' + what + '）')
    if pc.count('PrivacyBasicNotice(') != 1 or 'MeNoticeBar(' in pc:
        v.append('S2 基本模式提示条应是私有 PrivacyBasicNotice（P8：info 20、14/400），不再是 MeNoticeBar')
    # S3 基本模式卡去副句（P7 / G-P08）；撤回 / 开启完整功能各一张卡、标题读屏为标题（P6 / P7）。
    if 'privacy_center.basic_desc' in pc:
        v.append('S3 v2 画板去掉了「开启完整功能」副句（G-P08），不再渲染 privacy_center.basic_desc')
    if pc.count('MeCard(') < 5:
        v.append('S3 撤回同意 / 开启完整功能应各在一张白卡里（P6 / P7），MeCard 现 %d 处（清单、个性化、权限条目之外还缺）' % pc.count('MeCard('))
    for chunk_name in ['withdrawSection', 'enableFullSection']:
        if 'AccessibilityRoleType.TITLE_BAR' not in (method_text(pc, chunk_name) or ''):
            v.append('S3 ' + chunk_name + ' 的标题要读作标题（TITLE_BAR，P6 / P7）')
    # S4 红线：视图里没有 onClick / 手势（说明句不可点、点击只经组件 onTap）；无注销入口、不申请权限；不调 openSystemSettings（H-P16）。
    for token in ['.onClick(', '.gesture(', 'TapGesture', '.bindPopup(']:
        if token in views:
            v.append('S4 视图里出现 ' + token + '（红线：说明句 / 正文不可点，点击只经组件 onTap）')
    for bad in RED_FORBIDDEN:
        if bad in everything:
            v.append('S4 出现 ' + bad + '（红线：隐私中心无删除入口、系统权限只查不申请）')
    if squash('this.config.openSystemSettings(') in squash(pc):
        v.append('S4 隐私中心调了 openSystemSettings（H-P16：本单不改行为，鸿蒙无条目）')
    wd = method_text(pc, 'withdrawSection') or ''
    if "this.t('privacy_center.withdraw_desc')" not in wd:
        v.append('S4 撤回说明句应仍是 withdrawSection 里的纯 Text（privacy_center.withdraw_desc）')
    # S5 关于：AboutAppIcon（80，H-P08）/ AboutCopyButton（带图标，H-P09）/ MeGroupTitle（公示分组名在卡外，P16）；名字 17（P14）；说明居中。
    if ab.count('AboutAppIcon(') != 1 or ".substring(0, 1)" in ab:
        v.append('S5 关于页图标应是私有 AboutAppIcon（P13 / H-P08），不再是「凑」字文字块')
    if ab.count('AboutCopyButton(') != 1:
        v.append('S5 复制诊断信息应是私有 AboutCopyButton（带复制图标，P17 / H-P09）')
    for comp, _ in literal_owners(ab, "'about_copy_diagnostics'"):
        if comp == 'CouliButton':
            v.append('S5 about_copy_diagnostics 仍挂在 CouliButton 上（DS 无图标参数，H-P09）')
    if 'CouliTypography.title' in ab:
        v.append('S5 关于页名字仍是 title 22（P14：body 17/600）')
    if 'MeGroupTitle(' not in ab:
        v.append('S5 AI 公示分组名应在卡外（MeGroupTitle，P16）')
    m = re.search(r"'about_app_name'", ab)
    if not m or 'TITLE_BAR' not in ab[max(0, m.start() - 400):m.end() + 400]:
        v.append('S5 关于页名字要读作标题（about_app_name 附近 TITLE_BAR，P14）')
    m = re.search(r"'about_copy_desc'", ab)
    if not m or 'TextAlign.Center' not in ab[max(0, m.start() - 400):m.end() + 400]:
        v.append('S5 复制说明句要居中（about_copy_desc 附近 TextAlign.Center，P17）')
    # S6 客服：私有面板 / 图标块 / 安全条 / 链接；无 TEXT 变体；安全句契约键；中段高按系统半屏最大高；按钮纵向 12。
    for comp in ['CsSheetPanel(', 'CsBadge(', 'CsSafetyStrip(', 'CsHelpLink(']:
        if comp not in cs:
            v.append('S6 客服半屏缺 ' + comp + '（P20–P24 私有件）')
    if 'MeSheetPanel(' in cs:
        v.append('S6 客服半屏仍是 MeSheetPanel（标题靠左、无图标块；P20 私有 CsSheetPanel）')
    if 'CouliButtonVariant.TEXT' in cs:
        v.append('S6 「去帮助中心」仍有 TEXT 变体（P24：打不开为文字链接、其余为次按钮）')
    if "'cs.no_code_notice'" not in cs or "'cs.safety'" in cs:
        v.append('S6 安全句应取契约键 cs.no_code_notice（H-P07），不再用草稿 cs.safety')
    if 'CouliSheetPanel.maxHeight(' not in cs:
        v.append('S6 中段最大高应按 CouliSheetPanel.maxHeight(…) 算（P28：200% / 短屏正文可滚、按钮固定可见）')
    if 'CouliSpacing.space3' not in (method_text(cs, 'actionsArea') or ''):
        v.append('S6 客服按钮列纵向应为 12（space3，G-P06）')
    panel = struct_text(parts, 'CsSheetPanel') or ''
    t_at, b_at = panel.find('TITLE_BAR'), panel.find('Button(')
    if t_at < 0 or b_at < 0 or t_at > b_at:
        v.append('S6 CsSheetPanel 源码顺序须 标题（TITLE_BAR）在关闭按钮之前（adaptation-a11y-spec §8）')
    link = struct_text(parts, 'CsHelpLink') or ''
    if 'minTouchTarget' not in link or 'AccessibilityRoleType.BUTTON' not in link:
        v.append('S6 CsHelpLink 命中 / 语义盒须 ≥ 48（minTouchTarget）且是按钮角色（P24，避开 F-HM-82 小字号命中 45）')
    # S7 新功能图标用 HarmonyOS Symbol（H-P10）。
    if 'SymbolGlyph(' not in parts or "sys.symbol." not in parts:
        v.append("S7 本组新图标（警告 / 消息 / 盾牌 / 复制 / info）应用 SymbolGlyph($r('sys.symbol.*'))（H-P10 / D10-559）")
    # S8 不新增系统控件直用（DS-02 G1 警告不增）。
    for token, limit in NEW_DIRECT.items():
        n = len(re.findall(re.escape(token) if token.startswith('.') else r'(?<!\w)' + re.escape(token), everything))
        if n > limit:
            v.append('S8 ' + token + ' 直用 %d 处（> %d：DS-02 G1）' % (n, limit))
    # S9 设备用例依赖的 id。
    for rel, ids in DEVICE_IDS.items():
        src = strip_comments(read(root, rel)) + '\n' + parts
        for did in ids:
            if "'" + did + "'" not in src:
                v.append('S9 缺设备用例依赖的 id ' + did)
    for did in PARTS_IDS:
        if did not in parts:
            v.append('S9 私有件缺视觉节点 id 后缀 ' + did + '（<id>_knob_on|off、<id>_icon）')
    # S10 staging：H-P15 五个场景与同意记录计数键（只插入行，G2 守）。
    fake = strip_comments(read(root, FAKE_ME))
    for scene in STAGING_SCENES:
        if scene not in fake:
            v.append('S10 DebugFakeMe 缺场景 ' + scene + '（H-P15）')
    for key in STAGING_COUNTERS:
        if key not in fake:
            v.append('S10 DebugFakeMe 缺同意记录计数键 ' + key + '（设备用例按它数 recordConsent，§3.3）')
    # S11 privacy-visual-vectors.json 三端同一份（H-P14）。
    p = root / VECTORS
    if not p.is_file() or sha(p.read_bytes()) != VECTORS_SHA256:
        v.append('S11 ' + VECTORS + ' 与 Android / iOS 不是逐字节同一份（H-P14：鸿蒙差异在测试里映射，不改文件）')
    return v


def check_registration(root):
    v = []
    suite = read(root, SUITE)
    listed = re.findall(r"'(me12wb_\d\d_[a-z0-9_]+)'", suite.split('];')[0]) if suite else []
    its = len(re.findall(r'\bit\(ME12WB_DEVICE_CASES\[\d+\]', suite))
    fixture = [l.strip() for l in read(root, CASES).splitlines() if l.strip() and not l.startswith('#')]
    if not listed or listed != fixture or len(set(listed)) != len(listed) or its != len(listed):
        v.append('C1 设备名单三处不一致（ME12WB_DEVICE_CASES / device-cases.txt / it 数）')
    if "describe('Me12wbUi'" not in suite:
        v.append('C1 describe 名必须是 Me12wbUi（verify 按 class 过滤）')
    verify = read(root, 'tools/ci/verify.sh')
    tails = [line.split()[-3:] for line in verify.splitlines() if line.strip().startswith('run_device_tests entry ')]
    main_ok = any(t[0] == 'entry' and t[2] == 'main' and t[1].startswith('notClass=') and 'Me12wbUi' in t[1].split('=', 1)[1].split(',')
                  for t in tails)
    if not main_ok:
        v.append('C2 verify 主 entry 步必须排除 Me12wbUi')
    if ['entry-me12wb', 'class=Me12wbUi', 'me12wb'] not in tails:
        v.append('C2 verify 缺单独设备步 entry-me12wb class=Me12wbUi me12wb')
    for cmd in ['me12wb/check_privacy_visual.py" --self-test', 'me12wb/check_privacy_visual.py" ||', 'me12wb/run-logic.cjs"',
                'me12wb/check-arkts.cjs" --real']:
        if cmd not in verify:
            v.append('C2 verify 缺 APP-12w-b 宿主检查步命令：' + cmd)
    a, b = verify.find('me12wa/check-arkts.cjs" --real'), verify.find('me12wb/check_privacy_visual.py" --self-test')
    if a < 0 or b < 0 or b < a:
        v.append('C2 APP-12w-b 宿主检查步应排在 me12wa 宿主步之后')
    if 'me12wb/fixtures/device-cases.txt' not in read(root, 'tools/ci/ds02/check_device_result.py'):
        v.append('C2 check_device_result.py 缺 me12wb 名单')
    if not re.search(r'main\|hm07va\|hm07vb\|hm05r\|(?:[a-z0-9]+\|)*me12wb\|(?:[a-z0-9]+\|)*all\)', read(root, 'tools/ci/device-test.sh')):
        v.append('C2 device-test.sh 不认 COULI_HM_DEVICE_SET=me12wb')
    if not re.search(r'^\s*me12wbPrivacyTest\(\);', strip_comments(read(root, 'common/core/src/test/List.test.ets')), flags=re.M):
        v.append('C3 core List.test.ets 未登记 me12wbPrivacyTest()')
    entry_list = strip_comments(read(root, 'entry/src/ohosTest/ets/test/List.test.ets'))
    a, b = entry_list.find('me12wbUiTest();'), entry_list.find('hm07vHomeUiTest();')
    if a < 0 or b < 0 or a > b:
        v.append('C3 entry List.test.ets 须登记 me12wbUiTest()，且在 hm07vHomeUiTest() 之前（HM-07v-a C3 最后注册）')
    return v


def check_source(root, base=None):
    v = []
    if base is None:
        base, err = load_fixture(root)
        if err:
            v.append(err)
    if base is not None:
        v += check_logic(root, base)
        v += check_root_page(root, base)
        v += check_guard(root, base)
    v += check_static(root)
    v += check_registration(root)
    return v


# ---------------------------------------------------------------- 自测：参考实现（REV 原文按 §3.2「允许改」打补丁；只给静态检查用，不可编译）

def replace_method(text, name, new):
    old = method_text(text, name)
    if old is None or text.count(old) != 1:
        raise SystemExit('ME12WB_SELF_TEST_FAIL 参考实现找不到方法 ' + name)
    return text.replace(old, new)


REF_PRIVACY_PATCHES = [
    ("  DraftMeTexts, MeCard, MeKeyValue, MeNoticeBar, MePageFrame, MeRow, MeSwitchRow, MeTexts, switchSpoken\n} from './MeKit';\n",
     "  DraftMeTexts, MeCard, MeKeyValue, MePageFrame, MeTexts, switchSpoken\n} from './MeKit';\nimport { AgreementSheetRow } from './SettingsParts';\n"
     "import { PrivacyBasicNotice, PrivacySwitchRow } from './PrivacyAboutCsParts';\n", 1),
    ("    MeRow({\n      label:", "    AgreementSheetRow({\n      divider: true,\n      text:", 4),
    ("    MeSwitchRow({\n", "    PrivacySwitchRow({\n", 1),
    ("      MeNoticeBar({ text: this.t('privacy.basic_mode.notice'), tone: 'info', barId: 'privacy_basic_notice' })\n",
     "      PrivacyBasicNotice({ text: this.t('privacy.basic_mode.notice'), noticeId: 'privacy_basic_notice' })\n", 1),
    ("    MeCard({\n      content: () => {\n        this.listsCard()", "    MeCard({\n      cardId: 'privacy_lists_card',\n      content: () => {\n"
     "        this.listsCard()", 1),
    ("      MeCard({\n        vertical: CouliSpacing.space1,\n", "      MeCard({\n        cardId: 'privacy_personalization_card',\n"
     "        vertical: CouliSpacing.space1,\n", 1),
]
REF_ENABLE = """  @Builder
  enableFullSection() {
    MeCard({
      cardId: 'privacy_enable_full_card',
      vertical: CouliSpacing.space4,
      content: () => {
        Column({ space: CouliSpacing.space3 }) {
          Text(this.t('privacy_center.basic_title'))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
            .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
            .id('privacy_enable_full_title')
          CouliButton({
            text: this.t('privacy.basic_mode.enable'),
            fullWidth: true,
            buttonId: 'privacy_enable_full',
            onTap: () => this.config.enableFull()
          })
        }
        .width('100%')
      }
    })
  }"""
REF_WITHDRAW = """  @Builder
  withdrawSection() {
    MeCard({
      cardId: 'privacy_withdraw_card',
      vertical: CouliSpacing.space4,
      content: () => {
        Column({ space: CouliSpacing.space3 }) {
          Column({ space: CouliSpacing.space1 }) {
            Text(this.t('privacy_center.withdraw_title'))
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
              .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
              .id('privacy_withdraw_title')
            Text(this.t('privacy_center.withdraw_desc'))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
              .id('privacy_withdraw_desc')
          }
          .alignItems(HorizontalAlign.Start)
          CouliButton({
            text: this.t('privacy_center.withdraw'),
            variant: CouliButtonVariant.SECONDARY,
            fullWidth: true,
            loading: this.model.withdrawing,
            disabled: this.model.withdrawing,
            buttonId: 'privacy_withdraw',
            onTap: () => this.confirmWithdraw()
          })
        }
        .width('100%')
      }
    })
  }"""
REF_ABOUT_IMPORT = ("import { DraftMeTexts, MeCard, MePageFrame, MeTexts } from './MeKit';\n",
                    "import { DraftMeTexts, MeCard, MeGroupTitle, MePageFrame, MeTexts } from './MeKit';\n"
                    "import { AboutAppIcon, AboutCopyButton } from './PrivacyAboutCsParts';\n")
REF_ABOUT_FILING = """  @Builder
  filingCard() {
    Text(this.filing ?? '')
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
      .id('about_filing_text')
  }"""
REF_ABOUT_CONTENT = """  @Builder
  content() {
    Column({ space: CouliSpacing.space4 }) {
      Column({ space: CouliSpacing.space2 }) {
        AboutAppIcon({ iconId: 'about_app_icon' })
        Text(this.t('about.app_name'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          .id('about_app_name')
        Text(this.versionText())
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined, true))
          .id('about_version')
      }
      .width('100%')
      .padding({ top: CouliSpacing.space6, bottom: CouliSpacing.space2 })
      if (this.filing !== null) {
        Column({ space: CouliSpacing.space2 }) {
          MeGroupTitle({ text: this.t('about.filing_title') })
            .id('about_filing_title')
          MeCard({
            cardId: 'about_filing_card',
            vertical: CouliSpacing.space3,
            content: () => {
              this.filingCard()
            }
          })
        }
      }
      Column({ space: CouliSpacing.space2 }) {
        AboutCopyButton({
          text: this.t('about.copy_diagnostics'),
          buttonId: 'about_copy_diagnostics',
          onTap: () => {
            const ui: UIContext = this.getUIContext();
            this.config.copyDiagnostics().then((ok: boolean): void => {
              CouliToast.show(ui, this.t(ok ? 'about.copy_diagnostics.done' : 'me.copy_failed'));
            });
          }
        })
        Text(this.t('about.copy_desc'))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          .textAlign(TextAlign.Center)
          .id('about_copy_desc')
      }
      .width('100%')
    }
  }"""
REF_CS_IMPORT = ("import { DraftMeTexts, MeSheetPanel, MeTexts } from './MeKit';\n",
                 "import { DraftMeTexts, MeTexts } from './MeKit';\nimport { CsBadge, CsHelpLink, CsSafetyStrip, CsSheetPanel } from './PrivacyAboutCsParts';\n")
REF_CS_CONTENT = """  @Builder
  content() {
    Column({ space: CouliSpacing.space4 }) {
      Text(this.body())
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .textAlign(TextAlign.Center)
        .id('cs_body')
      CsSafetyStrip({ text: this.t('cs.no_code_notice'), stripId: 'cs_safety' })
    }
    .width('100%')
  }"""
REF_CS_BUTTONFOR = """  @Builder
  buttonFor(name: string, first: boolean) {
    if (name === 'open_wechat') {
      CouliButton({
        text: this.t('cs.open_wechat'),
        fullWidth: true,
        buttonId: 'cs_open_wechat',
        onTap: () => this.actions.openWechat()
      })
    } else if (name === 'retry') {
      CouliButton({
        text: this.t('cs.retry'),
        fullWidth: true,
        buttonId: 'cs_retry',
        onTap: () => this.actions.openWechat()
      })
    } else if (name === 'copy_link') {
      CouliButton({
        text: this.t('cs.copy_link'),
        variant: first ? CouliButtonVariant.PRIMARY : CouliButtonVariant.SECONDARY,
        fullWidth: true,
        buttonId: 'cs_copy_link',
        onTap: () => this.actions.copyLink()
      })
    } else if (!first && this.sheet() === CsEntryDecision.OPEN_FAILED) {
      CsHelpLink({
        text: this.t(this.sheet() === CsEntryDecision.HANDOFF ? 'cs.handoff.go_help' : 'cs.go_help'),
        linkId: 'cs_go_help',
        onTap: () => this.actions.goHelp()
      })
    } else {
      CouliButton({
        text: this.t(this.sheet() === CsEntryDecision.HANDOFF ? 'cs.handoff.go_help' : 'cs.go_help'),
        variant: first ? CouliButtonVariant.PRIMARY : CouliButtonVariant.SECONDARY,
        fullWidth: true,
        buttonId: 'cs_go_help',
        onTap: () => this.actions.goHelp()
      })
    }
  }"""
REF_CS_ACTIONS = """  @Builder
  actionsArea() {
    Column({ space: CouliSpacing.space3 }) {
      ForEach(this.buttons(), (name: string, index: number) => {
        this.buttonFor(name, index === 0)
      }, (name: string) => this.sheet() + '_' + name)
    }
    .width('100%')
  }"""
REF_CS_BUILD = """  build() {
    CsSheetPanel({
      title: this.title(),
      closeLabel: this.t('me.close'),
      titleId: 'cs_sheet_title',
      closeId: 'cs_sheet_close',
      panelId: 'cs_sheet_panel',
      maxBodyHeight: Math.max(120, CouliSheetPanel.maxHeight(this.getUIContext()) - 320),
      badge: () => {
        CsBadge({ tone: this.sheet() === CsEntryDecision.OPEN_FAILED || this.sheet() === CsEntryDecision.HELP_ONLY ? 'warning' : 'muted',
          badgeId: 'cs_badge' })
      },
      content: () => {
        this.content()
      },
      actions: () => {
        this.actionsArea()
      },
      onClose: () => this.actions.close()
    })
  }"""
REF_PARTS = """// 参考件（自测用，不可编译）：本组私有件只收值与 @Event。
@ComponentV2
export struct PrivacySwitchRow {
  @Param rowId: string = '';
  @Param on: boolean = false;
  build() {
    Row() {
      Row().id(this.rowId + '_knob_' + (this.on ? 'on' : 'off'))
    }
    .accessibilityRole(AccessibilityRoleType.SWITCH)
    .accessibilityChecked(this.on)
    .accessibilityDescription(this.desc)
  }
}
@ComponentV2
export struct PrivacyBasicNotice {
  @Param noticeId: string = '';
  build() {
    Row() {
      SymbolGlyph($r('sys.symbol.info_circle')).id(this.noticeId + '_icon')
    }
  }
}
@ComponentV2
export struct AboutAppIcon {
  build() {
    Row()
  }
}
@ComponentV2
export struct AboutCopyButton {
  build() {
    Row()
  }
}
@ComponentV2
export struct CsSheetPanel {
  build() {
    Column() {
      Text(this.title).accessibilityRole(AccessibilityRoleType.TITLE_BAR)
      Button() {
      }
    }
  }
}
@ComponentV2
export struct CsBadge {
  build() {
    Row()
  }
}
@ComponentV2
export struct CsSafetyStrip {
  build() {
    Row()
  }
}
@ComponentV2
export struct CsHelpLink {
  build() {
    Text(this.text)
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .accessibilityRole(AccessibilityRoleType.BUTTON)
  }
}
"""
STUB_FAKE_ME = ("export class DebugFakeMe {\n  static readonly SCENES: string[] = ['about_filed', 'about_unfiled', 'cs_no_kf', 'cs_http', 'consent_fail'];\n"
                "  static readonly KEYS: string[] = ['me.consents_count', 'me.consents_last_type'];\n}\n")
STUB_FAKE_ME_BASE = "export class DebugFakeMe {\n}\n"


def reference_views(views):
    pc = views[V_PRIVACY]
    for old, new, n in REF_PRIVACY_PATCHES:
        if pc.count(old) != n:
            raise SystemExit('ME12WB_SELF_TEST_FAIL 参考实现补丁定位串次数不对：' + old[:70])
        pc = pc.replace(old, new)
    pc = replace_method(pc, 'enableFullSection', REF_ENABLE.split('\n', 1)[1])
    pc = replace_method(pc, 'withdrawSection', REF_WITHDRAW.split('\n', 1)[1])
    ab = views[V_ABOUT].replace(*REF_ABOUT_IMPORT)
    ab = replace_method(ab, 'filingCard', REF_ABOUT_FILING.split('\n', 1)[1])
    ab = replace_method(ab, 'content', REF_ABOUT_CONTENT.split('\n', 1)[1])
    cs = views[V_CS].replace(*REF_CS_IMPORT)
    cs = replace_method(cs, 'content', REF_CS_CONTENT.split('\n', 1)[1])
    cs = replace_method(cs, 'buttonFor', REF_CS_BUTTONFOR.split('\n', 1)[1])
    cs = replace_method(cs, 'actionsArea', REF_CS_ACTIONS.split('\n', 1)[1])
    cs = replace_method(cs, 'build', REF_CS_BUILD)
    return {V_PRIVACY: pc, V_ABOUT: ab, V_CS: cs}


def reference_root_page(text):
    old = '        dragBar: false,\n        showClose: false,\n        onDisappear: () => {\n          this.cs.disappeared('
    if text.count(old) != 1:
        raise SystemExit('ME12WB_SELF_TEST_FAIL RootPage 参考补丁定位串不是恰好一次')
    return text.replace(old, '        dragBar: false,\n        showClose: false,\n        ' + MASK_LINE + '\n        onDisappear: () => {\n'
                             '          this.cs.disappeared(')


P, A, C = V_PRIVACY, V_ABOUT, V_CS
MUTANTS = [
    # ---- 隐私红线 ①：撤回确认只认一次 / 点遮罩不关不执行 / 返回 = 取消 / 视图作废同步关框（G4 confirmWithdraw / aboutToDisappear 逐字节）
    ('红线①点遮罩可关', P, '    options.dismissOnMask = false;\n', '    options.dismissOnMask = true;\n'),
    ('红线①系统返回不等于取消', P, '    options.backDismisses = true;\n', '    options.backDismisses = false;\n'),
    ('红线①确认时才取许可（不只认生成时的一次）', P, '      controller.withdraw(identity, permit);\n',
     '      controller.withdraw(controller.identity, controller.withdrawPermit());\n'),
    ('红线①【取消】也执行撤回', P, '    options.onSecondary = (): void => {\n',
     '    options.onPrimary = (): void => {\n      controller.withdraw(identity, permit);\n    };\n    options.onSecondary = (): void => {\n'),
    ('红线①撤回中仍可再开确认框', P, '    if (this.disposed || this.model.withdrawing) {\n      return;\n    }\n    // R1-07',
     '    if (this.disposed) {\n      return;\n    }\n    // R1-07'),
    ('红线①不先关上一个确认框', P, '    if (previous !== null) {\n      previous();\n    }\n', ''),
    ('红线①视图作废不关框', P, '    if (close !== null) {\n      close();\n    }\n', ''),
    ('红线①【取消】改成次按钮（主次对调）', P, "    options.primaryText = this.t('privacy.withdraw.confirm.cancel');\n",
     "    options.primaryText = this.t('privacy.withdraw.confirm.ok');\n"),
    ('红线①撤回按钮撤回中仍可点', P, "            disabled: this.model.withdrawing,\n            buttonId: 'privacy_withdraw',",
     "            buttonId: 'privacy_withdraw',"),
    # ---- 隐私红线 ②：基本模式只读
    ('红线②基本模式也显示撤回（分支条件改）', P, "    } else if (this.shows('withdrawButton')) {\n", "    }\n    if (this.shows('withdrawButton')) {\n"),
    ('红线②个性化分支条件改', P, "    if (this.shows('personalizationSwitch')) {\n", '    if (!this.model.forceUpdate) {\n'),
    ('红线②开启完整功能不调 enableFull', P, '            onTap: () => this.config.enableFull()\n', '            onTap: () => this.config.onBack()\n'),
    ('红线②提示条显示条件改', P, '    if (this.basic() && !this.model.forceUpdate) {\n', '    if (this.basic()) {\n'),
    # ---- 隐私红线 ③：个性化同意记录
    ('红线③个性化目标值取反', P, '        this.config.controller.setPersonalization(target, this.config.controller.identity);\n',
     '        this.config.controller.setPersonalization(!target, this.config.controller.identity);\n'),
    ('红线③个性化开关撤回中仍可切', P, '      disabled: this.model.withdrawing,\n      rowId: \'privacy_personalization\',',
     "      rowId: 'privacy_personalization',"),
    ('红线③失败提示去重被改（apply）', P, '    if (s.message !== null && s.message.seq !== this.lastSeq) {\n', '    if (s.message !== null) {\n'),
    # ---- 隐私红线 ④：无删除入口 / 说明句不可点 / 只查不申请
    ('红线④说明句挂点击去注销', P, "              .id('privacy_withdraw_desc')\n",
     "              .id('privacy_withdraw_desc')\n              .onClick(() => this.config.open('DeleteAccount', {}))\n"),
    ('红线④私有件申请权限', PARTS, '@ComponentV2\nexport struct AboutAppIcon {', 'function ask(): void { requestPermission(); }\n@ComponentV2\nexport struct AboutAppIcon {'),
    ('红线④隐私中心调系统设置（H-P16 行为改动）', P, "      PrivacyBasicNotice({ text: this.t('privacy.basic_mode.notice'), noticeId: 'privacy_basic_notice' })\n",
     "      PrivacyBasicNotice({ text: this.t('privacy.basic_mode.notice'), noticeId: 'privacy_basic_notice', onTap: () => "
     "this.config.openSystemSettings('push') })\n"),
    # ---- 隐私红线 ⑤：客服链接原样 / 动作映射
    ('红线⑤复制按钮改成打开微信', C, "        buttonId: 'cs_copy_link',\n        onTap: () => this.actions.copyLink()",
     "        buttonId: 'cs_copy_link',\n        onTap: () => this.actions.openWechat()"),
    ('红线⑤去帮助改成关闭', C, "        linkId: 'cs_go_help',\n        onTap: () => this.actions.goHelp()",
     "        linkId: 'cs_go_help',\n        onTap: () => this.actions.close()"),
    ('红线⑤重试不再拉起', C, "        buttonId: 'cs_retry',\n        onTap: () => this.actions.openWechat()",
     "        buttonId: 'cs_retry',\n        onTap: () => this.actions.copyLink()"),
    ('红线⑤客服出口被改', 'common/core/src/main/ets/me/CustomerService.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('红线⑤ForEach 键丢半屏种类', C, "      }, (name: string) => this.sheet() + '_' + name)", '      }, (name: string) => name)'),
    ('红线⑤关闭回调被改', C, '      onClose: () => this.actions.close()\n', '      onClose: () => this.actions.goHelp()\n'),
    # ---- 隐私红线 ⑥：诊断白名单 / 复制入口
    ('红线⑥复制结果总说成功', A, "this.t(ok ? 'about.copy_diagnostics.done' : 'me.copy_failed')", "this.t('about.copy_diagnostics.done')"),
    ('红线⑥诊断拼装被改（AppMe）', 'entry/src/main/ets/me/AppMe.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('红线⑥公示不再原样', A, "    Text(this.filing ?? '')\n", "    Text((this.filing ?? '').trim())\n"),
    # ---- 隐私中心视觉
    ('清单行仍 MeRow（行高约 56）', P, "    AgreementSheetRow({\n      divider: true,\n      text: this.t('privacy_center.share_list'),",
     "    MeRow({\n      divider: true,\n      text: this.t('privacy_center.share_list'),"),
    ('协议去向配错（共享清单开隐私政策）', P, "      onTap: () => this.agreement('sdk_list')", "      onTap: () => this.agreement('privacy')"),
    ('个性化仍 MeSwitchRow（说明不读）', P, '    PrivacySwitchRow({\n', '    MeSwitchRow({\n'),
    ('私有开关行缺读屏说明', PARTS, '    .accessibilityDescription(this.desc)\n', ''),
    ('提示条仍 MeNoticeBar（info 18）', P, "      PrivacyBasicNotice({ text: this.t('privacy.basic_mode.notice'), noticeId: 'privacy_basic_notice' })\n",
     "      MeNoticeBar({ text: this.t('privacy.basic_mode.notice'), tone: 'info', barId: 'privacy_basic_notice' })\n"),
    ('仍渲染 basic_desc 副句', P, "            .id('privacy_enable_full_title')\n",
     "            .id('privacy_enable_full_title')\n          Text(this.t('privacy_center.basic_desc'))\n"),
    ('撤回节无卡', P, "    MeCard({\n      cardId: 'privacy_withdraw_card',\n", "    Column({\n      cardId: 'privacy_withdraw_card',\n"),
    ('撤回卡标题不读作标题', P, "              .accessibilityRole(AccessibilityRoleType.TITLE_BAR)\n              .id('privacy_withdraw_title')",
     "              .id('privacy_withdraw_title')"),
    ('撤回按钮换成主按钮', P, "            variant: CouliButtonVariant.SECONDARY,\n            fullWidth: true,\n            loading:",
     '            fullWidth: true,\n            loading:'),
    ('撤回按钮不再是 CouliButton', P, "          CouliButton({\n            text: this.t('privacy_center.withdraw'),",
     "          MeButton({\n            text: this.t('privacy_center.withdraw'),"),
    # ---- 关于视觉
    ('关于图标仍「凑」字块', A, "        AboutAppIcon({ iconId: 'about_app_icon' })\n",
     "        Text(this.t('about.app_name').substring(0, 1)).id('about_app_icon')\n"),
    ('名字仍 title 22', A, "          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))\n"
     "          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)\n          .id('about_app_name')",
     "          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))\n"
     "          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)\n          .id('about_app_name')"),
    ('公示分组名仍在卡内', A, "          MeGroupTitle({ text: this.t('about.filing_title') })\n", "          Text(this.t('about.filing_title'))\n"),
    ('复制按钮仍 CouliButton（无图标）', A, '        AboutCopyButton({\n', '        CouliButton({\n'),
    ('复制说明左对齐', A, "          .textAlign(TextAlign.Center)\n          .id('about_copy_desc')", "          .id('about_copy_desc')"),
    ('公示显示条件被改', A, '      if (this.filing !== null) {\n', '      if (this.filing !== null && this.filing.length > 4) {\n'),
    # ---- 客服视觉
    ('客服仍 MeSheetPanel（标题靠左）', C, '    CsSheetPanel({\n', '    MeSheetPanel({\n'),
    ('客服无图标块', C, "        CsBadge({ tone:", "        Row({ tone:"),
    ('去帮助仍 TEXT 变体', C, "        variant: first ? CouliButtonVariant.PRIMARY : CouliButtonVariant.SECONDARY,\n        fullWidth: true,\n"
     "        buttonId: 'cs_go_help',", "        variant: first ? CouliButtonVariant.PRIMARY : CouliButtonVariant.TEXT,\n        fullWidth: true,\n"
     "        buttonId: 'cs_go_help',"),
    ('安全句仍草稿旧句', C, "this.t('cs.no_code_notice')", "this.t('cs.safety')"),
    ('中段高仍按 actions.maxHeight', C, 'CouliSheetPanel.maxHeight(this.getUIContext())', 'this.actions.maxHeight'),
    ('按钮列间距仍 8', C, "  actionsArea() {\n    Column({ space: CouliSpacing.space3 }) {", "  actionsArea() {\n    Column({ space: CouliSpacing.space2 }) {"),
    ('面板关闭在标题之前', PARTS, '      Text(this.title).accessibilityRole(AccessibilityRoleType.TITLE_BAR)\n      Button() {\n      }\n',
     '      Button() {\n      }\n      Text(this.title).accessibilityRole(AccessibilityRoleType.TITLE_BAR)\n'),
    ('文字链接命中 < 48', PARTS, '      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })\n', ''),
    ('新图标没用 Symbol', PARTS, "      SymbolGlyph($r('sys.symbol.info_circle')).id(this.noticeId + '_icon')\n",
     "      CouliIcon({ name: 'info' }).id(this.noticeId + '_icon')\n"),
    ('客服半屏遮罩仍系统缺省', ROOT_PAGE, '        ' + MASK_LINE + '\n', ''),
    ('RootPage 别处也改了', ROOT_PAGE, '        dragBar: false,\n        showClose: false,\n        ' + MASK_LINE,
     '        dragBar: true,\n        showClose: false,\n        ' + MASK_LINE),
    # ---- 私有件约束
    ('私有件读 config', PARTS, '@ComponentV2\nexport struct CsBadge {', '@ComponentV2\nexport struct CsBadge {\n  @Param config: Object = {};'),
    ('私有件自己弹 Toast', PARTS, '@ComponentV2\nexport struct CsBadge {', '@ComponentV2\nexport struct CsBadge {\n  t(): void { CouliToast.show(); }'),
    ('私有件写中文字面量', PARTS, "  @Param rowId: string = '';", "  @Param rowId: string = '个性化';"),
    ('私有件写色值', PARTS, '@ComponentV2\nexport struct CsBadge {\n  build() {\n    Row()',
     "@ComponentV2\nexport struct CsBadge {\n  build() {\n    Row().backgroundColor('#33290F')"),
    ('私有件缺 CsHelpLink', PARTS, 'export struct CsHelpLink {', 'export struct CsHelpLinkX {'),
    ('新增系统 Toggle 直用', PARTS, '@ComponentV2\nexport struct CsBadge {\n  build() {\n    Row()',
     '@ComponentV2\nexport struct CsBadge {\n  build() {\n    Toggle({ type: ToggleType.Switch, isOn: true })'),
    ('设备 id 缺（privacy_withdraw_card）', P, "      cardId: 'privacy_withdraw_card',\n", ''),
    ('设备 id 缺（cs_sheet_close）', C, "      closeId: 'cs_sheet_close',\n", ''),
    # ---- 逻辑零改动 / 边界
    ('执行器被改', 'common/core/src/main/ets/me/MeControllers.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('纯规则被改', 'common/core/src/main/ets/me/MePresentation.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('entry 接线被改（MePages）', 'entry/src/main/ets/me/MePages.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('客服宿主被改（AppCsSheet）', 'entry/src/main/ets/me/AppCsSheet.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('MeKit 被改', ME + 'MeKit.ets', 'export const K: number = 1;', 'export const K: number = 2;'),
    ('SettingsParts 被改', ME + 'SettingsParts.ets', 'export const S: number = 1;', 'export const S: number = 2;'),
    ('features/me 新增文件', ME + 'MeKit.ets', 'export const K: number = 1;', 'export const K: number = 1;\n//'),
    ('designsystem 被改', 'common/designsystem/src/main/ets/format/PriceTerms.ets', 'export const D: number = 1;', 'export const D: number = 2;'),
    ('AppPrivacy 被改', 'entry/src/main/ets/privacy/AppPrivacy.ets', 'export const Q: number = 1;', 'export const Q: number = 2;'),
    ('强更页被改', 'entry/src/main/ets/update/ForceUpdatePage.ets', 'export const U: number = 1;', 'export const U: number = 2;'),
    ('草稿表改了已有行', 'common/core/src/main/ets/me/MeDraftTexts.ets', "    m.set('cs.safety', '旧句');", "    m.set('cs.safety', '新句');"),
    ('staging 场景缺 consent_fail', FAKE_ME, "'consent_fail'", "'consent_x'"),
    ('staging 缺同意记录计数', FAKE_ME, "'me.consents_count'", "'me.count'"),
    ('夹具被改', VECTORS, '"clock": "2026-10-12T10:30:00+08:00"', '"clock": "2026-10-12T10:31:00+08:00"'),
    # ---- 名单与设施
    # APP-12w-c-harmony 测试 v1（#24 只换定位串，H-R16）：主步再排除 Me12wcUi、device-test 再认 me12wc。
    ('主步不排除 Me12wbUi', 'tools/ci/verify.sh', 'Me12waUi,Me12wbUi,Me12wcUi main', 'Me12waUi,Me12wcUi main'),
    ('没有 me12wb 设备步', 'tools/ci/verify.sh', 'entry-me12wb class=Me12wbUi me12wb', 'entry-me12wb class=Me12wbUi all'),
    ('verify 没跑本宿主自测', 'tools/ci/verify.sh', 'me12wb/check_privacy_visual.py" --self-test', 'me12wb/check_privacy_visual.py" --help'),
    ('device-test 不认 me12wb', 'tools/ci/device-test.sh', 'me12wa|me12wb|me12wc|all)', 'me12wa|me12wc|all)'),
    ('名单少一条', CASES, 'me12wb_17_', 'me12wb_99_'),
    ('core 套件未登记', 'common/core/src/test/List.test.ets', '  me12wbPrivacyTest();\n', ''),
    ('entry 套件未登记', 'entry/src/ohosTest/ets/test/List.test.ets', '  me12wbUiTest();\n', ''),
    ('fixture 被改', FIXTURE, '"rev": "' + REV + '"', '"rev": "' + REV + ' "'),
]
COPY = [SUITE, CASES, 'tools/ci/verify.sh', 'tools/ci/ds02/check_device_result.py', 'tools/ci/device-test.sh',
        'common/core/src/test/List.test.ets', 'entry/src/ohosTest/ets/test/List.test.ets', FIXTURE, VECTORS]
STUB_STRICT = ['common/core/src/main/ets/me/MeControllers.ets', 'common/core/src/main/ets/me/MePresentation.ets',
               'common/core/src/main/ets/me/CustomerService.ets', 'entry/src/main/ets/me/AppMe.ets', 'entry/src/main/ets/me/MePages.ets',
               'entry/src/main/ets/me/AppCsSheet.ets', 'contract.lock']
STUB_TREE = {ME + 'MeKit.ets': 'export const K: number = 1;\n',
             ME + 'SettingsParts.ets': 'export const S: number = 1;\n',
             'common/designsystem/src/main/ets/format/PriceTerms.ets': 'export const D: number = 1;\n',
             'entry/src/main/ets/privacy/AppPrivacy.ets': 'export const Q: number = 1;\n',
             'entry/src/main/ets/update/ForceUpdatePage.ets': 'export const U: number = 1;\n'}
STUB_TREES = ['features/me', 'entry/src/main/ets/privacy', 'entry/src/main/ets/update']
# 不进合成基线 tree：清单外的 designsystem 文件（FU-HM-G1-SYSTEM-CONTROLS（D10-951 ② / #24） 正对照）。
STUB_OUTSIDE = {'common/designsystem/src/main/ets/components/Overlays.ets': 'export const D: number = 1;\n'}
STUB_DRAFT = "export class MeDraftTexts {\n    m.set('cs.safety', '旧句');\n}\n"


def build_stub_tree(tmp):
    base = json.loads((ROOT / FIXTURE).read_text(encoding='utf-8'))
    files = {rel: '// 参考桩：' + rel + '\nexport const X: number = 1;\n' for rel in STUB_STRICT}
    files.update(STUB_TREE)
    files.update(STUB_OUTSIDE)
    files.update(reference_views(base['views']))
    files[PARTS] = REF_PARTS
    files[ROOT_PAGE] = reference_root_page(base['root_page'])
    files[FAKE_ME] = STUB_FAKE_ME
    files['common/core/src/main/ets/me/MeDraftTexts.ets'] = STUB_DRAFT
    for rel, text in files.items():
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding='utf-8')
    for rel in COPY:
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / rel, p)
    synth = dict(base)
    synth['strict'] = [[sha((tmp / rel).read_bytes()), rel] for rel in STUB_STRICT]
    synth['trees'] = STUB_TREES
    synth['tree'] = [[sha(text.encode('utf-8')), rel] for rel, text in sorted(STUB_TREE.items())]
    synth['append_only'] = {FAKE_ME: [line_key(l) for l in STUB_FAKE_ME_BASE.split('\n')],
                            'common/core/src/main/ets/me/MeDraftTexts.ets': [line_key(l) for l in STUB_DRAFT.split('\n')]}
    return synth


def run_mutants(tmp, layer, base, mutants, loose):
    failures = []
    for name, rel, old, new in mutants:
        p = tmp / rel
        if not p.is_file():
            failures.append('[%s] 变异目标缺失：%s（%s）' % (layer, name, rel))
            continue
        original = p.read_text(encoding='utf-8')
        n = original.count(old)
        if n == 0 or (not loose and n != 1):
            failures.append('[%s] 定位串在 %s 里出现 %d 次（须恰好 1 次）：%s' % (layer, rel, n, name))
            continue
        extra = None
        if name == 'features/me 新增文件':
            extra = tmp / (ME + 'PrivacyExtra.ets')
            extra.write_text('export const E: number = 1;\n', encoding='utf-8')
        else:
            p.write_text(original.replace(old, new, 1), encoding='utf-8')
        if rel == FIXTURE:
            _, err = load_fixture(tmp)
            got = [err] if err else []
        else:
            got = check_source(tmp, base) if base is not None else check_source(tmp)
        p.write_text(original, encoding='utf-8')
        if extra is not None:
            extra.unlink()
        print(('KILLED   ' if got else 'SURVIVED ') + '[' + layer + '] ' + name + ('  ← ' + got[0] if got else ''))
        if not got:
            failures.append('[%s] 未被拦下：%s' % (layer, name))
    return failures


def frozen_list_controls(tmp, check, outside_files, inside_listed):
    """FU-HM-G1-SYSTEM-CONTROLS（D10-951 ② / #24）：清单外的文件增 / 删 / 改都不红；清单内文件被删要红（「designsystem 被改」变异已打清单内被改）。"""
    failures = []
    for rel in outside_files:
        outside = tmp / rel
        original = outside.read_bytes()
        outside.write_bytes(original + b'// changed\n')
        if check():
            failures.append('[参考桩] 清单外文件被改被误报：' + rel)
        outside.unlink()
        if check():
            failures.append('[参考桩] 清单外文件被删被误报：' + rel)
        added = outside.with_name('AddedNotFrozen.ets')
        added.write_bytes(original)
        if check():
            failures.append('[参考桩] 清单外新增文件被误报：' + added.name + '（' + rel + ' 同目录）')
        added.unlink()
        outside.write_bytes(original)
    target = tmp / inside_listed
    saved = target.read_bytes()
    target.unlink()
    if not check():
        failures.append('[参考桩] 清单内文件被删未拦下：' + inside_listed)
    target.write_bytes(saved)
    return failures


def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        base = build_stub_tree(tmp)
        got = check_source(tmp, base)
        if got:
            print('ME12WB_SELF_TEST_FAIL 参考桩树不该有违反项：', *got, sep='\n  ')
            return 1
        # 正向对照：只许插入的文件插入一行（含中间插入）不误报；RootPage 选项缩进不同不误报。
        for rel, old, new in [(FAKE_ME, 'export class DebugFakeMe {\n', "export class DebugFakeMe {\n  static readonly SHOT: string = 'x';\n"),
                              ('common/core/src/main/ets/me/MeDraftTexts.ets', '}\n', '    // 追加\n}\n')]:
            p = tmp / rel
            original = p.read_text(encoding='utf-8')
            p.write_text(original.replace(old, new, 1), encoding='utf-8')
            if check_source(tmp, base):
                failures.append('[参考桩] 只许插入的 ' + rel + ' 插入一行被误报')
            p.write_text(original, encoding='utf-8')
        failures += frozen_list_controls(tmp, lambda: check_source(tmp, base), sorted(STUB_OUTSIDE), 'common/designsystem/src/main/ets/format/PriceTerms.ets')
        failures += run_mutants(tmp, '参考桩', base, MUTANTS, False)
    # 层二：真实实现（本仓库检查通过时）。
    if check_source(ROOT):
        print('SKIP [真实实现] 本仓库检查未通过（实现前预期如此；verify 下一步本仓库检查本来就红），层二跳过')
    else:
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            for top in ['common', 'entry/src', 'features', 'tools/ci', 'specs', 'contracts']:
                shutil.copytree(ROOT / top, tmp / top, ignore=shutil.ignore_patterns('build', '.test', 'oh_modules', '.hvigor', '.preview',
                                                                                     'node_modules'))
            shutil.copyfile(ROOT / 'contract.lock', tmp / 'contract.lock')
            real = [
                ('[真]点遮罩可关', V_PRIVACY, 'options.dismissOnMask = false;', 'options.dismissOnMask = true;'),
                ('[真]视图作废不关框', V_PRIVACY, '      close();\n', '      // close();\n'),
                ('[真]个性化目标取反', V_PRIVACY, 'setPersonalization(target,', 'setPersonalization(!target,'),
                ('[真]共享清单去错类型', V_PRIVACY, "this.agreement('sdk_list')", "this.agreement('privacy')"),
                ('[真]复制改打开微信', V_CS, 'onTap: () => this.actions.copyLink()', 'onTap: () => this.actions.openWechat()'),
                ('[真]复制结果总成功', V_ABOUT, "ok ? 'about.copy_diagnostics.done' : 'me.copy_failed'", "'about.copy_diagnostics.done'"),
                ('[真]半屏遮罩去掉', ROOT_PAGE, MASK_LINE, ''),
                ('[真]MeKit 被改', ME + 'MeKit.ets', 'export struct MeRow {', 'export struct MeRow  {'),
                ('[真]私有件读 config', PARTS, '@ComponentV2', "import { AboutConfig } from './AboutView';\n@ComponentV2"),
                ('[真]说明句可点', V_PRIVACY, "'privacy_withdraw_desc'", "'privacy_withdraw_desc').onClick(() => {})//"),
            ]
            failures += run_mutants(tmp, '真实实现', None, real, True)
    if failures:
        print('ME12WB_SELF_TEST_FAIL', *failures, sep='\n  ')
        return 1
    print('ME12WB_SELF_TEST_OK %d 种错误实现全部拦下（参考桩层；真实实现层见上）' % len(MUTANTS))
    return 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    found = check_source(ROOT)
    for f in found:
        print(f)
    print('ME12WB_HOST_OK' if not found else 'ME12WB_HOST_FAIL %d 项' % len(found))
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
