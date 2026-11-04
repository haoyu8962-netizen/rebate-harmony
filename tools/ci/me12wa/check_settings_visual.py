#!/usr/bin/env python3
"""APP-12w-a-harmony（设置一族视觉）宿主检查（测试作者 v1）。依据 NATIVE/APP-12w/brief-a-harmony.md §2、§3、§4.3、§6（H-S01–H-S14 由
D10-600 全部照推荐）。照 tools/ci/me12v/check_me_visual.py 的写法；与它共存（它钉的 11 个文件这里也钉，基线各自独立，不互相改）。
只用 Python 3 标准库；不调 git（基线是仓库里的 fixture，其 sha256 钉在本文件里，改 fixture 即红）。

检查项：
  G1 逻辑与边界文件 sha256 与 REV（cc872c3）一致（§3.1）：me12v G1 的 11 个（含 MeKit，H-S01 一字不动）+ AccountPages / AppAccount /
     HarmonyPermissionSystem / contract.lock；整树：core me/account/**、contracts/**、features/me/**（除 SettingsView.ets 与新
     SettingsParts.ets；不许新增别的文件）、common/designsystem/**（H-S02 / H-S05 / H-S07 不改 DS）、entry/src/staging/**
  G2 只许追加行：MeDraftTexts.ets（预计不加）、staging DebugFakeMe / DebugFakeAccount / BuildVariant（只许追加截图 / 设备场景）
  G4 SettingsView 守卫区（§3.2，按符号）与 REV 逐字节一致：5 个类、cacheSizeText、4 个 SUB_ 常量、35 个方法；build 的子页分支条件；
     回调体（去空白后必须出现在 SettingsView 里）；各 ForEach 键函数；昵称保存 disabled / loading、通知开关 disabled / on / 显示条件；
     bindSheet onClose / onDisappear（焦点回 settings_agreement）；openSystemNotificationSettings 全文件恰好一处
  G5 specs/me-vectors.json：去掉 visualSettings 组后与 REV 逐字节一致（已有组不变；visualSettings 本身由 gen.py --check 守与两端一致）
  S1–S9 视觉静态规则：私有件在 SettingsParts.ets（不读 config / 控制器 / model、不发跳转、无中文字面量）；主页行改 SettingsNavRow、
     撤回 AI 行仍 MeRow（恰好 1 处）；半屏两行 / 去登录 / 去设置不再是 CouliButton；30415 等不再是 MeNoticeBar 红底条（H-S12）、
     通知条不再是 MeNoticeBar + 条外按钮；通知开关不再是 MeSwitchRow（H-S06 私有行）；bindSheet maskColor = overlayScrim；
     不新增 Toggle / showToast / TextInput / bindSheet 直用、不换 CouliTextField（H-S05）；昵称底栏白底 + 上分隔；设备用例依赖的 id
  C1–C3 设备名单三处一致、describe 名；verify 主步排除 Me12waUi、第七个 entry 设备步 entry-me12wa、本宿主步四条命令；
     check_device_result / device-test 认 me12wa；core / entry 两个 List 登记（entry 在 hm07vHomeUiTest 之前）

用法：
  check_settings_visual.py               本仓库
  check_settings_visual.py --self-test   层一：参考桩树（逻辑文件为合成件、基线随之合成；SettingsView 用 REV 原文按 §3.2「允许改」打补丁
                                         成参考实现）全过 + 每种错误实现各自打红（定位串必须恰好一次）；层二：本仓库检查通过时把真实文件
                                         拷出再逐个变异（未通过时跳过并说明）
"""
import hashlib
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REV = 'cc872c3'
FIXTURE = 'tools/ci/me12wa/fixtures/settings-baseline-' + REV + '.json'
# fixture 指纹（NATIVE/APP-12w/tests-a-harmony-v1-aux/make_baseline.py 由 git show REV 生成；改 fixture 来迁就实现即红）。
FIXTURE_SHA256 = 'f07327511b611e19484eb9171577c406f5c10336c3da49150ec151df67ce7e27'

VIEW = 'features/me/src/main/ets/SettingsView.ets'
PARTS = 'features/me/src/main/ets/SettingsParts.ets'
VECTORS = 'specs/me-vectors.json'
SKIP_PARTS = {'build', '.test', 'oh_modules', '.hvigor', '.preview', 'node_modules'}
TREE_SKIP = ('src/test/', 'src/ohosTest/')

GUARD_CLASSES = ['SettingsPageConfig', 'SettingsRowBinding', 'NicknameBinding', 'NotifyBinding', 'SettingsModel']
GUARD_METHODS = ['aboutToAppear', 'aboutToDisappear', 'dispose', 'reload', 'systemBack', 'phoneBack', 'openAgreementSheet', 'closeSub',
                 'currentBound', 'boundLive', 'openNickname', 'applyNick', 'openPhoneChange', 'openNotify', 'applyNotify', 'onForeground',
                 'confirmClearCache', 'dropAiConfirm', 'confirmAiWithdraw', 'dropLogoutConfirm', 'confirmLogout', 'tapItem', 'label',
                 'value', 'rowId', 'groupTitle', 'groups', 'rows', 'clickable', 'rowBindings', 'clipTap', 'nickBindings', 'nickCurrent',
                 'nicknameHint', 'notifyBindings']
GUARD_CONSTS = ["const SUB_MAIN: string = 'main';", "const SUB_NICKNAME: string = 'nickname';", "const SUB_NOTIFY: string = 'notify';",
                "const SUB_PHONE: string = 'phone_change';"]
# build 的子页分支条件（整行去缩进后逐字节）。
GUARD_LINES = {
    'build.phone_if': 'if (this.model.sub === SUB_PHONE && this.phoneCtl !== null) {',
    'build.nickname_if': '} else if (this.model.sub === SUB_NICKNAME) {',
    'build.notify_if': '} else if (this.model.sub === SUB_NOTIFY) {',
}
# 回调体与关键表达式（去注释、去空白后必须出现在 SettingsView 里；私有件不得持有这些调用）。
CALLBACKS = {
    'row': "this.tapItem(b.row['id'] as string, typeof b.row['route'] === 'string' ? b.row['route'] as string : null, b.bound);",
    'clip_toggle': 'this.clipTap(value, true);',
    'clip_row': 'this.clipTap(!this.model.clipOn, false);',
    'clip_on': 'isOn: this.model.clipOn,',
    'clip_toggle_id': "controlId: 'settings_clipboard_auto_toggle',",
    'clip_row_id': ".id('settings_clipboard_auto')",
    'logout': 'if (this.boundLive(b)) { this.confirmLogout(b.identity); }',
    'login': 'if (this.boundLive(b)) { this.config.login(); }',
    'enable_full': 'if (this.boundLive(b)) { this.config.enableFull(); }',
    'agreement_user': "this.model.agreementSheet = false; if (!this.boundLive(bound)) { return; } const p: Record<string, Object> = {};"
                      " p['type'] = 'agreement'; this.config.open('Agreement', p, bound.identity);",
    'agreement_privacy': "this.model.agreementSheet = false; if (!this.boundLive(bound)) { return; } const p: Record<string, Object> = {};"
                         " p['type'] = 'privacy'; this.config.open('Agreement', p, bound.identity);",
    'nick_input': 'if (this.nickCurrent(bound)) { bound.controller.setInput(value, bound.identity); }',
    'nick_clear': "if (this.nickCurrent(bound)) { bound.controller.setInput('', bound.identity); }",
    'nick_save': 'if (this.nickCurrent(b)) { b.controller.save(b.identity); }',
    'nick_disabled': "disabled: (this.model.nick as NicknameSnapshot).check['saveEnabled'] !== true"
                     " || (this.model.nick as NicknameSnapshot).blocked,",
    'nick_loading': 'loading: (this.model.nick as NicknameSnapshot).saving,',
    'notify_toggle': 'if (!this.disposed && this.notifyCtl === bound.controller && this.formSeq === bound.form)'
                     ' { bound.controller.toggle(target, bound.identity); }',
    'notify_disabled': 'disabled: (this.model.notify as NotifySnapshot).saving || (this.model.notify as NotifySnapshot).blocked,',
    'notify_on': 'on: bound.flag,',
    'notify_switch_if': 'if ((this.model.notify as NotifySnapshot).switchAvailable && (this.model.notify as NotifySnapshot).serviceOn !== null) {',
    'notify_bar_if': "if ((this.model.notify as NotifySnapshot).systemRaw !== 'granted') {",
    'notify_spoken': "spoken: switchSpoken(this.config.texts, this.t('notify.service'), bound.flag),",
    'ai_withdraw': 'this.confirmAiWithdraw(bound);',
    'ai_row_id': "rowId: 'settings_ai_withdraw',",
    'sheet_close': 'onClose: () => { this.model.agreementSheet = false; }',
    'sheet_disappear': "onDisappear: () => { this.model.agreementSheet = false; CouliFocusReturn.to(this.getUIContext(), 'settings_agreement'); }",
    'sheet_bind': 'bindSheet(this.model.agreementSheet, this.agreementSheet(), {',
}
OPEN_SYSTEM = 'this.config.openSystemNotificationSettings()'
# 各 ForEach 的键函数（决定按身份 / 世代重建与捕获）。
FOREACH_KEYS = [
    "(b: SettingsRowBinding) => (b.row['id'] as string) + '_' + b.bound.id + '_' + this.model.cacheText + '_' + this.model.nickname"
    " + '_' + this.model.tipBlocked)",
    "(b: Bound) => 'logout_' + b.id + '_' + this.model.busy)",
    "(b: Bound) => 'login_' + b.id)",
    "(b: Bound) => 'enable_full_' + b.id)",
    "(group: MeRecord) => (group['group'] as string) + '_' + this.model.version)",
    "(b: Bound) => 'ai_withdraw_' + b.id)",
    "(b: Bound) => 'agreement_' + b.id)",
    "(b: NicknameBinding) => 'nick_' + b.form + '_' + b.identity)",
    "(b: NicknameBinding) => 'nick_save_' + b.id)",
    "(b: NotifyBinding) => 'notify_' + b.id)",
]
# 私有件（SettingsParts.ets）不得读 / 调的（只收渲染时的值与 @Event，§3.2）。
PARTS_FORBIDDEN = ['config', 'Controller', 'tapItem', 'clipTap', 'boundLive', 'nickCurrent', 'SettingsPageConfig', 'this.model',
                   'AppClipboard', 'openSystemNotificationSettings', 'CouliToast', 'showToast', 'Router', 'confirmLogout',
                   'confirmClearCache']
# 设备用例依赖的 id（tests-a-harmony-handback.md §3.2；新 id + 不改名的旧 id）。
DEVICE_IDS = ['settings_group_title_', 'settings_card_', 'settings_guest_footer', 'settings_login', 'settings_basic_notice',
              'settings_enable_full', 'settings_logout', 'settings_agreement_user', 'settings_agreement_privacy',
              'settings_agreement_sheet_title', 'settings_reset_tip', 'nickname_card', 'nickname_label', 'nickname_box', 'nickname_input',
              'nickname_clear', 'nickname_counter', 'nickname_error', 'nickname_local_hint', 'nickname_message', 'nickname_hint',
              'nickname_footer', 'nickname_save', 'notify_system_off', 'notify_go_settings', 'notify_service_switch']
NEW_DIRECT = {'Toggle(': 0, 'showToast(': 0, 'TextInput(': 1, '.bindSheet(': 1, 'CouliTextField(': 0}
SUITE = 'entry/src/ohosTest/ets/test/Me12waUi.test.ets'
CASES = 'tools/ci/me12wa/fixtures/device-cases.txt'
CORE_SUITE = 'common/core/src/test/Me12waSettings.test.ets'


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


def function_text(text, name):
    m = re.search(r'(?m)^(?:export\s+)?function\s+' + name + r'\s*\([^)]*\)\s*(?::\s*[^{;]+)?\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else text[m.start():end + 1]


def method_text(text, name):
    m = re.search(r'(?m)^[ \t]*(?:(?:private|public|protected|static|async)\s+)*' + name + r'\s*\([^)]*\)\s*(?::\s*[^{;]+)?\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else text[m.start():end + 1]


def guard_symbols(view):
    out = {}
    for name in GUARD_CLASSES:
        out['class.' + name] = class_text(view, name)
    out['function.cacheSizeText'] = function_text(view, 'cacheSizeText')
    for name in GUARD_METHODS:
        out['method.' + name] = method_text(view, name)
    return out


def load_fixture(root):
    p = root / FIXTURE
    if not p.is_file():
        return None, 'G0 fixture 缺失 ' + FIXTURE
    data = p.read_bytes()
    if sha(data) != FIXTURE_SHA256:
        return None, 'G0 fixture 被改 ' + FIXTURE + '（sha256 ' + sha(data)[:12] + ' ≠ 钉住的 ' + FIXTURE_SHA256[:12] + '）'
    return json.loads(data.decode('utf-8')), None


def owner_component(src, literal):
    """字面量（如 'settings_login'）所在组件调用名：往前找最近的「大写开头名字({」。字面量不在为 None。"""
    at = src.find(literal)
    if at < 0:
        return None
    found = None
    for m in re.finditer(r'\b([A-Z]\w*)\s*\(\s*\{', src[:at]):
        found = m.group(1)
    return found


# ---------------------------------------------------------------- 检查

def check_logic(root, base):
    v = []
    for want, rel in base['strict']:
        p = root / rel
        if not p.is_file():
            v.append('G1 逻辑文件缺失 ' + rel)
        elif sha(p.read_bytes()) != want:
            v.append('G1 逻辑 / 边界文件被改 ' + rel + '（§3.1 合入前后 sha256 必须一致' +
                     ('；H-S01 MeKit 一字不动' if rel.endswith('MeKit.ets') else '') + '）')
    tree = {rel: s for s, rel in base['tree']}
    exempt = set(base['tree_exempt']) | set(base['append_only'].keys()) | {rel for _, rel in base['strict']}
    tops = ['common/core/src/main/ets/me/account', 'contracts', 'features/me', 'common/designsystem', 'entry/src/staging']
    for top in tops:
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
                hint = '（H-S02 / H-S05 / H-S07：不改 DS）' if top == 'common/designsystem' else \
                    '（H-S01：设置私有件只放 SettingsParts.ets，MeKit 等不动）' if top == 'features/me' else ''
                v.append('G1 ' + top + ' 有' + kind + '：' + rel + hint)
    for rel, keys in sorted(base['append_only'].items()):
        now = [line_key(l) for l in read(root, rel).split('\n')]
        i = 0
        for k in now:
            if i < len(keys) and k == keys[i]:
                i += 1
        if i < len(keys):
            v.append('G2 ' + rel + ' 只许追加行：' + REV + ' 的第 %d 行被改 / 删 / 挪位' % (i + 1))
    return v


def check_guard(root, base):
    v = []
    view = read(root, VIEW)
    if not view:
        return ['G4 缺 ' + VIEW]
    want = guard_symbols(base['view'])
    for name, text in sorted(want.items()):
        if text is None:
            v.append('G0 fixture 里抽不到守卫符号 ' + name + '（抽取规则与基线不符）')
    now = guard_symbols(view)
    for name, text in sorted(want.items()):
        if text is not None and now.get(name) != text:
            v.append('G4 SettingsView 守卫区被改：' + name + '（§3.2 与 ' + REV + ' 逐字节一致）')
    flat = [line.strip() for line in view.split('\n')]
    for line in GUARD_CONSTS:
        if line not in flat:
            v.append('G4 SettingsView 守卫区被改：子页常量缺这一行 ' + line)
    for name, line in GUARD_LINES.items():
        if line not in flat:
            v.append('G4 SettingsView 守卫区被改：' + name + '（缺这一行：' + line + '）')
    body = squash(strip_comments(view))
    for name, call in CALLBACKS.items():
        if squash(call) not in body:
            v.append('G4 回调体 / 关键表达式被改或挪出 SettingsView：' + name + '（' + call + '）')
    if body.count(squash(OPEN_SYSTEM)) != 1:
        v.append('G4 openSystemNotificationSettings() 在 SettingsView 必须恰好一处（只跳系统设置，BR-ID-13 / AC-S1-84），现 %d 处'
                 % body.count(squash(OPEN_SYSTEM)))
    for key in FOREACH_KEYS:
        if squash(key) not in body:
            v.append('G4 ForEach 键函数被改：' + key)
    return v


def check_vectors(root, base):
    text = read(root, VECTORS)
    lines = text.split('\n')
    if '  "visualSettings": {' in lines:
        at = lines.index('  "visualSettings": {')
        rest = lines[:at]
        if rest and rest[-1] == '  },':
            rest[-1] = '  }'
        text = '\n'.join(rest + ['}', ''])
    if sha(text.encode('utf-8')) != base['vectors_base']:
        return ['G5 specs/me-vectors.json 已有组被改（只许追加 visualSettings；去掉它后须与 ' + REV + ' 逐字节一致，H-S09）']
    return []


def check_static(root):
    v = []
    view = strip_comments(read(root, VIEW))
    parts_raw = read(root, PARTS)
    parts = strip_comments(parts_raw)
    both = view + '\n' + parts
    # S1 私有件放新文件 SettingsParts.ets（H-S01），只收值与 @Event。
    if not parts:
        v.append('S1 缺 ' + PARTS + '（H-S01：设置一族私有件放新文件，MeKit 一字不动）')
    for bad in PARTS_FORBIDDEN:
        if bad in parts:
            v.append('S1 SettingsParts 私有件读 / 调了 ' + bad + '（只收渲染时的值与 @Event 回调，§3.2）')
    if re.search(r"'[^'\n]*[一-鿿][^'\n]*'", parts) or re.search(r'"[^"\n]*[一-鿿][^"\n]*"', parts):
        v.append('S1 SettingsParts 写了中文字面量（HM-LINT-1：文案经字典取键，由页面传入）')
    if parts and '@ComponentV2' not in parts:
        v.append('S1 SettingsParts 私有件须是 @ComponentV2（状态管理只用 V2）')
    # S2 主页导航行：SettingsNavRow（52 / 节距 53、动作行无 ›），撤回 AI 行仍 MeRow（恰好一处）。
    if 'SettingsNavRow(' not in view:
        v.append('S2 设置主页导航行没换成 SettingsNavRow（H-S01：52 / 节距 53 的私有行）')
    if not re.search(r'\bstruct\s+SettingsNavRow\b', parts):
        v.append('S2 SettingsParts 里没有 SettingsNavRow')
    if view.count('MeRow(') != 1:
        v.append('S2 SettingsView 里 MeRow( 应恰好一处（撤回 AI 行仍 48，FU），现 %d 处' % view.count('MeRow('))
    # S3 半屏两行 / 去登录 / 去设置 不再是 CouliButton。
    for literal, what in [("'settings_agreement_user'", '协议半屏「用户协议」'), ("'settings_agreement_privacy'", '协议半屏「隐私政策」'),
                          ("'settings_login'", '游客「去登录」'), ("'notify_go_settings'", '通知「去设置」')]:
        owner = owner_component(view, literal)
        if owner == 'CouliButton':
            v.append('S3 ' + what + ' 仍是 CouliButton（应为列表行 / 文字链接，S10 / S14 / S20）')
    # S4 30415 等消息不再是 MeNoticeBar 红底条（H-S12）；通知条不再是 MeNoticeBar（S20 私有 NotifyWarningBar）；
    #    通知开关不再是 MeSwitchRow（H-S06 私有行：说明移到下方）。
    if re.search(r"tone:\s*'error'", view):
        v.append("S4 昵称消息仍是 MeNoticeBar tone 'error' 红底条（H-S12：改框下错误行）")
    if 'MeNoticeBar(' in view:
        v.append('S4 SettingsView 仍用 MeNoticeBar（通知条 / 昵称消息应换私有件）')
    if 'MeSwitchRow(' in view:
        v.append('S4 通知服务开关仍是 MeSwitchRow（H-S06：私有 NotifyServiceRow，说明在下方）')
    # S5 半屏遮罩令牌（S14）。
    m = re.search(r'\.bindSheet\(', view)
    sheet = view[m.start():match_close(view, m.end() - 1, '(', ')') + 1] if m else ''
    if not re.search(r'maskColor\s*:\s*CouliColors\.overlayScrim', sheet):
        v.append('S5 协议半屏 bindSheet 没设 maskColor: CouliColors.overlayScrim（S14）')
    # S6 不新增系统控件直用（DS-02 G1 警告不增；H-S05 不换 CouliTextField）。
    for token, limit in NEW_DIRECT.items():
        n = len(re.findall(re.escape(token) if token.startswith('.') else r'(?<!\w)' + re.escape(token), both))
        if n > limit:
            v.append('S6 ' + token + ' 直用 %d 处（> %d：DS-02 G1 / H-S05）' % (n, limit))
    # S7 昵称底栏白底 + 上分隔（S19）。
    footer = method_text(view, 'nicknameFooter') or ''
    if 'backgroundSurface' not in footer:
        v.append('S7 昵称底栏没有白底（nicknameFooter 里 backgroundSurface，S19）')
    if 'borderSubtle' not in footer:
        v.append('S7 昵称底栏没有上分隔（nicknameFooter 里 borderSubtle，S19）')
    # S8 设备用例依赖的 id。
    for did in DEVICE_IDS:
        if did not in both:
            v.append('S8 缺设备用例依赖的 id ' + did)
    if "'_knob_" not in both:
        v.append("S8 通知服务开关缺视觉节点 id（<行 id>_knob_on|off，同 MeSwitchRow 约定）")
    # S9 剪贴板行仍是 DS CouliSwitch（H-S07：只修缩进，不换控件）。
    if view.count('CouliSwitch(') != 1:
        v.append('S9 剪贴板行应仍是一个 CouliSwitch（H-S07 不换控件），现 %d 处' % view.count('CouliSwitch('))
    return v


def check_registration(root):
    v = []
    suite = read(root, SUITE)
    listed = re.findall(r"'(me12wa_\d\d_[a-z0-9_]+)'", suite.split('];')[0]) if suite else []
    its = len(re.findall(r'\bit\(ME12WA_DEVICE_CASES\[\d+\]', suite))
    fixture = [l.strip() for l in read(root, CASES).splitlines() if l.strip() and not l.startswith('#')]
    if not listed or listed != fixture or len(set(listed)) != len(listed) or its != len(listed):
        v.append('C1 设备名单三处不一致（ME12WA_DEVICE_CASES / device-cases.txt / it 数）')
    if "describe('Me12waUi'" not in suite:
        v.append('C1 describe 名必须是 Me12waUi（verify 按 class 过滤）')
    verify = read(root, 'tools/ci/verify.sh')
    tails = [line.split()[-3:] for line in verify.splitlines() if line.strip().startswith('run_device_tests entry ')]
    main_ok = any(t[0] == 'entry' and t[2] == 'main' and t[1].startswith('notClass=') and 'Me12waUi' in t[1].split('=', 1)[1].split(',')
                  for t in tails)
    if not main_ok:
        v.append('C2 verify 主 entry 步必须排除 Me12waUi')
    if ['entry-me12wa', 'class=Me12waUi', 'me12wa'] not in tails:
        v.append('C2 verify 缺单独设备步 entry-me12wa class=Me12waUi me12wa')
    for cmd in ['me12wa/check_settings_visual.py" --self-test', 'me12wa/check_settings_visual.py" ||', 'me12wa/run-logic.cjs"',
                'me12wa/check-arkts.cjs" --real']:
        if cmd not in verify:
            v.append('C2 verify 缺 APP-12w-a 宿主检查步命令：' + cmd)
    if 'me12wa/fixtures/device-cases.txt' not in read(root, 'tools/ci/ds02/check_device_result.py'):
        v.append('C2 check_device_result.py 缺 me12wa 名单')
    if not re.search(r'main\|hm07va\|hm07vb\|hm05r\|(?:[a-z0-9]+\|)*me12wa\|(?:[a-z0-9]+\|)*all\)', read(root, 'tools/ci/device-test.sh')):
        v.append('C2 device-test.sh 不认 COULI_HM_DEVICE_SET=me12wa')
    if not re.search(r'^\s*me12waSettingsTest\(\);', strip_comments(read(root, 'common/core/src/test/List.test.ets')), flags=re.M):
        v.append('C3 core List.test.ets 未登记 me12waSettingsTest()')
    entry_list = strip_comments(read(root, 'entry/src/ohosTest/ets/test/List.test.ets'))
    a, b = entry_list.find('me12waUiTest();'), entry_list.find('hm07vHomeUiTest();')
    if a < 0 or b < 0 or a > b:
        v.append('C3 entry List.test.ets 须登记 me12waUiTest()，且在 hm07vHomeUiTest() 之前（HM-07v-a C3 最后注册）')
    return v


def check_source(root, base=None):
    v = []
    if base is None:
        base, err = load_fixture(root)
        if err:
            v.append(err)
    if base is not None:
        v += check_logic(root, base)
        v += check_guard(root, base)
        v += check_vectors(root, base)
    v += check_static(root)
    v += check_registration(root)
    return v


# ---------------------------------------------------------------- 自测

# 参考实现：REV 原文按 §3.2「允许改」打补丁（只给静态检查用，不可编译；实现方不必照抄）。
REF_VIEW_PATCHES = [
    ("} from './MeKit';\n", "} from './MeKit';\nimport { AgreementSheetRow, BasicModeNotice, GuestLoginLink, NicknameErrorRow, NotifyServiceRow,"
     " NotifyWarningBar, SettingsNavRow } from './SettingsParts';\n"),
    ("      if (this.groupTitle(group['group'] as string).length > 0) {\n        MeGroupTitle({ text: this.groupTitle(group['group'] as string) })\n",
     "      if (this.groupTitle(group['group'] as string).length > 0) {\n        MeGroupTitle({ text: this.groupTitle(group['group'] as string) })\n"
     "          .id('settings_group_title_' + index)\n"),
    ("      MeCard({\n        content: () => {\n          this.groupRows(group)\n        }\n      })\n",
     "      MeCard({\n        cardId: 'settings_card_' + index,\n        content: () => {\n          this.groupRows(group)\n        }\n      })\n"),
    ("    .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })\n      if (divider) {",
     "    .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })\n        .margin({ left: -CouliSpacing.space4, right: -CouliSpacing.space4 })\n"
     "      if (divider) {"),
    ("      MeRow({\n        label: this.label(b.row['id'] as string),",
     "      SettingsNavRow({\n        showChevron: this.clickable(b.row) && b.row['id'] !== SettingsItems.ID_RESET_TIP,\n"
     "        label: this.label(b.row['id'] as string),"),
    ("            .textAlign(TextAlign.Center)\n            .width('100%')\n",
     "            .textAlign(TextAlign.Center)\n            .width('100%')\n            .id('settings_guest_footer')\n"),
    ("            CouliButton({\n              text: this.t('settings.go_login'),\n              fullWidth: true,\n              buttonId: 'settings_login',",
     "            GuestLoginLink({\n              text: this.t('settings.go_login'),\n              linkId: 'settings_login',"),
    ("        ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {\n          CouliButton({\n"
     "            text: this.t('privacy.basic_mode.enable'),",
     "        BasicModeNotice({ text: this.t('privacy.basic_mode.notice'), noticeId: 'settings_basic_notice' })\n"
     "        ForEach([new Bound(this.model.identity, this.model.version)], (b: Bound) => {\n          CouliButton({\n"
     "            text: this.t('privacy.basic_mode.enable'),"),
    ("      CouliButton({\n        text: this.t('settings.agreement.user'),\n        variant: CouliButtonVariant.SECONDARY,\n        fullWidth: true,\n"
     "        buttonId: 'settings_agreement_user',",
     "      AgreementSheetRow({\n        text: this.t('settings.agreement.user'),\n        rowId: 'settings_agreement_user',"),
    ("      CouliButton({\n        text: this.t('settings.agreement.privacy'),\n        variant: CouliButtonVariant.SECONDARY,\n        fullWidth: true,\n"
     "        buttonId: 'settings_agreement_privacy',",
     "      AgreementSheetRow({\n        text: this.t('settings.agreement.privacy'),\n        rowId: 'settings_agreement_privacy',"),
    ("        MeNoticeBar({\n          text: ((this.model.nick as NicknameSnapshot).message as MeMessage).text,\n          tone: 'error',\n"
     "          barId: 'nickname_message'\n        })",
     "        NicknameErrorRow({\n          text: ((this.model.nick as NicknameSnapshot).message as MeMessage).text,\n"
     "          rowId: 'nickname_message'\n        })"),
    ("      .width('100%')\n      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,\n"
     "        bottom: CouliSpacing.space5 })\n",
     "      .width('100%')\n      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,\n"
     "        bottom: CouliSpacing.space5 })\n      .backgroundColor(CouliColors.backgroundSurface)\n"
     "      .border({ width: { top: 1 }, color: { top: CouliColors.borderSubtle } })\n      .id('nickname_footer')\n"),
    ("        MeNoticeBar({ text: this.t('perm.push.denied_forever'), tone: 'warning', barId: 'notify_system_off' })\n"
     "        CouliButton({\n          text: this.t('perm.go_settings'),\n          variant: CouliButtonVariant.SECONDARY,\n          fullWidth: true,\n"
     "          buttonId: 'notify_go_settings',\n",
     "        NotifyWarningBar({\n          text: this.t('perm.push.denied_forever'),\n          linkText: this.t('perm.go_settings'),\n"
     "          barId: 'notify_system_off',\n          linkId: 'notify_go_settings',\n"),
    ("      MeSwitchRow({\n        label: this.t('notify.service'),", "      NotifyServiceRow({\n        label: this.t('notify.service'),"),
    ("      dragBar: false,\n", "      dragBar: false,\n      maskColor: CouliColors.overlayScrim,\n"),
    ("      Text(this.t('nickname.label'))\n", "      Text(this.t('nickname.label'))\n        .id('nickname_label')\n"),
    ("      .borderRadius(12)\n", "      .borderRadius(12)\n      .id('nickname_box')\n"),
    ("      Text(this.t('nickname.hint'))\n", "      Text(this.t('nickname.hint'))\n        .id('nickname_hint')\n"),
    ("    .width('100%')\n    .alignItems(HorizontalAlign.Start)\n  }\n\n  /** 本地长度提示",
     "    .width('100%')\n    .alignItems(HorizontalAlign.Start)\n    .id('nickname_card')\n  }\n\n  /** 本地长度提示"),
    ("    ForEach(this.groups(), (group: MeRecord) => {\n      this.groupCard(group)\n    },",
     "    ForEach(this.groups(), (group: MeRecord, index: number) => {\n      this.groupCard(group, index)\n    },"),
    ("  groupCard(group: MeRecord) {", "  groupCard(group: MeRecord, index: number) {"),
]
REF_PARTS = """// 参考件（自测用，不可编译）：设置一族私有件只收值与 @Event。
@ComponentV2
export struct SettingsNavRow {
  @Param label: string = '';
  @Param showChevron: boolean = true;
  @Event onTap: () => void = () => {
  };
}

@ComponentV2
export struct NotifyServiceRow {
  @Param rowId: string = '';
  @Param on: boolean = false;

  build() {
    Row() {
    }
    .id(this.rowId + '_knob_' + (this.on ? 'on' : 'off'))
  }
}
"""
V = VIEW
MUTANTS = [
    # ---- prompt 列的错误实现（宿主层能看到的部分；设备层见 Me12waUi）
    ('行高仍 48：主页行仍 MeRow', V, "      SettingsNavRow({\n        showChevron:", "      MeRow({\n        showChevron:"),
    ('私有行 SettingsNavRow 缺失（52 行没放进 SettingsParts）', PARTS, 'export struct SettingsNavRow', 'export struct SettingsNavRowX'),
    ('协议半屏仍两个通栏按钮', V, "      AgreementSheetRow({\n        text: this.t('settings.agreement.user'),",
     "      CouliButton({\n        text: this.t('settings.agreement.user'),"),
    ('30415 仍红底条', V, "        NicknameErrorRow({\n          text: ((this.model.nick as NicknameSnapshot).message as MeMessage).text,\n",
     "        MeNoticeBar({ tone: 'error',\n          text: ((this.model.nick as NicknameSnapshot).message as MeMessage).text,\n"),
    ('昵称缺白底栏', V, '      .backgroundColor(CouliColors.backgroundSurface)\n      .border({ width: { top: 1 }', '      .border({ width: { top: 1 }'),
    ('昵称底栏缺上分隔', V, '      .border({ width: { top: 1 }, color: { top: CouliColors.borderSubtle } })\n', ''),
    ('改了 MeKit', 'features/me/src/main/ets/MeKit.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('守卫区被改（tapItem 清缓存不弹确认）', V, '      case SettingsItems.ID_CLEAR_CACHE:\n        this.confirmClearCache();',
     '      case SettingsItems.ID_CLEAR_CACHE:\n        this.config.clearCache();'),
    ('守卫区被改（confirmLogout 点遮罩可关）', V, '    // 点遮罩不执行；系统返回走与【取消】相同的出口（APP-09 第 48 条）。\n    options.dismissOnMask = false;',
     '    // 点遮罩不执行；系统返回走与【取消】相同的出口（APP-09 第 48 条）。\n    options.dismissOnMask = true;'),
    ('守卫区被改（clipTap）', V, '    this.config.toggleClipboard(target);\n', '    this.config.toggleClipboard(!target);\n'),
    ('守卫区被改（SettingsPageConfig）', V, '  stepUpViewport: number = 0;', '  stepUpViewport: number = 1;'),
    ('守卫区被改（cacheSizeText）', V, "    return Math.round(bytes / 1024) + ' KB';", "    return Math.ceil(bytes / 1024) + ' KB';"),
    ('守卫区被改（SUB_ 常量）', V, "const SUB_PHONE: string = 'phone_change';", "const SUB_PHONE: string = 'phone';"),
    ('守卫区被改（boundLive）', V, '    return !this.disposed && bound.identity === this.model.identity && bound.version === this.model.version\n',
     '    return !this.disposed && bound.identity === this.model.identity\n'),
    ('守卫区被改（applyNick 焦点 id）', V, "ui.getFocusController().requestFocus('nickname_error');",
     "ui.getFocusController().requestFocus('nickname_message');"),
    ('守卫区被改（30415 也移焦：applyNick 消息分支）', V, '      this.lastNickSeq = s.message.seq;\n      CouliAnnounce.say(ui, s.message.text);\n',
     "      this.lastNickSeq = s.message.seq;\n      CouliAnnounce.say(ui, s.message.text);\n      ui.getFocusController().requestFocus('nickname_message');\n"),
    ('build 子页分支条件被改', V, '} else if (this.model.sub === SUB_NOTIFY) {', '} else if (this.notifyCtl !== null) {'),
    ('行回调体丢路由', V, "typeof b.row['route'] === 'string' ? b.row['route'] as string : null,\n            b.bound);",
     'null,\n            b.bound);'),
    ('协议「隐私政策」去错类型', V, "          p['type'] = 'privacy';", "          p['type'] = 'agreement';"),
    ('去登录不核对绑定', V, '                if (this.boundLive(b)) {\n                  this.config.login();\n                }',
     '                this.config.login();'),
    ('去设置多一处出口', V, "    .id('settings_clipboard_auto')\n", "    .id('settings_clipboard_auto')\n    .onAppear(() => this.config.openSystemNotificationSettings())\n"),
    ('通知开关回调不核对表单', V, '!this.disposed && this.notifyCtl === bound.controller && this.formSeq === bound.form',
     '!this.disposed && this.notifyCtl === bound.controller'),
    ('昵称保存 disabled 改了（30415 置灰）', V, "              || (this.model.nick as NicknameSnapshot).blocked,",
     "              || (this.model.nick as NicknameSnapshot).blocked || (this.model.nick as NicknameSnapshot).message !== null,"),
    ('ForEach 键函数改了（行键丢 cacheText）', V, " + '_' + this.model.cacheText\n", '\n'),
    ('半屏关闭焦点不回协议行', V, "CouliFocusReturn.to(this.getUIContext(), 'settings_agreement');",
     "CouliFocusReturn.to(this.getUIContext(), 'settings_scroll');"),
    ('撤回 AI 行也换了 SettingsNavRow', V, '    MeRow({\n      label: this.config.aiWithdrawTexts()[0] ??',
     '    SettingsNavRow({\n      label: this.config.aiWithdrawTexts()[0] ??'),
    ('去登录仍是通栏按钮', V, "            GuestLoginLink({\n              text: this.t('settings.go_login'),\n              linkId: 'settings_login',",
     "            CouliButton({\n              text: this.t('settings.go_login'),\n              buttonId: 'settings_login',"),
    ('去设置仍在条外通栏按钮', V, "        NotifyWarningBar({\n          text: this.t('perm.push.denied_forever'),",
     "        CouliButton({\n          text: this.t('perm.push.denied_forever'),"),
    ('通知说明位置错（仍 MeSwitchRow）', V, "      NotifyServiceRow({\n        label: this.t('notify.service'),",
     "      MeSwitchRow({\n        label: this.t('notify.service'),"),
    ('半屏遮罩没用令牌', V, '      maskColor: CouliColors.overlayScrim,\n', ''),
    ('新增系统 Toggle 直用', V, "    .id('settings_clipboard_auto')\n", "    .id('settings_clipboard_auto')\n    Toggle({ type: ToggleType.Switch, isOn: true })\n"),
    ('新增 showToast 直用', V, "    .id('settings_clipboard_auto')\n",
     "    .id('settings_clipboard_auto')\n    .onAppear(() => promptAction.showToast({ message: '' }))\n"),
    ('剪贴板行换了控件', V, '      CouliSwitch({\n        isOn: this.model.clipOn,', '      MeSwitchRow({\n        isOn: this.model.clipOn,'),
    ('昵称框换 CouliTextField', V, "        TextInput({ text: (this.model.nick as NicknameSnapshot).input })",
     "        CouliTextField({ text: (this.model.nick as NicknameSnapshot).input })"),
    ('私有件读 config', PARTS, "  @Param label: string = '';", "  @Param label: string = '';\n  @Param config: SettingsPageConfig;"),
    ('私有件自己跳系统设置', PARTS, '  @Param rowId: string = \'\';', "  @Param rowId: string = '';\n  go(): void { this.cfg.openSystemNotificationSettings(); }"),
    ('私有件写中文字面量', PARTS, "  @Param label: string = '';", "  @Param label: string = '昵称';"),
    ('设备 id 缺（nickname_box）', V, "      .id('nickname_box')\n", ''),
    ('设备 id 缺（knob）', PARTS, "'_knob_'", "'_k_'"),
    # ---- 逻辑零改动 / 边界
    ('执行器被改', 'common/core/src/main/ets/me/MeControllers.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('注销线被改', 'entry/src/main/ets/account/AccountPages.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('权限状态被改', 'entry/src/main/ets/permission/HarmonyPermissionSystem.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('契约锁被改', 'contract.lock', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('features/me 其他页被改', 'features/me/src/main/ets/AboutView.ets', 'export const A: number = 1;', 'export const A: number = 2;'),
    ('features/me 新增文件', 'features/me/src/main/ets/AboutView.ets', 'export const A: number = 1;', 'export const A: number = 1;\n//'),
    ('designsystem 被改', 'common/designsystem/src/main/ets/Colors.ets', 'export const C: number = 1;', 'export const C: number = 2;'),
    ('注销线 core 被改', 'common/core/src/main/ets/me/account/AccountDraftTexts.ets', 'export const D: number = 1;', 'export const D: number = 2;'),
    ('staging 其他文件被改', 'entry/src/staging/ets/variant/DebugFakeHome.ets', 'export const H: number = 1;', 'export const H: number = 2;'),
    ('staging 场景改了已有行', 'entry/src/staging/ets/variant/DebugFakeMe.ets', "const SCENE: string = 'nickname_limit';",
     "const SCENE: string = 'limit';"),
    ('草稿表改了已有行', 'common/core/src/main/ets/me/MeDraftTexts.ets', "m.set('settings.go_login', '去登录');", "m.set('settings.go_login', '登录');"),
    ('me-vectors 已有组被改', VECTORS, '"version": 1', '"version": 2'),
    # ---- 名单与设施
    ('主步不排除 Me12waUi', 'tools/ci/verify.sh', 'Me12vUi,Me12waUi main', 'Me12vUi main'),
    ('没有 me12wa 设备步', 'tools/ci/verify.sh', 'entry-me12wa class=Me12waUi me12wa', 'entry-me12wa class=Me12waUi all'),
    ('verify 没跑本宿主自测', 'tools/ci/verify.sh', 'me12wa/check_settings_visual.py" --self-test', 'me12wa/check_settings_visual.py" --help'),
    ('device-test 不认 me12wa', 'tools/ci/device-test.sh', 'me12v|me12wa|all)', 'me12v|all)'),
    ('名单少一条', CASES, 'me12wa_15_', 'me12wa_99_'),
    ('core 套件未登记', 'common/core/src/test/List.test.ets', '  me12waSettingsTest();\n', ''),
    ('entry 套件未登记', 'entry/src/ohosTest/ets/test/List.test.ets', '  me12waUiTest();\n', ''),
    ('fixture 被改', FIXTURE, '"rev": "' + REV + '"', '"rev": "' + REV + ' "'),
]
COPY = [SUITE, CASES, 'tools/ci/verify.sh', 'tools/ci/ds02/check_device_result.py', 'tools/ci/device-test.sh',
        'common/core/src/test/List.test.ets', 'entry/src/ohosTest/ets/test/List.test.ets', FIXTURE]
STUB_STRICT = ['common/core/src/main/ets/me/MeControllers.ets', 'features/me/src/main/ets/MeKit.ets', 'entry/src/main/ets/account/AccountPages.ets',
               'entry/src/main/ets/permission/HarmonyPermissionSystem.ets', 'contract.lock']
STUB_TREE = {'features/me/src/main/ets/AboutView.ets': 'export const A: number = 1;\n',
             'common/designsystem/src/main/ets/Colors.ets': 'export const C: number = 1;\n',
             'common/core/src/main/ets/me/account/AccountDraftTexts.ets': 'export const D: number = 1;\n',
             'entry/src/staging/ets/variant/DebugFakeHome.ets': 'export const H: number = 1;\n',
             'contracts/snapshot/x.json': '{}\n'}
STUB_APPEND = {'common/core/src/main/ets/me/MeDraftTexts.ets': "export class MeDraftTexts {\n    m.set('settings.go_login', '去登录');\n}\n",
               'entry/src/staging/ets/variant/DebugFakeMe.ets': "const SCENE: string = 'nickname_limit';\n"}
STUB_VECTORS_BASE = '{\n  "version": 1,\n  "visualMe": {\n    "a": 1\n  }\n}\n'
STUB_VECTORS_NOW = '{\n  "version": 1,\n  "visualMe": {\n    "a": 1\n  },\n  "visualSettings": {\n    "b": 2\n  }\n}\n'


def reference_view(base_view):
    text = base_view
    for old, new in REF_VIEW_PATCHES:
        if text.count(old) != 1:
            raise SystemExit('ME12WA_SELF_TEST_FAIL 参考实现补丁定位串不是恰好一次：' + old[:70])
        text = text.replace(old, new)
    return text


def build_stub_tree(tmp):
    base = json.loads((ROOT / FIXTURE).read_text(encoding='utf-8'))
    files = {rel: '// 参考桩：' + rel + '\nexport const X: number = 1;\n' for rel in STUB_STRICT}
    files.update(STUB_TREE)
    files.update(STUB_APPEND)
    files[VIEW] = reference_view(base['view'])
    files[PARTS] = REF_PARTS
    files[VECTORS] = STUB_VECTORS_NOW
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
    synth['tree'] = [[sha(text.encode('utf-8')), rel] for rel, text in sorted(STUB_TREE.items())]
    synth['append_only'] = {rel: [line_key(l) for l in text.split('\n')] for rel, text in STUB_APPEND.items()}
    synth['vectors_base'] = sha(STUB_VECTORS_BASE.encode('utf-8'))
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
            extra = tmp / 'features/me/src/main/ets/SettingsExtra.ets'
            extra.write_text('export const E: number = 1;\n', encoding='utf-8')
        else:
            p.write_text(original.replace(old, new), encoding='utf-8')
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


def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        base = build_stub_tree(tmp)
        got = check_source(tmp, base)
        if got:
            print('ME12WA_SELF_TEST_FAIL 参考桩树不该有违反项：', *got, sep='\n  ')
            return 1
        # 正向对照：只许追加的文件追加一行、visualSettings 本身改值，都不该报（G2 / G5 不误伤）。
        for rel, add in [('entry/src/staging/ets/variant/DebugFakeMe.ets', "const NEW_SCENE: string = 'shot';\n"),
                         ('common/core/src/main/ets/me/MeDraftTexts.ets', '// 追加\n')]:
            p = tmp / rel
            original = p.read_text(encoding='utf-8')
            p.write_text(original + add, encoding='utf-8')
            if check_source(tmp, base):
                failures.append('[参考桩] 只许追加的 ' + rel + ' 追加一行被误报')
            p.write_text(original, encoding='utf-8')
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
                ('[真]主页行回到 MeRow', VIEW, 'SettingsNavRow(', 'MeRow('),
                ('[真]半屏遮罩去掉令牌', VIEW, 'CouliColors.overlayScrim', 'CouliColors.backgroundSurface'),
                ('[真]守卫区被改', VIEW, "options.returnFocusId = 'settings_clear_cache';", "options.returnFocusId = 'settings_scroll';"),
                ('[真]回调体被改', VIEW, "p['type'] = 'privacy';", "p['type'] = 'agreement';"),
                ('[真]MeKit 被改', 'features/me/src/main/ets/MeKit.ets', 'export struct MeRow {', 'export struct MeRow  {'),
                ('[真]私有件读 config', PARTS, '@ComponentV2', "import { SettingsPageConfig } from './SettingsView';\n@ComponentV2"),
                ('[真]30415 红底条', VIEW, "'nickname_message'", "'nickname_message', tone: 'error'"),
                ('[真]去设置多一处', VIEW, OPEN_SYSTEM, OPEN_SYSTEM + ';' + OPEN_SYSTEM),
            ]
            failures += run_mutants(tmp, '真实实现', None, real, True)
    if failures:
        print('ME12WA_SELF_TEST_FAIL', *failures, sep='\n  ')
        return 1
    print('ME12WA_SELF_TEST_OK %d 种错误实现全部拦下（参考桩层；真实实现层见上）' % len(MUTANTS))
    return 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    found = check_source(ROOT)
    for f in found:
        print(f)
    print('ME12WA_HOST_OK' if not found else 'ME12WA_HOST_FAIL %d 项' % len(found))
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
