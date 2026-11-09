#!/usr/bin/env python3
"""HM-07v-b（首页视觉 b 段：弹窗与剪贴板浮层）宿主检查：设备用例名单与单独设备步、单测登记、几处「不用就一定错」的接线。

用法：
  check_overlays.py              检查本仓库源码（实现落地前预期红）
  check_overlays.py --self-test  对临时副本逐个施加错误实现，每个都必须被拦下

行为本身由 core（Hm07vOverlay）/ designsystem（Hm07vOverlayLayout）Hypium 套件与 entry 设备套件 Hm07vOverlayUi 判定；
这里只守：名单三处一致、verify 第三个 entry 设备步、读屏名 / 按钮字草稿、弹窗遮罩令牌与几何接线、邀请条排法接线、
①⑤ 关闭按结果类别、识别卡半屏系统把手与关闭 id、假服务的两个场景词（只在 staging）。
"""
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SUITE = 'entry/src/ohosTest/ets/test/Hm07vOverlayUi.test.ets'
CASES = 'tools/ci/hm07v/fixtures/device-cases-b.txt'
HOME_CARDS = 'features/home/src/main/ets/HomeCards.ets'
HOME_ROOT = 'features/home/src/main/ets/HomeTabRoot.ets'
HOME_DRAFTS = 'common/core/src/main/ets/home/HomeDraftTexts.ets'
CLIP_DRAFTS = 'entry/src/main/ets/clipboard/ClipboardDraftTexts.ets'
CLIP_VIEWS = 'entry/src/main/ets/clipboard/ClipboardViews.ets'
APP_CLIP = 'entry/src/main/ets/clipboard/AppClipboard.ets'
DS_CLIP = 'common/designsystem/src/main/ets/components/Clipboard.ets'
DS_OVERLAYS = 'common/designsystem/src/main/ets/components/Overlays.ets'
FAKE_CLIP = 'entry/src/staging/ets/variant/DebugFakeClipboard.ets'
FILES = [SUITE, CASES, HOME_CARDS, HOME_ROOT, HOME_DRAFTS, CLIP_DRAFTS, CLIP_VIEWS, APP_CLIP, DS_CLIP, DS_OVERLAYS, FAKE_CLIP,
         'tools/ci/verify.sh', 'tools/ci/device-test.sh', 'tools/ci/ds02/check_device_result.py',
         'entry/src/ohosTest/ets/test/List.test.ets', 'common/core/src/test/List.test.ets',
         'common/designsystem/src/test/List.test.ets']


def read(root, rel):
    p = Path(root) / rel
    return p.read_text(encoding='utf-8') if p.exists() else ''


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'(^|[^:])//[^\n]*', r'\1', text)


def block(text, start):
    """从 start 所在处起、按花括号配平取出的那一段（找不到为空）。"""
    at = text.find(start)
    if at < 0:
        return ''
    open_at = text.find('{', at)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[at:i + 1]
    return text[at:]


def check_source(root):
    errors = []
    # C1 名单：套件 it() = 导出常量 HM07VB_DEVICE_CASES = 登记文件，且不重名、都以 hm07vb_ 开头。
    suite = read(root, SUITE)
    declared = re.findall(r"\bit\('(hm07vb_[a-z0-9_]+)'", suite)
    exported = re.findall(r"'(hm07vb_[a-z0-9_]+)'", suite.split('HM07VB_DEVICE_CASES', 1)[1]) if 'HM07VB_DEVICE_CASES' in suite else []
    listed = [line.strip() for line in read(root, CASES).splitlines() if line.strip() and not line.startswith('#')]
    if not declared:
        errors.append('C1 设备套件没有 hm07vb_ 用例')
    if declared != exported or sorted(declared) != sorted(listed) or len(set(declared)) != len(declared):
        errors.append('C1 设备用例名单三处不一致（套件 it / HM07VB_DEVICE_CASES / device-cases-b.txt）或重名')
    if "describe('Hm07vOverlayUi'" not in suite:
        errors.append('C1 设备套件 describe 名不是 Hm07vOverlayUi（verify 的套件过滤按它）')
    # C2 单独设备步：主步排除 b 套件、第三步只跑 b 套件并按 hm07vb 名单核对；名单登记；device-test 认 hm07vb。
    verify = read(root, 'tools/ci/verify.sh')
    tails = [line.split()[-3:] for line in verify.splitlines() if line.strip().startswith('run_device_tests entry ')]
    main_ok = any(t[0] == 'entry' and t[2] == 'main' and t[1].startswith('notClass=')
                  and 'Hm07vOverlayUi' in t[1].split('=', 1)[1].split(',') for t in tails)
    if not main_ok or ['entry-hm07vb', 'class=Hm07vOverlayUi', 'hm07vb'] not in tails:
        errors.append('C2 verify.sh 没有 entry-hm07vb class=Hm07vOverlayUi hm07vb 设备步，或主步没排除 Hm07vOverlayUi')
    if 'hm07v/fixtures/device-cases-b.txt' not in read(root, 'tools/ci/ds02/check_device_result.py'):
        errors.append('C2 check_device_result.py 没把 HM-07v-b 用例列为必跑')
    # HM-05r 测试 v1（D10-378 test-change）：device-test 还认 hm05r，b 段只要求 hm07vb 在认的名单里。
    if not re.search(r'main\|hm07va\|hm07vb\|(?:[a-z0-9]+\|)*all\)', read(root, 'tools/ci/device-test.sh')):
        errors.append('C2 device-test.sh 不认 COULI_HM_DEVICE_SET=hm07vb')
    # C3 套件登记（三个 List.test.ets）。
    for rel, call in [('entry/src/ohosTest/ets/test/List.test.ets', 'hm07vOverlayUiTest'),
                      ('common/core/src/test/List.test.ets', 'hm07vOverlayTest'),
                      ('common/designsystem/src/test/List.test.ets', 'hm07vOverlayLayoutTest')]:
        if not re.search(r'^\s*' + call + r'\(\);', strip_comments(read(root, rel)), flags=re.M):
            errors.append('C3 ' + rel + ' 没登记 ' + call)
    # W1 弹窗读屏名：「首页弹窗」，不再有「活动弹窗」（G-V07）。
    drafts = strip_comments(read(root, HOME_DRAFTS))
    if "'home.popup.label', '首页弹窗'" not in drafts or '活动弹窗' in drafts:
        errors.append('W1 home.popup.label 不是「首页弹窗」或仍有「活动弹窗」')
    # W2 弹窗：遮罩用 overlay.scrim 令牌（不用 textPrimary 推出来的 CouliShadow.mask）；几何走 HomePopupGeometry；新 id。
    home_root = strip_comments(read(root, HOME_ROOT))
    home_cards = strip_comments(read(root, HOME_CARDS))
    dialog = block(home_root, 'class ArkPopupPresenter')
    if 'maskColor: CouliColors.overlayScrim' not in dialog or 'CouliShadow.mask(' in dialog:
        errors.append('W2 首页弹窗遮罩没用 CouliColors.overlayScrim（或仍用 CouliShadow.mask）')
    popup = block(home_cards, 'export struct HomePopupView')
    if 'HomePopupGeometry.of(' not in popup + home_root:
        errors.append('W2 首页弹窗尺寸没走 HomePopupGeometry.of（关闭层独立于图片比例的口径在单测里，页面须同一口径）')
    for pid in ["'home_popup'", "'home_popup_image'", "'home_popup_close'"]:
        if '.id(' + pid + ')' not in popup:
            errors.append('W2 HomePopupView 缺稳定 id ' + pid)
    # W3 邀请条：按钮字【绑定】、读屏「绑定邀请人」（三端口径）；按钮浅底 brand.subtle；排法走 ClipboardPromptLayout。
    clip = strip_comments(read(root, CLIP_DRAFTS))
    if "'clipboard.invite_prompt.action', '绑定'" not in clip or "'clipboard.invite_prompt.action_label', '绑定邀请人'" not in clip \
            or '粘贴并绑定邀请人' in clip:
        errors.append('W3 邀请条按钮字不是「绑定」或读屏名不是「绑定邀请人」')
    bar = block(strip_comments(read(root, DS_CLIP)), 'export struct ClipboardPromptBar')
    if 'ClipboardPromptLayout.stacked(' not in bar or 'ClipboardPromptLayout.question(' not in bar:
        errors.append('W3 ClipboardPromptBar 没用 ClipboardPromptLayout（问句不拆行 / 放不下按钮下移）')
    # 禁用态可回 background.muted（Android b 同口径），可用态必须是 brand.subtle 浅底。
    if 'CouliColors.brandSubtle' not in bar:
        errors.append('W3 ClipboardPromptBar 按钮不是 brand.subtle 浅底')
    # W4 ①⑤：关闭按结果类别给（ClipboardResultView.closable）；⑤ 有【重试】接线（ClipboardResultBinding.retry）。
    entry_clip = strip_comments(read(root, CLIP_VIEWS)) + strip_comments(read(root, APP_CLIP))
    if 'ClipboardResultView.closable(' not in entry_clip:
        errors.append('W4 首页结果卡的【关闭】没按 ClipboardResultView.closable（①⑤ 不设关闭）')
    if '.retry()' not in entry_clip or 'NETWORK_FAILED' not in entry_clip:
        errors.append('W4 ⑤ 网络失败没接【重试】（ClipboardResultBinding.retry / ClipboardResultView.NETWORK_FAILED）')
    # W5 识别卡半屏：首页 bindSheet 用系统把手（H19 dragBar: true），关闭有稳定 id。
    views = strip_comments(read(root, CLIP_VIEWS))
    home_paste = block(views, 'export struct HomeClipboardPaste')
    if 'dragBar: true' not in home_paste:
        errors.append('W5 首页识别卡半屏没用系统把手（bindSheet dragBar: true，H19）')
    if "'clipboard_card_list_close'" not in views + strip_comments(read(root, DS_OVERLAYS)):
        errors.append('W5 识别卡半屏关闭缺稳定 id clipboard_card_list_close')
    # W6 假服务场景词（只在 staging 源码集）：offline → 断网（code -1）；sheet1 → 单张缺 product_key 的卡。
    fake = strip_comments(read(root, FAKE_CLIP))
    if "indexOf('offline')" not in fake or 'FakeAnswer(-1' not in fake:
        errors.append('W6 DebugFakeClipboard 缺场景词 offline（code -1 断网，⑤ 设备用例用）')
    if "indexOf('sheet1')" not in fake:
        errors.append('W6 DebugFakeClipboard 缺场景词 sheet1（单张识别卡半屏设备用例用）')
    for main_src in ['entry/src/main', 'entry/src/release']:
        for p in (Path(root) / main_src).rglob('*.ets') if (Path(root) / main_src).exists() else []:
            if 'DebugFakeClipboard' in p.read_text(encoding='utf-8'):
                errors.append('W6 ' + str(p.relative_to(root)) + ' 引用了 staging 假服务')
    return errors


# 自测（v2，D10-378 既有设施改动）：v1 把真实文件拷进临时树再「追加」参考片段、变异只换第一处——真实实现里同样的字样还在，
# 变异改掉的是参考片段那处、检查读到的是真实那处，于是实现越完整越「拦不下」（W4×2、W6×1 必然存活）。v2 分两层：
#   层一 参考桩树：产品文件不拷真实副本，只放按交回 §3 写的最小参考片段；每个变异的定位串在目标文件里必须恰好出现一次（不唯一即自测失败）。
#   层二 真实实现：本仓库检查通过时，把真实文件原样拷出（含 entry/src/main、release 全部源码），对检查真正读取的那几处做全量替换
#        （可限定在某个 struct / class 块内），每个变异都必须真改到文件且被拦下。本仓库检查未过时层二跳过（verify 下一步的本仓库检查本来就红）。
PRODUCT_FILES = [HOME_CARDS, HOME_ROOT, HOME_DRAFTS, CLIP_DRAFTS, CLIP_VIEWS, APP_CLIP, DS_CLIP, DS_OVERLAYS, FAKE_CLIP]
REFERENCE_STUBS = {
    HOME_DRAFTS: "m.set('home.popup.label', '首页弹窗');\nm.set('home.popup.close', '关闭');\n",
    CLIP_DRAFTS: "m.set('clipboard.invite_prompt.action', '绑定');\nm.set('clipboard.invite_prompt.action_label', '绑定邀请人');\n",
    HOME_ROOT: 'class ArkPopupPresenter {\n  open() { x({ maskColor: CouliColors.overlayScrim }); }\n}\n',
    HOME_CARDS: "export struct HomePopupView {\n  build() { const g = HomePopupGeometry.of(1, 2, 3, 4);\n"
                "    Stack() {}.id('home_popup'); Image(x).id('home_popup_image'); Button().id('home_popup_close'); }\n}\n",
    DS_CLIP: 'export struct ClipboardPromptBar {\n'
             '  build() { ClipboardPromptLayout.question(t); ClipboardPromptLayout.stacked(1, 2, 3, 4);\n'
             '    Button().backgroundColor(CouliColors.brandSubtle); }\n}\nexport struct ClipboardNotice {\n  build() {}\n}\n',
    APP_CLIP: 'const c = ClipboardResultView.closable(k); if (k === ClipboardResultView.NETWORK_FAILED) { b.retry(); }\n',
    CLIP_VIEWS: "export struct HomeClipboardPaste {\n  build() { Column().bindSheet(s, b, { dragBar: true }); "
                "Button().id('clipboard_card_list_close'); }\n}\n",
    DS_OVERLAYS: 'export struct CouliSheetPanel {\n  build() {}\n}\n',
    FAKE_CLIP: "if (text.indexOf('offline') >= 0) { return new FakeAnswer(-1, '{}'); }\n"
               "if (text.indexOf('sheet1') >= 0) { return x; }\n",
}
LEAK = 'entry/src/main/ets/clipboard/Leak.ets'

# (标签, 检查代码, 层一目标文件, 层一定位串, 替换, 层二 [(文件, 限定块起始或 None)], 层二定位串, 层二替换)
#   层二定位串与检查要求的字样相同（或是其子串），所以通过检查的真实实现里一定能找到；全量替换后检查读到的每一处都变了。
MUTANTS = [
    ('弹窗读屏名回「活动弹窗」', 'W1', HOME_DRAFTS, "'首页弹窗'", "'活动弹窗'",
     [(HOME_DRAFTS, None)], "'首页弹窗'", "'活动弹窗'"),
    ('遮罩回 textPrimary 推的 CouliShadow.mask', 'W2', HOME_ROOT, 'maskColor: CouliColors.overlayScrim',
     'maskColor: CouliShadow.mask(CouliColors.textPrimary)',
     [(HOME_ROOT, 'class ArkPopupPresenter')], 'maskColor: CouliColors.overlayScrim', 'maskColor: CouliShadow.mask(CouliColors.textPrimary)'),
    ('弹窗尺寸不走 HomePopupGeometry', 'W2', HOME_CARDS, 'HomePopupGeometry.of(1, 2, 3, 4)', 'computeSize()',
     [(HOME_CARDS, None), (HOME_ROOT, None)], 'HomePopupGeometry.of(', 'computeSize('),
    ('弹窗缺图片框 id', 'W2', HOME_CARDS, ".id('home_popup_image')", '',
     [(HOME_CARDS, 'export struct HomePopupView')], ".id('home_popup_image')", ''),
    ('邀请条按钮仍为「粘贴」', 'W3', CLIP_DRAFTS, "'clipboard.invite_prompt.action', '绑定'", "'clipboard.invite_prompt.action', '粘贴'",
     [(CLIP_DRAFTS, None)], "'clipboard.invite_prompt.action', '绑定'", "'clipboard.invite_prompt.action', '粘贴'"),
    ('邀请条读屏名回「粘贴并绑定邀请人」', 'W3', CLIP_DRAFTS, "'绑定邀请人'", "'粘贴并绑定邀请人'",
     [(CLIP_DRAFTS, None)], "'绑定邀请人'", "'粘贴并绑定邀请人'"),
    ('提示条不用排法规则', 'W3', DS_CLIP, 'ClipboardPromptLayout.stacked(1, 2, 3, 4)', 'false',
     [(DS_CLIP, 'export struct ClipboardPromptBar')], 'ClipboardPromptLayout.stacked(', 'legacyStacked('),
    ('提示条按钮仍灰底', 'W3', DS_CLIP, 'Button().backgroundColor(CouliColors.brandSubtle)',
     'Button().backgroundColor(CouliColors.backgroundMuted)',
     [(DS_CLIP, 'export struct ClipboardPromptBar')], 'CouliColors.brandSubtle', 'CouliColors.backgroundMuted'),
    ('①⑤ 仍按固定关闭', 'W4', APP_CLIP, 'ClipboardResultView.closable(k)', 'true',
     [(CLIP_VIEWS, None), (APP_CLIP, None)], 'ClipboardResultView.closable(', 'alwaysClosable('),
    ('⑤ 没接重试', 'W4', APP_CLIP, 'b.retry()', 'b.close()',
     [(CLIP_VIEWS, None), (APP_CLIP, None)], '.retry()', '.close()'),
    ('识别卡半屏自绘把手', 'W5', CLIP_VIEWS, 'dragBar: true', 'dragBar: false',
     [(CLIP_VIEWS, 'export struct HomeClipboardPaste')], 'dragBar: true', 'dragBar: false'),
    ('假服务缺断网场景', 'W6', FAKE_CLIP, "indexOf('offline')", "indexOf('offlinex')",
     [(FAKE_CLIP, None)], "indexOf('offline')", "indexOf('offlinex')"),
    ('假服务进 main 源码', 'W6', LEAK, '', 'import { DebugFakeClipboard } from x;',
     [(LEAK, None)], '', 'import { DebugFakeClipboard } from x;'),
    ('名单少一条', 'C1', CASES, 'hm07vb_overlays_never_expose_old_copy_in_reader_tree\n', '',
     [(CASES, None)], 'hm07vb_overlays_never_expose_old_copy_in_reader_tree\n', ''),
    # APP-12v-harmony 测试 v1（D10-378 test-change，定位串同步）：主步再排除 Me12vUi、device-test 再认 me12v。
    # APP-12w-a-harmony 测试 v1（#24 只换定位串）：主步再排除 Me12waUi、device-test 再认 me12wa。
    # APP-12w-b-harmony 测试 v1（#24 只换定位串）：主步再排除 Me12wbUi、device-test 再认 me12wb。
    # APP-12w-c-harmony 测试 v1（#24 只换定位串，H-R16）：主步再排除 Me12wcUi、device-test 再认 me12wc。
    ('主步没排除 b 套件', 'C2', 'tools/ci/verify.sh', 'notClass=Hm07vHomeUi,Hm07vOverlayUi,Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi main',
     'notClass=Hm07vHomeUi,Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi main',
     [('tools/ci/verify.sh', None)], 'notClass=Hm07vHomeUi,Hm07vOverlayUi,Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi main',
     'notClass=Hm07vHomeUi,Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi main'),
    ('没有 b 设备步', 'C2', 'tools/ci/verify.sh', 'entry-hm07vb class=Hm07vOverlayUi hm07vb', 'entry-hm07vb class=Hm07vOverlayUi all',
     [('tools/ci/verify.sh', None)], 'entry-hm07vb class=Hm07vOverlayUi hm07vb', 'entry-hm07vb class=Hm07vOverlayUi all'),
    ('device-test 不认 hm07vb', 'C2', 'tools/ci/device-test.sh', 'main|hm07va|hm07vb|hm05r|me12v|me12wa|me12wb|me12wc|tabbar|all)', 'main|hm07va|hm05r|me12v|me12wa|me12wb|me12wc|tabbar|all)',
     [('tools/ci/device-test.sh', None)], 'main|hm07va|hm07vb|hm05r|me12v|me12wa|me12wb|me12wc|tabbar|all)', 'main|hm07va|hm05r|me12v|me12wa|me12wb|me12wc|tabbar|all)'),
    ('core 套件未登记', 'C3', 'common/core/src/test/List.test.ets', '  hm07vOverlayTest();\n', '',
     [('common/core/src/test/List.test.ets', None)], 'hm07vOverlayTest();', ''),
]


def copy_rel(src_root, dst_root, rel):
    dst = Path(dst_root) / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    if (Path(src_root) / rel).exists():
        shutil.copy(Path(src_root) / rel, dst)
    else:
        dst.write_text('', encoding='utf-8')


def stub_tree(tmp):
    """层一：测试设施文件（套件、名单、verify、device-test、登记）取本仓库；产品文件只放参考片段（不含真实实现，避免同一字样两处出现）。"""
    for rel in FILES:
        if rel in REFERENCE_STUBS:
            dst = tmp / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(REFERENCE_STUBS[rel], encoding='utf-8')
        else:
            copy_rel(ROOT, tmp, rel)


def real_tree(tmp):
    """层二：本仓库真实文件原样拷出；W6 扫 entry/src/main、release 全部 .ets，所以整个源码集一并拷。"""
    for rel in FILES:
        copy_rel(ROOT, tmp, rel)
    for src in ['entry/src/main', 'entry/src/release']:
        if (ROOT / src).exists():
            shutil.copytree(ROOT / src, tmp / src, dirs_exist_ok=True)


def apply_once(root, rel, old, new):
    """层一：定位串在目标文件里必须恰好一次；old 为空表示新增文件 / 追加。返回错误说明或 None。"""
    p = Path(root) / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    text = p.read_text(encoding='utf-8') if p.exists() else ''
    if not old:
        p.write_text(text + ('\n' if text else '') + new + '\n', encoding='utf-8')
        return None
    n = text.count(old)
    if n != 1:
        return '定位串在 ' + rel + ' 中出现 ' + str(n) + ' 次（须恰好 1 次）'
    p.write_text(text.replace(old, new), encoding='utf-8')
    return None


def apply_everywhere(root, targets, old, new):
    """层二：在每个目标文件（或其中限定的块）里全量替换；返回实际替换次数（old 为空表示新增文件，记 1）。"""
    total = 0
    for rel, scope in targets:
        p = Path(root) / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        text = p.read_text(encoding='utf-8') if p.exists() else ''
        if not old:
            p.write_text(text + ('\n' if text else '') + new + '\n', encoding='utf-8')
            total += 1
            continue
        if scope is None:
            total += text.count(old)
            p.write_text(text.replace(old, new), encoding='utf-8')
        else:
            seg = block(text, scope)
            if seg:
                total += seg.count(old)
                p.write_text(text.replace(seg, seg.replace(old, new), 1), encoding='utf-8')
    return total


def run_layer(name, build, apply, failures):
    tmp = Path(tempfile.mkdtemp(prefix='hm07vb-host-'))
    try:
        build(tmp)
        base = check_source(tmp)
        if base:
            failures.append(name + ' 未变异时本应全过：' + '; '.join(base))
            return
        for m in MUTANTS:
            label, code = m[0], m[1]
            case = Path(tempfile.mkdtemp(prefix='hm07vb-mut-'))
            try:
                shutil.copytree(tmp, case, dirs_exist_ok=True)
                problem = apply(case, m)
                if problem:
                    failures.append(name + ' 变异没施加上：' + label + '（' + problem + '）')
                    print('NOT-APPLIED [' + name + '] ' + label + ' → ' + problem)
                    continue
                hits = [e for e in check_source(case) if e.startswith(code)]
                print(('KILLED ' if hits else 'SURVIVED ') + '[' + name + '] ' + label + ' → ' + (hits[0] if hits else code))
                if not hits:
                    failures.append(name + ' 没拦下：' + label)
            finally:
                shutil.rmtree(case, ignore_errors=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def self_test():
    failures = []
    run_layer('参考桩', stub_tree, lambda case, m: apply_once(case, m[2], m[3], m[4]), failures)

    def real_apply(case, m):
        n = apply_everywhere(case, m[5], m[6], m[7])
        return None if n > 0 else '真实实现里找不到定位串 ' + repr(m[6])
    if check_source(ROOT):
        print('REAL-LAYER SKIP 本仓库检查未过（见 check_overlays.py 本身的违反项），真实实现层不跑')
    else:
        run_layer('真实实现', real_tree, real_apply, failures)
    for f in failures:
        print('SELF-TEST FAIL ' + f, file=sys.stderr)
    if not failures:
        print('HM07VB_SELF_TEST_OK ' + str(len(MUTANTS)) + ' 种错误实现全部拦下'
              + ('' if check_source(ROOT) else '（参考桩与真实实现两层）'))
    return 1 if failures else 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    errors = check_source(ROOT)
    for e in errors:
        print('HM07VB ' + e, file=sys.stderr)
    if errors:
        return 1
    print('HM07VB_HOST_OK 名单 / 设备步 / 草稿 / 弹窗遮罩与几何 / 邀请条 / ①⑤ / 半屏 / 假服务')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
