#!/usr/bin/env python3
"""APP-12v-harmony（「我的」Tab 视觉）宿主检查（测试作者 v1）。依据 NATIVE/APP-12v/brief-harmony.md §3、§4、§5（H-M01 / H-M03 / H-M05 / H-M06 /
H-M08 / H-M09 按推荐）。只用 Python 3 标准库；不调 git（基线是仓库里的 fixture，其 sha256 钉在本文件里，改 fixture 即红）。

检查项：
  G1 逻辑文件 sha256 与 REV（c782ca8） 一致（§3.1：MeControllers / MePresentation / MeSession / MeJson / CustomerService、AppMe / MePages /
     AppCsSheet / AppMeTexts、AppClipboard、MeKit）
  G2 只许新增行：MeDraftTexts.ets、core Index.ets（c782ca8 的每一行按原顺序仍在）
  G3 common/designsystem 清单内文件零改动（H-M07；D10-951 ② 从整树收窄为 fixture tree 里的 2 项，frozen_deps.py 按 import 图实算）
  G4 MeTabView 守卫区（§3.2）与 REV（c782ca8） 逐字节一致：MeTabConfig / MeTabModel / GridCell 三个类；aboutToAppear / apply / refreshGuideBar /
     member / cells / tapCell / inviteCode / fen / amountText / amountSpoken / copyCode；build 的两个分支条件、Refresh 的 refreshing /
     pullToRefresh / onRefreshing；各可点控件回调体（只认 MeTabView 里，子组件不得读 config / controller）
  A1 H-M01：entry 三处自动入口（onRootShown「我的」、onAppForeground、navigationShown）只调 autoLoad()；「我的」页源码不调 load()
  S1–S10 视觉静态规则：标题 / 预估数值用 title（不再 heading）；无 LoadingProgress、有骨架与 me.loading；功能图标全部 SymbolGlyph（不用
     CouliIcon），宫格 10 格各映射到 sys.symbol.*、收益看板 = histogram、钟表 = clock，SymbolGlyph 字号用 vp；空组按 MeGridGroups；
     降列按 MeGridColumns + 量宽；引导条 MeGuideText.split + Span + backgroundMuted（不再警告色）；隐藏切换按 MeMaskAnnounce 播报、
     余额卡 ForEach 键不带 masked；刷新失败按 MeNoticeAnnounce 播报；MeTabParts 不读 config / controller
  W5 core Index 导出五个新类；草稿 me.amount_shown「金额已显示」/ me.loading「加载中」（TODO(CT-16f)）
  W8 staging 假服务：GET /v1/me 计数 me.get_count 与设备用例要的场景词；main / release 源码不得引用
  C1 设备名单三处一致；C2 verify 第六个 entry 设备步 entry-me12v、主步排除 Me12vUi、名单登记、device-test 认 me12v；C3 单测登记
  S11 测试 v3（评审 S2-5）：core 单测 pageCellGroups 照抄的 MeTabView.cells() 过滤条件与守卫 fixture method.cells 逐字一致、条件数相同，
     且对比用例 me12v_grid_groups_match_page_cells_rule_on_all_vectors 在（cells 是 private，单测调不到，靠此对齐两处口径）

用法：
  check_me_visual.py               本仓库
  check_me_visual.py --self-test   层一：参考桩树（逻辑文件为合成件、基线随之合成；MeTabView 守卫区用真实 c782ca8 fixture）全过 + 每种错误实现
                                   各自打红（定位串必须恰好一次）；层二：本仓库检查通过时把真实文件拷出再逐个变异（未通过时跳过并说明）
"""
import hashlib
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
# v1b（2026-11-03，本线变基到 c782ca8 = HM-CLIP-BATCH 合并点）：基线改钉 c782ca8，断言不变（D10-378「只换基线值」）。
REV = 'c782ca8'
LOGIC_FIXTURE = 'tools/ci/me12v/fixtures/logic-baseline-' + REV + '.json'
GUARD_FIXTURE = 'tools/ci/me12v/fixtures/me-tab-guard-' + REV + '.json'
# fixture 指纹（make_baseline.py 由 git show REV（c782ca8） 生成；改 fixture 来迁就实现即红）。
FIXTURE_SHA256 = {
    LOGIC_FIXTURE: '2ed75f6b59b450e4c1cb6ff8afa4d89200deef1d8bdffce3b33172be882b2f2e',
    GUARD_FIXTURE: '5ec789384a0b6075b9e8ce15aa71a9075947a59d23f54f50da6631781b8ab42b',
}

ME_TAB_VIEW = 'features/me/src/main/ets/MeTabView.ets'
ME_TAB_PARTS = 'features/me/src/main/ets/MeTabParts.ets'
APP_ME = 'entry/src/main/ets/me/AppMe.ets'
DRAFTS = 'common/core/src/main/ets/me/MeDraftTexts.ets'
CORE_INDEX = 'common/core/Index.ets'
STRICT_FILES = [
    'common/core/src/main/ets/me/MeControllers.ets', 'common/core/src/main/ets/me/MePresentation.ets',
    'common/core/src/main/ets/me/MeSession.ets', 'common/core/src/main/ets/me/MeJson.ets',
    'common/core/src/main/ets/me/CustomerService.ets',
    APP_ME, 'entry/src/main/ets/me/MePages.ets', 'entry/src/main/ets/me/AppCsSheet.ets', 'entry/src/main/ets/me/AppMeTexts.ets',
    'entry/src/main/ets/clipboard/AppClipboard.ets', 'features/me/src/main/ets/MeKit.ets',
]
APPEND_ONLY = [DRAFTS, CORE_INDEX]
# FU-HM-G1-SYSTEM-CONTROLS（D10-951 ② / #24）：designsystem 不再整树冻结，只守 fixture tree 里的清单文件（tools/ci/system-controls/frozen_deps.py 实算）。
TREE_DIRS = []
SKIP_PARTS = {'src/test', 'src/ohosTest', 'build', '.test', 'oh_modules', '.hvigor', '.preview', 'node_modules'}
GUARD_CLASSES = ['MeTabConfig', 'MeTabModel', 'GridCell']
GUARD_METHODS = ['aboutToAppear', 'apply', 'refreshGuideBar', 'member', 'cells', 'tapCell', 'inviteCode', 'fen', 'amountText',
                 'amountSpoken', 'copyCode']
# build 里的分支条件与 Refresh 参数（整行去掉缩进后逐字节）。
GUARD_LINES = {
    'build.error_if': 'if (this.member() && this.model.phase === MePhase.ERROR) {',
    'build.loading_if': '} else if (this.member() && this.model.phase !== MePhase.CONTENT) {',
    'build.refresh': 'Refresh({ refreshing: this.model.refreshing }) {',
    'build.pull': '.pullToRefresh(this.member() && !this.model.blocked)',
}
# 各可点控件的回调体（去空白后必须出现在 MeTabView 里；子组件不得自己持有这些调用）。
CALLBACKS = {
    'bell': "this.config.open('Messages',{},bound.identity);",
    'guide_body': 'this.config.openSystemNotificationSettings()',
    'guide_close': 'this.config.closeGuideBar(bound.identity);this.model.guideBar=false;',
    'copy': 'this.copyCode(bound);',
    'withdraw': "this.config.open('Wallet',{},bound.identity);",
    'grid': 'this.tapCell(cell)',
    'login': 'this.config.login()',
    'mask': 'this.maskUi.toggle()',
}
RETRY_CALL = 'this.config.controller.retry();'
NEW_EXPORTS = ['MeGuideText', 'MeGuideParts', 'MeGridColumns', 'MeMaskAnnounce', 'MeNoticeAnnounce', 'MeGridGroups']
GRID_KEYS = ['me.grid.orders', 'me.grid.wallet', 'me.grid.ledger', 'me.grid.find_order', 'me.grid.invite', 'me.grid.earnings',
             'me.grid.help', 'me.grid.cs', 'me.grid.auth', 'me.grid.settings']
STAGING_SCENES = ['slow', 'refresh_fail', 'offline', 'long', 'earnings', 'new_user', 'negative', 'rate']
COUNTER = 'me.get_count'
SKELETON_IDS = ['me_skeleton', 'me_skeleton_identity', 'me_skeleton_identity_avatar', 'me_skeleton_balance', 'me_skeleton_grid']
DEVICE_IDS = ['me_page', 'me_title', 'me_guest_card', 'me_guest_avatar', 'me_identity_card', 'me_balance_card',
              'me_withdrawable_label', 'me_estimated_block', 'me_guide', 'me_grid_group_']


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


def tree_member(rel):
    parts = rel.split('/')
    for i in range(len(parts)):
        if '/'.join(parts[i:i + 2]) in SKIP_PARTS or parts[i] in SKIP_PARTS:
            return False
    return True


def match_close(text, start, open_ch='{', close_ch='}'):
    """text[start] 是 open_ch；返回配对 close_ch 的下标（跳过 '…' / "…" 字符串与注释）。找不到为 -1。"""
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
    m = re.search(r'(?m)^[ \t]*(?:(?:private|public|protected|static|async)\s+)*' + name + r'\s*\([^)]*\)\s*(?::\s*[^{;]+)?\{', text)
    if not m:
        return None
    end = match_close(text, m.end() - 1)
    return None if end < 0 else text[m.start():end + 1]


def on_refreshing(text):
    at = text.find('.onRefreshing(')
    if at < 0:
        return None
    end = match_close(text, at + len('.onRefreshing'), '(', ')')
    if end < 0:
        return None
    return '\n'.join(line.strip() for line in text[at:end + 1].split('\n'))


def guard_symbols(view):
    out = {}
    for name in GUARD_CLASSES:
        out['class.' + name] = class_text(view, name)
    for name in GUARD_METHODS:
        out['method.' + name] = method_text(view, name)
    out['build.onRefreshing'] = on_refreshing(view)
    return out


def product_sources(root):
    out = []
    for top in ['entry/src/main', 'entry/src/release', 'common', 'features']:
        base = root / top
        if not base.is_dir():
            continue
        for p in sorted(base.rglob('*.ets')):
            rel = p.relative_to(root).as_posix()
            if '/src/test/' in rel or '/src/ohosTest/' in rel or '/src/staging/' in rel or rel.startswith('common/generated/'):
                continue
            out.append(p)
    return out


def load_fixture(root, rel):
    p = root / rel
    if not p.is_file():
        return None, 'fixture 缺失 ' + rel
    data = p.read_bytes()
    want = FIXTURE_SHA256.get(rel)
    if want is not None and sha(data) != want:
        return None, 'fixture 被改 ' + rel + '（sha256 ' + sha(data)[:12] + ' ≠ 钉住的 ' + str(want)[:12] + '）'
    return json.loads(data.decode('utf-8')), None


# ---------------------------------------------------------------- 检查

def check_logic(root, logic):
    v = []
    for rel, want in sorted(logic['strict'].items()):
        p = root / rel
        if not p.is_file():
            v.append('G1 逻辑文件缺失 ' + rel)
        elif sha(p.read_bytes()) != want:
            v.append('G1 逻辑文件被改 ' + rel + '（§3.1 合入前后 sha256 必须一致）')
    for rel, keys in sorted(logic['append_only'].items()):
        now = [line_key(l) for l in read(root, rel).split('\n')]
        i = 0
        for k in now:
            if i < len(keys) and k == keys[i]:
                i += 1
        if i < len(keys):
            v.append('G2 ' + rel + ' 只许新增行：' + REV + ' 的第 %d 行被改 / 删 / 挪位' % (i + 1))
    tree = {rel: s for s, rel in logic['tree']}  # fixture 里是 [摘要, 路径] 对（摘要在前：避免 gitleaks 把「…Tokens.ets": "<hex>"」当成密钥）
    for top in TREE_DIRS:
        want = {rel: s for rel, s in tree.items() if rel.startswith(top + '/')}
        base = root / top
        now = {}
        if base.is_dir():
            for p in base.rglob('*'):
                rel = p.relative_to(root).as_posix()
                if p.is_file() and tree_member(rel):
                    now[rel] = sha(p.read_bytes())
        for rel in sorted(set(want) | set(now)):
            if want.get(rel) != now.get(rel):
                v.append('G3 ' + top + ' 产品源码有改动（H-M07 推荐零改动）：' + rel)
    # FU-HM-G1-SYSTEM-CONTROLS（D10-951 ② / #24）：designsystem（me12wa 另有 staging）不再整树冻结，只守 fixture tree 里不属于任何整树的清单文件（frozen_deps.py 实算）；清单外增删改不报。
    covered = tuple(t + '/' for t in TREE_DIRS)
    for rel, want_sha in sorted(tree.items()):
        if rel.startswith(covered):
            continue
        p = root / rel
        if not p.is_file():
            v.append('G3 清单内文件被删：' + rel)
        elif sha(p.read_bytes()) != want_sha:
            v.append('G3 清单内文件被改：' + rel)
    return v


def check_guard(root, guard):
    v = []
    view = read(root, ME_TAB_VIEW)
    now = guard_symbols(view)
    for name, text in sorted(guard['symbols'].items()):
        if now.get(name) != text:
            v.append('G4 MeTabView 守卫区被改：' + name + '（§3.2 与 ' + REV + ' 逐字节一致）')
    flat = [line.strip() for line in view.split('\n')]
    for name, line in GUARD_LINES.items():
        if line not in flat:
            v.append('G4 MeTabView 守卫区被改：' + name + '（缺这一行：' + line + '）')
    body = squash(strip_comments(view))
    for name, call in CALLBACKS.items():
        if call not in body:
            v.append('G4 回调体被改或挪出 MeTabView：' + name + '（' + call + '）')
    if body.count(RETRY_CALL) < 2:
        v.append('G4 回调体被改：两处【重试】（刷新失败条、整页错误）必须仍是 ' + RETRY_CALL)
    parts = strip_comments(read(root, ME_TAB_PARTS))
    if parts:
        for bad in ['config.', 'controller', 'MeTabConfig', 'copyCode', '.toggle(', 'AppClipboard', 'AppMe']:
            if bad in parts:
                v.append('S10 MeTabParts 子组件读了 ' + bad + '（只接收渲染时的值与 @Event 回调，§3.2）')
    return v


def me_sources(root):
    return strip_comments(read(root, ME_TAB_VIEW)) + '\n' + strip_comments(read(root, ME_TAB_PARTS))


def resolve_symbol(src, value, depth=0):
    """icon() 的返回值 → sys.symbol 名：直接 $r('sys.symbol.X')，或字符串 'k' 再经某个 case 'k': return $r('sys.symbol.X') 解析。"""
    m = re.fullmatch(r"\$r\('sys\.symbol\.([a-z0-9_]+)'\)", value.strip())
    if m:
        return m.group(1)
    m = re.fullmatch(r"'([^']+)'", value.strip())
    if not m or depth > 2:
        return None
    for cm in re.finditer(r"case\s+'" + re.escape(m.group(1)) + r"'\s*:\s*(?:case\s+'[^']*'\s*:\s*)*return\s+([^;]+);", src):
        got = resolve_symbol(src, cm.group(1), depth + 1)
        if got:
            return got
    return None


def grid_symbols(src):
    """icon() 映射：每个宫格键 → sys.symbol 名（default 分支给没列出的键）。"""
    body = method_text(src, 'icon') or ''
    out = {}
    default = None
    dm = re.search(r'default\s*:\s*return\s+([^;]+);', body)
    if dm:
        default = resolve_symbol(src, dm.group(1))
    for key in GRID_KEYS:
        m = re.search(r"case\s+'" + re.escape(key) + r"'\s*:\s*(?:case\s+'[^']*'\s*:\s*)*return\s+([^;]+);", body)
        out[key] = resolve_symbol(src, m.group(1)) if m else default
    return out


def check_static(root):
    v = []
    src = me_sources(root)
    view = strip_comments(read(root, ME_TAB_VIEW))
    # S1 标题 22 / 预估数值 22：title，不再有 heading（28）。
    if 'CouliTypography.heading' in src:
        v.append('S1 「我的」页仍用 CouliTypography.heading（28/600；标题与预估数值应为 title 22/600）')
    if 'CouliTypography.title' not in src:
        v.append('S1 「我的」页没用 CouliTypography.title')
    # S2 骨架（H-M02 / HM15）。
    if 'LoadingProgress' in src:
        v.append('S2 「我的」页仍有 LoadingProgress 转圈（应为静态骨架）')
    for sid in SKELETON_IDS:
        if "'" + sid + "'" not in src:
            v.append('S2 骨架缺 id ' + sid)
    if "'me.loading'" not in src:
        v.append("S2 骨架读屏没用草稿 me.loading")
    # S3 功能图标 HarmonyOS Symbol（H-M03 / D10-559）。
    if re.search(r'\bCouliIcon\s*\(', src):
        v.append('S3 「我的」页仍用 CouliIcon 自绘图标（H-M03：宫格、钟表、铃铛、复制、眼睛、关闭、头像全部 SymbolGlyph）')
    if 'SymbolGlyph(' not in src:
        v.append('S3 「我的」页没有 SymbolGlyph')
    symbols = grid_symbols(src)
    for key, name in symbols.items():
        if name is None:
            v.append('S3 宫格 ' + key + ' 没映射到 $r(\'sys.symbol.*\')')
    if symbols.get('me.grid.earnings') != 'histogram':
        v.append('S3 收益看板图标应是 sys.symbol.histogram（柱状），实际 ' + str(symbols.get('me.grid.earnings')))
    named = [n for n in symbols.values() if n]
    if len(set(named)) != len(named):
        v.append('S3 宫格有两个格用了同一个 Symbol：' + ', '.join(sorted(named)))
    if "'sys.symbol.clock" not in src:
        v.append('S3 预估块钟表应是 sys.symbol.clock')
    for m in re.finditer(r'SymbolGlyph\s*\(', src):
        tail = src[m.end():m.end() + 400]
        nxt = re.search(r'SymbolGlyph\s*\(', tail)
        tail = tail[:nxt.start()] if nxt else tail
        fs = re.search(r'\.fontSize\(([^)]*)\)', tail)
        if not fs or 'vp' not in fs.group(1):
            v.append('S3 SymbolGlyph 字号必须用 vp（不随字号放大）：' + (fs.group(0) if fs else '没设 fontSize'))
            break
    # S4 空组（H-M09）、S5 降列（H-M08）。
    if 'MeGridGroups.visible(' not in src:
        v.append('S4 宫格分组显隐没走 MeGridGroups.visible（空组仍会画卡）')
    if 'MeGridColumns.count(' not in src:
        v.append('S5 宫格列数没走 MeGridColumns.count（200% 不降列）')
    if not re.search(r'measureText|MeasureText', src):
        v.append('S5 降列没量格名宽（MeasureText / getMeasureUtils().measureText）')
    # S6 引导条（HM3 / HM4 / G-M10）。
    if 'MeGuideText.split(' not in src or not re.search(r'\bSpan\s*\(', src):
        v.append('S6 引导条没按 MeGuideText.split 切成 Span（句尾「去开启」链接样式）')
    if re.search(r'statusWarning(Background|Text)', src):
        v.append('S6 「我的」页仍用警告色（引导条应为 backgroundMuted 底、次文字色图标、主文字）')
    if 'backgroundMuted' not in src:
        v.append('S6 引导条底色没用 backgroundMuted')
    # S7 隐藏切换（G-M13 / H-M06）。
    if 'MeMaskAnnounce.key(' not in src or 'CouliAnnounce.say(' not in src:
        v.append('S7 点眼睛后没按 MeMaskAnnounce.key 播报（G-M13）')
    if re.search(r"'me_balance_'[^\n]*masked", src):
        v.append('S7 余额卡 ForEach 键仍带 masked（切换即整卡重建、读屏焦点丢失，H-M06）')
    # S8 刷新失败播报（H-M05）。
    if 'MeNoticeAnnounce.next(' not in src:
        v.append('S8 刷新失败提示条出现时没按 MeNoticeAnnounce.next 播报（H-M05）')
    # S9 设备用例依赖的稳定 id。
    for did in DEVICE_IDS:
        if "'" + did not in src:
            v.append('S9 缺设备用例依赖的 id ' + did)
    # A1 H-M01：entry 三处自动入口只走 autoLoad；「我的」页不调 load()。
    app = strip_comments(read(root, APP_ME))
    roots = re.search(r"ShellState\.onRootShown\s*=.*?if\s*\(destination\.route\s*===\s*'Me'\)\s*\{(.*?)\}", app, flags=re.S)
    if not roots or squash(roots.group(1)) != 'this.tab().autoLoad();':
        v.append('A1 进入「我的」Tab（onRootShown）必须只调 tab().autoLoad()（受限会话不读）')
    for name in ['onAppForeground', 'navigationShown']:
        body = method_text(app, name) or ''
        if 'autoLoad()' not in body or re.search(r'\.load\(\)', body):
            v.append('A1 ' + name + ' 读「我的」必须走 autoLoad()，不得 load()')
    if re.search(r'\.load\(\)', src):
        v.append('A1 「我的」页源码调了 load()（自动路径必须 autoLoad；下拉 / 重试走 refresh / retry）')
    if 'autoLoad' in src:
        v.append('A1 「我的」页源码不应自己发自动读取（入口在 entry，不改接线）')
    return v


def check_exports_and_staging(root):
    v = []
    index = read(root, CORE_INDEX)
    for name in NEW_EXPORTS:
        if not re.search(r'\b' + name + r'\b', index):
            v.append('W5 core Index 未导出 ' + name)
    drafts = read(root, DRAFTS)
    for key, text in [('me.amount_shown', '金额已显示'), ('me.loading', '加载中')]:
        if not re.search(r"m\.set\('" + re.escape(key) + r"',\s*'" + text + r"'\)", drafts):
            v.append('W5 草稿表缺 ' + key + '「' + text + '」')
    if 'CT-16f' not in drafts:
        v.append('W5 新草稿要标 TODO(CT-16f)')
    staging = ''.join(p.read_text(encoding='utf-8') for p in sorted((root / 'entry/src/staging').rglob('*.ets'))) \
        if (root / 'entry/src/staging').is_dir() else ''
    fake_me = read(root, 'entry/src/staging/ets/variant/DebugFakeMe.ets')
    if "'" + COUNTER + "'" not in staging:
        v.append('W8 staging 缺 GET /v1/me 计数 ' + COUNTER + '（设备用例依赖）')
    for scene in STAGING_SCENES:
        if "'" + scene + "'" not in fake_me:
            v.append('W8 DebugFakeMe 缺场景 ' + scene)
    for p in product_sources(root):
        text = p.read_text(encoding='utf-8')
        if COUNTER in text:
            v.append('W8 ' + p.relative_to(root).as_posix() + ' 在 main / release 源码里引用调试计数 ' + COUNTER)
    return v


def check_registration(root):
    v = []
    suite = read(root, 'entry/src/ohosTest/ets/test/Me12vUi.test.ets')
    listed = re.findall(r"'(me12v_\d\d_[a-z0-9_]+)'", suite.split('];')[0]) if suite else []
    its = len(re.findall(r'\bit\(ME12V_DEVICE_CASES\[\d+\]', suite))
    fixture = [l.strip() for l in read(root, 'tools/ci/me12v/fixtures/device-cases.txt').splitlines()
               if l.strip() and not l.startswith('#')]
    if not listed or listed != fixture or len(set(listed)) != len(listed) or its != len(listed):
        v.append('C1 设备名单三处不一致（ME12V_DEVICE_CASES / device-cases.txt / it 数）')
    if "describe('Me12vUi'" not in suite:
        v.append('C1 describe 名必须是 Me12vUi（verify 按 class 过滤）')
    verify = read(root, 'tools/ci/verify.sh')
    tails = [line.split()[-3:] for line in verify.splitlines() if line.strip().startswith('run_device_tests entry ')]
    main_ok = any(t[0] == 'entry' and t[2] == 'main' and t[1].startswith('notClass=') and 'Me12vUi' in t[1].split('=', 1)[1].split(',')
                  for t in tails)
    if not main_ok:
        v.append('C2 verify 主 entry 步必须排除 Me12vUi')
    if ['entry-me12v', 'class=Me12vUi', 'me12v'] not in tails:
        v.append('C2 verify 缺单独设备步 entry-me12v class=Me12vUi me12v')
    if 'check_me_visual.py" --self-test' not in verify or 'me12v/run-logic.cjs"' not in verify or 'me12v/check-arkts.cjs" --real' not in verify:
        v.append('C2 verify 缺 APP-12v 宿主检查步（自测 / run-logic / ArkTS --real）')
    if 'me12v/fixtures/device-cases.txt' not in read(root, 'tools/ci/ds02/check_device_result.py'):
        v.append('C2 check_device_result.py 缺 me12v 名单')
    if not re.search(r'main\|hm07va\|hm07vb\|hm05r\|(?:[a-z0-9]+\|)*me12v\|(?:[a-z0-9]+\|)*all\)', read(root, 'tools/ci/device-test.sh')):
        v.append('C2 device-test.sh 不认 COULI_HM_DEVICE_SET=me12v')
    if not re.search(r'^\s*me12vVisualTest\(\);', strip_comments(read(root, 'common/core/src/test/List.test.ets')), flags=re.M):
        v.append('C3 core List.test.ets 未登记 me12vVisualTest()')
    entry_list = strip_comments(read(root, 'entry/src/ohosTest/ets/test/List.test.ets'))
    a, b = entry_list.find('me12vUiTest();'), entry_list.find('hm07vHomeUiTest();')
    if a < 0 or b < 0 or a > b:
        v.append('C3 entry List.test.ets 须登记 me12vUiTest()，且在 hm07vHomeUiTest() 之前（HM-07v-a C3 最后注册）')
    return v


CORE_VISUAL_TEST = 'common/core/src/test/Me12vVisual.test.ets'
CELLS_RULE = ["if (c['group'] !== group) {", "const key: string | null = MeDraftTexts.gridKey(c['item'] as string);",
              'if (key === null) {']


def check_cells_rule(root, guard):
    """S11：单测里照抄的 cells() 过滤口径与守卫区 method.cells 一致（G4 另守 MeTabView.cells 与 fixture 逐字节一致）。"""
    v = []
    cells = squash(strip_comments(guard['symbols'].get('method.cells', '')))
    test = read(root, CORE_VISUAL_TEST)
    m = re.search(r'function pageCellGroups\(.*?// PAGE_CELLS_RULE 结束', test, flags=re.S)
    body = squash(strip_comments(m.group(0))) if m else ''
    if not body:
        v.append('S11 core 单测缺 pageCellGroups（MeTabView.cells 口径照抄）')
        return v
    for line in CELLS_RULE:
        if squash(line) not in cells:
            v.append('S11 守卫 fixture method.cells 里没有这条过滤条件：' + line)
        if squash(line) not in body:
            v.append('S11 单测 pageCellGroups 与页面 cells() 口径不一致：缺 ' + line)
    if body.count('continue;') != cells.count('continue;'):
        v.append('S11 单测 pageCellGroups 与页面 cells() 的过滤条件数不同')
    if "'me12v_grid_groups_match_page_cells_rule_on_all_vectors'" not in test:
        v.append('S11 core 单测缺 MeGridGroups.visible 与 cells() 口径的全量对比用例')
    return v


def check_source(root, logic=None, guard=None):
    v = []
    if logic is None:
        logic, err = load_fixture(root, LOGIC_FIXTURE)
        if err:
            v.append('G0 ' + err)
    if guard is None:
        guard, err = load_fixture(root, GUARD_FIXTURE)
        if err:
            v.append('G0 ' + err)
    if logic is not None:
        v += check_logic(root, logic)
    if guard is not None:
        v += check_guard(root, guard)
        v += check_cells_rule(root, guard)
    v += check_static(root)
    v += check_exports_and_staging(root)
    v += check_registration(root)
    return v


# ---------------------------------------------------------------- 自测

def reference_view(guard):
    """参考 MeTabView：守卫区原文（c782ca8 fixture）+ 按 §3 写法的最小视图片段（不可编译，只给静态检查用）。"""
    s = guard['symbols']
    parts = [
        "import { MeGridColumns, MeGridGroups, MeGuideText, MeMaskAnnounce, MeNoticeAnnounce } from 'core';",
        s['class.MeTabConfig'], '', '@ObservedV2', s['class.MeTabModel'], '', s['class.GridCell'], '',
        '@ComponentV2', 'export struct MeTabView {',
        s['method.aboutToAppear'], s['method.apply'], s['method.refreshGuideBar'], s['method.member'],
        "  private icon(item: string): string {\n    switch (item) {\n"
        "      case 'me.grid.orders':\n        return 'orders';\n      case 'me.grid.wallet':\n        return 'wallet';\n"
        "      case 'me.grid.ledger':\n        return 'ledger';\n      case 'me.grid.find_order':\n        return 'find';\n"
        "      case 'me.grid.invite':\n        return 'invite';\n      case 'me.grid.earnings':\n        return 'earnings';\n"
        "      case 'me.grid.help':\n        return 'help';\n      case 'me.grid.cs':\n        return 'cs';\n"
        "      case 'me.grid.auth':\n        return 'auth';\n      default:\n        return 'settings';\n    }\n  }",
        s['method.cells'], s['method.tapCell'], s['method.inviteCode'], s['method.fen'], s['method.amountText'],
        s['method.amountSpoken'], s['method.copyCode'],
        "  @Builder header() { Text(this.t('me.title')).id('me_title').attributeModifier(new M(CouliTypography.title)) }",
        "  @Builder bell(bound: Bound) { Button() { SymbolGlyph($r('sys.symbol.bell')).fontSize('24vp') }.id('me_bell')\n"
        "    .onClick(() => {\n      this.config.open('Messages', {}, bound.identity);\n    }) }",
        "  @Builder guideBar(bound: Bound) { Row() { Text() { Span(MeGuideText.split(t).head) } .id('me_guide_bar')\n"
        "    .onClick(() => this.config.openSystemNotificationSettings())\n"
        "    Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize('20vp') }.id('me_guide_bar_close').onClick(() => {\n"
        "      this.config.closeGuideBar(bound.identity);\n      this.model.guideBar = false;\n    }) }.id('me_guide')\n"
        "    .backgroundColor(CouliColors.backgroundMuted) }",
        "  @Builder identityCard(bound: Bound) { Column() { SymbolGlyph($r('sys.symbol.person')).fontSize('32vp') }"
        ".id('me_identity_card')\n    Button() { SymbolGlyph($r('sys.symbol.square_on_square')).fontSize('16vp') }.onClick(() => {\n"
        "      this.copyCode(bound);\n    }) }",
        "  @Builder balanceCard(bound: Bound) { Text('').id('me_withdrawable_label') Button() {\n"
        "    SymbolGlyph($r('sys.symbol.eye')).fontSize('20vp') }.onClick(() => {\n      const before: boolean = this.maskUi.masked;\n"
        "      this.maskUi.toggle();\n      const key: string | null = MeMaskAnnounce.key(before, this.maskUi.masked);\n"
        "      if (key !== null) {\n        CouliAnnounce.say(this.getUIContext(), this.t(key));\n      }\n    })\n"
        "    Button().onClick(() => {\n      this.config.open('Wallet', {}, bound.identity);\n    })\n"
        "    Row() { SymbolGlyph($r('sys.symbol.clock')).fontSize('14vp') }.id('me_estimated_block') }.id('me_balance_card')",
        "  @Builder gridCard(cells: GridCell[]) { ForEach(cells, (cell: GridCell) => { Column() {\n"
        "    SymbolGlyph(this.symbol(cell.icon)).fontSize('24vp') }.onClick(() => this.tapCell(cell)) }) }",
        "  private symbol(name: string): Resource {\n    switch (name) {\n      case 'orders':\n        return $r('sys.symbol.doc_plaintext');\n"
        "      case 'wallet':\n        return $r('sys.symbol.wallet');\n      case 'ledger':\n        return $r('sys.symbol.list_bullet');\n"
        "      case 'find':\n        return $r('sys.symbol.magnifyingglass');\n      case 'invite':\n"
        "        return $r('sys.symbol.person_badge_plus');\n      case 'earnings':\n        return $r('sys.symbol.histogram');\n"
        "      case 'help':\n        return $r('sys.symbol.questionmark_circle');\n      case 'cs':\n        return $r('sys.symbol.headphones');\n"
        "      case 'auth':\n        return $r('sys.symbol.checkmark_shield');\n      case 'settings':\n        return $r('sys.symbol.gearshape');\n"
        "      default:\n        return $r('sys.symbol.gearshape');\n"
        "    }\n  }",
        "  private columns(w: number): number { return MeGridColumns.count(w, this.getUIContext().getMeasureUtils().measureText({})); }",
        "  private groups(): string[] { return MeGridGroups.visible(this.model.view, MeGridGroups.MEMBER_ORDER); }",
        "  @Monitor('model.refreshError') onRefreshError(): void { const s: string | null = MeNoticeAnnounce.next(this.lastNotice, "
        "this.model.refreshError); }",
        "  @Builder guestCard() { Column() { Row() {}.id('me_guest_avatar') Button().onTap(() => this.config.login()) }.id('me_guest_card') }",
        "  @Builder skeleton() { Column() { Column() { Circle().id('me_skeleton_identity_avatar') }.id('me_skeleton_identity')\n"
        "    Column().id('me_skeleton_balance') Column().id('me_skeleton_grid') }.id('me_skeleton')"
        ".accessibilityText(this.t('me.loading')) }",
        "  @Builder memberBody() {\n    MeNoticeBar({ onTap: () => {\n          this.config.controller.retry();\n        } })\n"
        "    ForEach([b], (b: Bound) => { this.balanceCard(b) }, (b: Bound) => 'me_balance_' + b.id)\n"
        "    Column().id('me_grid_group_' + g)\n  }",
        "  build() {\n    Column() {\n      this.header()\n      if (this.member() && this.model.phase === MePhase.ERROR) {\n"
        "        ErrorState({ onRetry: () => {\n            this.config.controller.retry();\n          } })\n"
        "      } else if (this.member() && this.model.phase !== MePhase.CONTENT) {\n        this.skeleton()\n      } else {\n"
        "        Refresh({ refreshing: this.model.refreshing }) {\n          Scroll(this.scroller) {}\n        }\n"
        "        .pullToRefresh(this.member() && !this.model.blocked)\n" + indent(s['build.onRefreshing'], 8) + "\n"
        "      }\n    }.id('me_page')\n  }",
        '}', '',
    ]
    return '\n'.join(parts)


def indent(text, n):
    return '\n'.join(' ' * n + line for line in text.split('\n'))


REF_APP_ME = (
    "    ShellState.onRootShown = (destination: RouteDestination): void => {\n      previous(destination);\n"
    "      if (destination.route === 'Me') {\n        this.tab().autoLoad();\n      }\n    };\n"
    "  onAppForeground(): void {\n    if (v !== null) {\n      v();\n    } else if (x) {\n      this.tab().autoLoad();\n    }\n  }\n"
    "  navigationShown(names: string[]): void {\n    if (names.length === 0 && this.tabInstance !== null) {\n"
    "      this.tabInstance.autoLoad();\n    }\n  }\n")
REF_STRICT = {rel: ('// 参考桩：' + rel + '\nexport const X: number = 1;\n') for rel in STRICT_FILES if rel != APP_ME}
REF_STRICT[APP_ME] = REF_APP_ME
REF_FILES = {
    DRAFTS: "export class MeDraftTexts {\n    m.set('me.amount_hidden', '金额已隐藏');\n"
            "    // TODO(CT-16f) 待契约补键\n    m.set('me.amount_shown', '金额已显示');\n    m.set('me.loading', '加载中');\n}\n",
    CORE_INDEX: "export { MeDraftTexts } from './src/main/ets/me/MeDraftTexts';\n"
                "export { " + ', '.join(NEW_EXPORTS) + " } from './src/main/ets/me/MeTabVisual';\n",
    'common/designsystem/src/main/ets/Colors.ets': 'export const C: number = 1;\n',
    'common/designsystem/Index.ets': "export { C } from './src/main/ets/Colors';\n",
    'common/designsystem/src/main/ets/components/NotFrozen.ets': 'export const N: number = 1;\n',  # 不进合成基线 tree：清单外正对照
    'entry/src/staging/ets/variant/DebugFakeMe.ets':
        "const COUNTER: string = 'me.get_count';\nconst SCENES: string[] = [" +
        ', '.join("'" + s + "'" for s in STAGING_SCENES) + '];\n',
    'entry/src/main/ets/me/Other.ets': 'export const Y: number = 1;\n',
    ME_TAB_PARTS: '@ComponentV2\nexport struct MeGuideRow {\n  @Param text: string = \'\';\n  @Event onOpen: () => void = () => {};\n}\n',
}
COPY = ['entry/src/ohosTest/ets/test/Me12vUi.test.ets', 'tools/ci/me12v/fixtures/device-cases.txt', 'tools/ci/verify.sh',
        'tools/ci/ds02/check_device_result.py', 'tools/ci/device-test.sh', 'common/core/src/test/List.test.ets',
        'entry/src/ohosTest/ets/test/List.test.ets', GUARD_FIXTURE, CORE_VISUAL_TEST]
V = ME_TAB_VIEW
MUTANTS = [
    # ---- prompt 列的错误实现
    ('标题仍 28（heading）', V, "attributeModifier(new M(CouliTypography.title))", "attributeModifier(new M(CouliTypography.heading))"),
    ('金额切换重建（ForEach 键带 masked）', V, "(b: Bound) => 'me_balance_' + b.id)", "(b: Bound) => 'me_balance_' + b.id + '_' + this.maskUi.masked)"),
    ('200% 不降列', V, 'MeGridColumns.count(w, this.getUIContext().getMeasureUtils().measureText({}))', '4'),
    ('空组仍画卡', V, 'MeGridGroups.visible(this.model.view, MeGridGroups.MEMBER_ORDER)', "['orders_wallet', 'promo', 'more']"),
    ('受限会话自动读（进入 Tab 改 load）', APP_ME, "      if (destination.route === 'Me') {\n        this.tab().autoLoad();",
     "      if (destination.route === 'Me') {\n        this.tab().load();"),
    ('受限会话自动读（回前台改 load）', APP_ME, "    } else if (x) {\n      this.tab().autoLoad();", "    } else if (x) {\n      this.tab().load();"),
    ('受限会话自动读（子页返回改 load）', APP_ME, 'this.tabInstance.autoLoad();', 'this.tabInstance.load();'),
    ('页面自己发 load', V, '  private groups(): string[] {', '  private reload(): void { this.config.controller.load(); }\n  private groups(): string[] {'),
    ('宫格仍自绘图标', V, "SymbolGlyph(this.symbol(cell.icon)).fontSize('24vp')", "CouliIcon({ name: cell.icon, iconSize: 24 })"),
    ('收益看板仍 trend / 非柱状', V, "return $r('sys.symbol.histogram');", "return $r('sys.symbol.chart_line_uptrend');"),
    ('宫格某格没映射到 Symbol', V, "return $r('sys.symbol.wallet');", "return $r('app.media.wallet');"),
    ('SymbolGlyph 用 fp 字号', V, "SymbolGlyph(this.symbol(cell.icon)).fontSize('24vp')", 'SymbolGlyph(this.symbol(cell.icon)).fontSize(24)'),
    ('钟表不是 Symbol', V, "$r('sys.symbol.clock')", "$r('sys.symbol.timer')"),
    ('守卫区被改（copyCode）', V, "    CouliToast.show(ui, this.t(ok ? 'invite.copy_code.done' : 'me.copy_failed'));",
     "    CouliToast.show(ui, this.t('invite.copy_code.done'));"),
    ('守卫区被改（apply）', V, '    m.guideBar = s.level === MeLevel.MEMBER && this.config.guideBarVisible();', '    m.guideBar = true;'),
    ('守卫区被改（MeTabConfig）', V, '  availableRoutes: () => string[] = () => [];', "  availableRoutes: () => string[] = () => ['Earnings'];"),
    ('守卫区被改（build 分支条件）', V, '} else if (this.member() && this.model.phase !== MePhase.CONTENT) {',
     '} else if (this.model.phase !== MePhase.CONTENT) {'),
    ('守卫区被改（pullToRefresh）', V, '.pullToRefresh(this.member() && !this.model.blocked)', '.pullToRefresh(this.member())'),
    ('守卫区被改（onRefreshing）', V, 'if (!this.config.controller.refresh()) {', 'if (!this.config.controller.retry()) {'),
    ('回调体被改（提现去 Withdraw）', V, "this.config.open('Wallet', {}, bound.identity);", "this.config.open('Withdraw', {}, bound.identity);"),
    ('回调体被改（关闭引导条不记时刻）', V, '      this.config.closeGuideBar(bound.identity);\n', ''),
    ('眼睛不再 toggle', V, '      this.maskUi.toggle();\n', '      this.maskUi.masked = !this.maskUi.masked;\n'),
    ('仍是转圈', V, '        this.skeleton()\n', '        LoadingProgress()\n'),
    ('骨架读屏不是 me.loading', V, ".accessibilityText(this.t('me.loading'))", ".accessibilityText('')"),
    ('引导条没切分', V, 'Span(MeGuideText.split(t).head)', 'Span(t)'),
    ('引导条仍警告底', V, '.backgroundColor(CouliColors.backgroundMuted)', '.backgroundColor(CouliColors.statusWarningBackground)'),
    ('隐藏切换不播报', V, '      const key: string | null = MeMaskAnnounce.key(before, this.maskUi.masked);\n', '      const key: string | null = null;\n'),
    ('刷新失败不播报', V, 'MeNoticeAnnounce.next(this.lastNotice, ', 'String(this.lastNotice, '),
    ('子组件读 config', ME_TAB_PARTS, "  @Param text: string = '';", "  @Param text: string = '';\n  @Param config: MeTabConfig;"),
    ('设备 id 缺（me_withdrawable_label）', V, "Text('').id('me_withdrawable_label')", "Text('')"),
    # ---- 逻辑零改动
    ('执行器被改', 'common/core/src/main/ets/me/MeControllers.ets', 'export const X: number = 1;', 'export const X: number = 2;'),
    ('MeKit 默认外观被改', 'features/me/src/main/ets/MeKit.ets', 'export const X: number = 1;', 'export const X: number = 3;'),
    ('统一剪贴板入口被改', 'entry/src/main/ets/clipboard/AppClipboard.ets', 'export const X: number = 1;', 'export const X: number = 4;'),
    ('designsystem 被改', 'common/designsystem/src/main/ets/Colors.ets', 'export const C: number = 1;', 'export const C: number = 2;'),
    ('草稿表改了已有行', DRAFTS, "m.set('me.amount_hidden', '金额已隐藏');", "m.set('me.amount_hidden', '已隐藏');"),
    ('新草稿文字不对', DRAFTS, "m.set('me.amount_shown', '金额已显示');", "m.set('me.amount_shown', '已显示');"),
    ('Index 漏导出', CORE_INDEX, 'MeNoticeAnnounce, ', ''),
    ('Index 删了旧导出', CORE_INDEX, "export { MeDraftTexts } from './src/main/ets/me/MeDraftTexts';\n", ''),
    # ---- staging 与设施
    ('staging 缺 getMe 计数', 'entry/src/staging/ets/variant/DebugFakeMe.ets', "'me.get_count'", "'me.count'"),
    ('staging 缺慢速场景', 'entry/src/staging/ets/variant/DebugFakeMe.ets', "'slow', ", ''),
    ('调试计数进 main', 'entry/src/main/ets/me/Other.ets', 'export const Y: number = 1;', "export const Y: string = 'me.get_count';"),
    # APP-12w-a-harmony 测试 v1（#24 只换定位串）：主步再排除 Me12waUi、device-test 再认 me12wa。
    # APP-12w-b-harmony 测试 v1（#24 只换定位串）：主步再排除 Me12wbUi、device-test 再认 me12wb。
    # APP-12w-c-harmony 测试 v1（#24 只换定位串，H-R16）：主步再排除 Me12wcUi、device-test 再认 me12wc。
    ('主步不排除 Me12vUi', 'tools/ci/verify.sh', 'Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi main', 'Hm05rConsentUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi main'),
    ('没有 me12v 设备步', 'tools/ci/verify.sh', 'entry-me12v class=Me12vUi me12v', 'entry-me12v class=Me12vUi all'),
    ('device-test 不认 me12v', 'tools/ci/device-test.sh', 'hm05r|me12v|me12wa|me12wb|me12wc|tabbar|all)', 'hm05r|me12wa|me12wb|me12wc|tabbar|all)'),
    ('名单少一条', 'tools/ci/me12v/fixtures/device-cases.txt', 'me12v_14_', 'me12v_99_'),
    ('core 套件未登记', 'common/core/src/test/List.test.ets', '  me12vVisualTest();\n', ''),
    ('entry 套件排在 a 段之后', 'entry/src/ohosTest/ets/test/List.test.ets', '  me12vUiTest();\n', ''),
    # ---- 测试 v3：S11 单测照抄的 cells() 口径漂移
    ('单测照抄口径少一条（gridKey）', CORE_VISUAL_TEST, "      if (key === null) {\n        continue;\n      }\n      n++;",
     '      n++;'),
    ('单测照抄口径改了比较', CORE_VISUAL_TEST, "      if (c['group'] !== group) {\n        continue;\n      }\n      const key",
     "      if (c['group'] === undefined) {\n        continue;\n      }\n      const key"),
    ('缺口径全量对比用例', CORE_VISUAL_TEST, "'me12v_grid_groups_match_page_cells_rule_on_all_vectors'", "'me12v_grid_groups_x'"),
    ('守卫 fixture 被改', GUARD_FIXTURE, '"rev": "' + REV + '"', '"rev": "' + REV + ' "'),
]


def build_stub_tree(tmp):
    guard = json.loads((ROOT / GUARD_FIXTURE).read_text(encoding='utf-8'))
    files = dict(REF_STRICT)
    files.update(REF_FILES)
    files[ME_TAB_VIEW] = reference_view(guard)
    for rel, text in files.items():
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding='utf-8')
    for rel in COPY:
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / rel, p)
    # 合成基线：参考桩的逻辑文件 / 只增文件 / designsystem 即「改前」。
    logic = {'strict': {rel: sha((tmp / rel).read_bytes()) for rel in STRICT_FILES},
             'append_only': {DRAFTS: [line_key(l) for l in "export class MeDraftTexts {\n    m.set('me.amount_hidden', '金额已隐藏');"
                                      .split('\n')],
                             CORE_INDEX: [line_key("export { MeDraftTexts } from './src/main/ets/me/MeDraftTexts';")]},
             'tree': [[sha((tmp / rel).read_bytes()), rel] for rel in
                      ['common/designsystem/src/main/ets/Colors.ets', 'common/designsystem/Index.ets']]}
    return logic


def run_mutants(tmp, layer, logic, mutants, loose):
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
        p.write_text(original.replace(old, new), encoding='utf-8')
        got = check_source(tmp, logic=logic) if logic is not None else check_source(tmp)
        p.write_text(original, encoding='utf-8')
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
        logic = build_stub_tree(tmp)
        base = check_source(tmp, logic=logic)
        if base:
            print('ME12V_SELF_TEST_FAIL 参考桩树不该有违反项：', *base, sep='\n  ')
            return 1
        failures += frozen_list_controls(tmp, lambda: check_source(tmp, logic=logic), ['common/designsystem/src/main/ets/components/NotFrozen.ets'],
                                         'common/designsystem/src/main/ets/Colors.ets')
        failures += run_mutants(tmp, '参考桩', logic, MUTANTS, False)
    # 层二：真实实现（本仓库检查通过时）。
    if check_source(ROOT):
        print('SKIP [真实实现] 本仓库检查未通过（实现前预期如此；verify 下一步本仓库检查本来就红），层二跳过')
    else:
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            for top in ['common', 'entry/src', 'features', 'tools/ci']:
                shutil.copytree(ROOT / top, tmp / top, ignore=shutil.ignore_patterns('build', '.test', 'oh_modules', '.hvigor',
                                                                                     '.preview', 'node_modules'))
            real = [
                ('[真]标题仍 heading', ME_TAB_VIEW + '|' + ME_TAB_PARTS, 'CouliTypography.title', 'CouliTypography.heading'),
                ('[真]收益看板非 histogram', ME_TAB_VIEW + '|' + ME_TAB_PARTS, "'sys.symbol.histogram'", "'sys.symbol.chart'"),
                ('[真]进入 Tab 改 load', APP_ME, 'this.tab().autoLoad();', 'this.tab().load();'),
                ('[真]回调体被改', ME_TAB_VIEW, "this.config.open('Wallet', {}, bound.identity);", "this.config.open('Withdraw', {}, bound.identity);"),
                ('[真]守卫区被改', ME_TAB_VIEW, "'invite.copy_code.done'", "'invite.copy_code.x'"),
                ('[真]不降列', ME_TAB_VIEW + '|' + ME_TAB_PARTS, 'MeGridColumns.count(', 'Math.max('),
                ('[真]空组仍画', ME_TAB_VIEW + '|' + ME_TAB_PARTS, 'MeGridGroups.visible(', 'Array.of('),
                ('[真]转圈', ME_TAB_VIEW + '|' + ME_TAB_PARTS, "'me.loading'", "'me.loadingx'"),
            ]
            expanded = []
            for name, rels, old, new in real:
                for rel in rels.split('|'):
                    if (tmp / rel).is_file() and old in (tmp / rel).read_text(encoding='utf-8'):
                        expanded.append((name, rel, old, new))
                        break
                else:
                    failures.append('[真实实现] 定位串找不到：' + name)
            failures += run_mutants(tmp, '真实实现', None, expanded, True)
    if failures:
        print('ME12V_SELF_TEST_FAIL', *failures, sep='\n  ')
        return 1
    print('ME12V_SELF_TEST_OK %d 种错误实现全部拦下（参考桩层；真实实现层见上）' % len(MUTANTS))
    return 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    found = check_source(ROOT)
    for f in found:
        print(f)
    print('ME12V_HOST_OK' if not found else 'ME12V_HOST_FAIL %d 项' % len(found))
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
