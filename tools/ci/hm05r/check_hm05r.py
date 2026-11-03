#!/usr/bin/env python3
"""HM-05r 宿主检查（测试 v1 + v2 + v3）：设备名单与设备步、单测登记、权限声明（D1）、旧端键（D4）、默认装配、staging 测量钩子不进
main / release、普通互斥模态订阅（v2 W9）。
测试 v3（2026-10-30 默认开启：BR-ID-16 2026-10-30 版、docs/changes/20261030-剪贴板默认开启.md §2、任务书 FU-X-CLIP-DEFAULT-ON §1 / §2.1，
编排 D10-423）：原 W1（用途说明半屏的 bindSheet / onWillDismiss 关闭语义与 S2-3 票据绑定）、W2（首页来源打开点恰好 1 处）、W6（用途说明
草稿文案）、W7（同意上报 channel 的 TODO）、W10（S2-9 configSource 按层取 consent_version）随 §2 第 1、2、4、5 行作废删除；新增
W1 C2（产品里不再有用途说明半屏、来源、clipboard.consent.* 文案键与 PasteOutcome.NOTICE）、W2 C3（不再写 clipboard_auto_import，
上报器移除）、W6 C8（设置行草稿文案仍在）、W11 C4（剪贴板模块不再读 consent_version）、W12（staging 自动任务探测计数：
BuildVariant.clipboardAdapter，Release 原样返回）。判据改动逐条见 tests-harmony-v3-handback.md §1。

用法：
  check_hm05r.py                本仓库
  check_hm05r.py --self-test    参考桩树全过 + 每种错误实现各自打红（变异定位串在目标文件里必须恰好一次）
  check_hm05r.py --hap <hap>    制品：module.json 不得声明 ohos.permission.READ_PASTEBOARD（Release；D1）
"""
import json
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PERMISSION = 'ohos.permission.READ_PASTEBOARD'
NEW_EXPORTS = ['ImportPreferenceStore', 'ImportPreferenceBackend', 'ImportGates', 'ImportCoordinator', 'ImportTask',
               'ClipboardEligibility', 'SystemClipboardAdapter', 'NotEligibleClipboardAdapter', 'HarmonyAdapterPolicy', 'ClipboardBuild',
               'ClipboardAutoSwitch', 'HarmonyClipboardAdapter']
# 测试 v3：假服务的同意记录回执（设备用例核对「不再上报」）与自动任务探测计数（设备用例核对「默认开启：回前台首页根页走到资格这一步」）
STAGING_HOOKS = ['consents.clipboard_auto_import', 'clipboard.auto_probes']
# 测试 v3（C2）：用途说明半屏与它的来源、文案键在产品源码里一处都不能再有
NOTICE_REMNANTS = ['clipboard_consent_sheet', 'ClipboardConsentHost', 'ClipboardNoticeHost', 'ClipboardNoticeSource',
                   'ClipboardNoticeTicket', 'PasteOutcome.NOTICE', "'clipboard.consent."]


def read(root, rel):
    p = root / rel
    return p.read_text(encoding='utf-8') if p.is_file() else ''


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'(?m)(^|[^:])//.*$', r'\1', text)


def sources(root, sub, suffix='.ets'):
    base = root / sub
    return sorted(p for p in base.rglob('*' + suffix) if p.is_file()) if base.is_dir() else []


def product_sources(root):
    out = []
    for top in ['entry/src/main', 'common', 'features']:
        for p in sources(root, top):
            rel = p.relative_to(root).as_posix()
            if '/src/test/' in rel or '/src/ohosTest/' in rel or '/src/staging/' in rel or rel.startswith('common/generated/'):
                continue
            out.append(p)
    return out


def block_after(text, anchor, size=1600):
    at = text.find(anchor)
    return '' if at < 0 else text[at:at + size]


def statement_at(text, at):
    """从 at 起取一条语句：括号深度为 0 时遇到 ; 或换行结束（多行闭包按括号配对整体取出）。"""
    depth = 0
    i = at
    while i < len(text):
        c = text[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth < 0:
                return text[at:i]
        elif depth == 0 and c in ';\n':
            return text[at:i]
        i += 1
    return text[at:]


def method_body(text, name):
    """同一文件里方法 name 的花括号体（含 static / private 修饰）；找不到为空串。"""
    m = re.search(r'(?m)^\s*(?:(?:private|public|protected|static|async)\s+)*' + re.escape(name) + r'\s*\([^)]*\)\s*(?::\s*[^{]+)?\{', text)
    if not m:
        return ''
    start = m.end() - 1
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return text[start:]


def sheet_callback(text, name, size=700):
    """bindSheet 选项里回调 name 的块：到下一个回调名（onAppear / onWillAppear / onWillDismiss / onDisappear）或 size 字为止。"""
    out = []
    for m in re.finditer(r'\b' + name + r'\s*:', text):
        body = text[m.end():m.end() + size]
        nxt = re.search(r'\b(onAppear|onWillAppear|onWillDismiss|onDisappear|onWillDisappear)\s*:', body)
        out.append(body[:nxt.start()] if nxt else body)
    return out


MODAL_SOURCES = ['AppUpdate', 'PermissionPromptModel']


def check_source(root):
    v = []
    # ---------------- C1 名单
    suite = read(root, 'entry/src/ohosTest/ets/test/Hm05rConsentUi.test.ets')
    listed = re.findall(r"'(hm05r_\d\d_[a-z0-9_]+)'", suite.split('];')[0]) if suite else []
    its = len(re.findall(r'\bit\(HM05R_DEVICE_CASES\[\d+\]', suite))
    fixture = [l.strip() for l in read(root, 'tools/ci/hm05r/fixtures/device-cases.txt').splitlines()
               if l.strip() and not l.startswith('#')]
    if not listed or listed != fixture or len(set(listed)) != len(listed) or its != len(listed):
        v.append('C1 设备名单三处不一致（HM05R_DEVICE_CASES / device-cases.txt / it 数）')
    if "describe('Hm05rConsentUi'" not in suite:
        v.append('C1 describe 名必须是 Hm05rConsentUi（verify 按 class 过滤）')
    # ---------------- C2 设备步与名单核对
    verify = read(root, 'tools/ci/verify.sh')
    if not re.search(r'entry notClass=[^\s]*\bHm05rConsentUi\b[^\s]* main', verify):
        v.append('C2 verify 主 entry 步必须排除 Hm05rConsentUi')
    if 'entry-hm05r class=Hm05rConsentUi hm05r' not in verify:
        v.append('C2 verify 缺单独设备步 entry-hm05r class=Hm05rConsentUi hm05r')
    if 'check_hm05r.py" --hap "$OUT_DIR/Release.hap"' not in verify:
        v.append('C2 verify 缺 Release 制品权限声明检查')
    if "'hm05r'" not in read(root, 'tools/ci/ds02/check_device_result.py'):
        v.append('C2 check_device_result.py 缺 hm05r 名单')
    # APP-12v-harmony 测试 v1（D10-378 test-change）：device-test 还认 me12v，这里只要求 hm05r 在认的名单里。
    if not re.search(r'main\|hm07va\|hm07vb\|hm05r\|(?:[a-z0-9]+\|)*all\)', read(root, 'tools/ci/device-test.sh')):
        v.append('C2 device-test.sh 不认 COULI_HM_DEVICE_SET=hm05r')
    # ---------------- C3 单测登记
    core_list = read(root, 'common/core/src/test/List.test.ets')
    for name in ['hm05rVectorTest();', 'hm05rLogicTest();', 'hm05rIntegrationTest();']:
        if name not in core_list:
            v.append('C3 core List.test.ets 未登记 ' + name)
    if 'hm05rConsentUiTest();' not in read(root, 'entry/src/ohosTest/ets/test/List.test.ets'):
        v.append('C3 entry List.test.ets 未登记 hm05rConsentUiTest()')
    # ---------------- P1 权限声明（D1：任何构建都不声明，CAP-X-02 实测前）
    for p in sorted((root / 'entry').rglob('module.json5')) + sorted((root / 'AppScope').rglob('*.json5')):
        if PERMISSION in p.read_text(encoding='utf-8'):
            v.append('P1 ' + p.relative_to(root).as_posix() + ' 声明了 ' + PERMISSION + '（D1：翻转另立 HM-05r-b）')
    build = strip_comments(read(root, 'common/core/src/main/ets/clipboard/ClipboardImport.ets'))
    if not re.search(r'DECLARES_READ_PASTEBOARD\s*:\s*boolean\s*=\s*false\s*;', build):
        v.append('P2 ClipboardBuild.DECLARES_READ_PASTEBOARD 在 core 默认（Release）源码里必须是 false')
    # P3 资格只经 checkAccessToken 推断
    for p in product_sources(root):
        text = strip_comments(p.read_text(encoding='utf-8'))
        if re.search(r'(?<!DECLARES_)READ_PASTEBOARD', text):
            if 'checkAccessToken' not in text or re.search(r'verifyAccessToken|isPermissionGranted|getPermissionFlags', text):
                v.append('P3 ' + p.relative_to(root).as_posix() + ' 推断剪贴板资格不是只经 checkAccessToken')
    # ---------------- W1 C2：用途说明半屏、三种来源与 clipboard.consent.* 文案键全部移除（变更记录 §2 第 1、3、5 行）
    if (root / 'entry/src/main/ets/clipboard/ClipboardConsentSheet.ets').exists():
        v.append('W1 C2 用途说明半屏文件 ClipboardConsentSheet.ets 还在（2026-10-30 起移除）')
    for p in product_sources(root):
        text = strip_comments(p.read_text(encoding='utf-8'))
        for word in NOTICE_REMNANTS:
            if word in text:
                v.append('W1 C2 ' + p.relative_to(root).as_posix() + ' 仍引用用途说明 ' + word.strip("'"))
    # ---------------- W2 C3：客户端不再写 clipboard_auto_import（上报器移除；ApiClient 的条件签名可留可删，不在这里判）
    for p in product_sources(root):
        rel = p.relative_to(root).as_posix()
        text = strip_comments(p.read_text(encoding='utf-8'))
        if rel.endswith('network/ApiClient.ets'):
            continue
        if 'clipboard_auto_import' in text or 'ImportConsentReporter' in text:
            v.append('W2 C3 ' + rel + ' 仍写 / 补报剪贴板功能同意（clipboard_auto_import / ImportConsentReporter）')
    # ---------------- W11 C4：剪贴板模块不再读 config.clipboard.consent_version（ImportTask.consentVersion 字段可留，不参与判定）
    for sub in ['common/core/src/main/ets/clipboard', 'entry/src/main/ets/clipboard']:
        for p in sources(root, sub):
            if 'consent_version' in strip_comments(p.read_text(encoding='utf-8')):
                v.append('W11 C4 ' + p.relative_to(root).as_posix() + ' 仍读 consent_version')
    # ---------------- W3 旧端键不再读（D4）
    for p in product_sources(root):
        if 'clipboard.enabled.harmony' in strip_comments(p.read_text(encoding='utf-8')):
            v.append('W3 ' + p.relative_to(root).as_posix() + ' 仍读旧端键 clipboard.enabled.harmony（D4）')
    # ---------------- W4 默认装配（真实 preferences 文件、系统适配器、构建常量）
    app = strip_comments(read(root, 'entry/src/main/ets/clipboard/AppClipboard.ets'))
    if not re.search(r'\.importPrefs\s*=', app) or 'ImportPreferenceStore.FILE_NAME' not in app:
        v.append('W4 AppClipboard 必须用 ImportPreferenceStore.FILE_NAME 的 preferences 存储装配 deps.importPrefs')
    if not re.search(r'\.adapter\s*=', app) or 'SystemClipboardAdapter' not in app or 'ClipboardBuild.DECLARES_READ_PASTEBOARD' not in app:
        v.append('W4 AppClipboard 必须以 ClipboardBuild.DECLARES_READ_PASTEBOARD 装配 SystemClipboardAdapter')
    # ---------------- W12 staging 测量：适配器经 BuildVariant.clipboardAdapter(context, real) 装配；Release 原样返回 real（不包、不计数）
    ad = re.search(r'\.adapter\s*=', app)
    if not ad or 'BuildVariant.clipboardAdapter(' not in statement_at(app, ad.start()):
        v.append('W12 deps.adapter 必须经 BuildVariant.clipboardAdapter(context, …SystemClipboardAdapter…) 装配（staging 计探测次数）')
    rel_bv = strip_comments(read(root, 'entry/src/release/ets/variant/BuildVariant.ets'))
    body = method_body(rel_bv, 'clipboardAdapter')
    sig = re.search(r'clipboardAdapter\s*\(\s*\w+\s*:[^,]+,\s*(\w+)\s*:', rel_bv)
    if not body or not sig or not re.fullmatch(r'\{\s*return\s+' + sig.group(1) + r'\s*;\s*\}', body):
        v.append('W12 Release BuildVariant.clipboardAdapter 必须原样返回传入的适配器')
    # ---------------- W9 S1-1：更新提示 / 权限说明的显示变化通知执行层（测试 v3：没有半屏可让位，模态在时自动任务等待、收起后同轮再试）
    entry_main = [p for p in sources(root, 'entry/src/main')]
    modal_fn = method_body(app, 'modal')
    if not re.search(r'\bshowPrompt\b', modal_fn) or 'UpdateStatusRaw.BELOW_RECOMMENDED' not in modal_fn:
        v.append('W9 S1-1 AppClipboard.modal() 必须把「AppUpdate showPrompt 且 BELOW_RECOMMENDED」当普通模态 update_prompt')
    if not re.search(r'PermissionPromptModel\.shared\.visible', modal_fn):
        v.append('W9 S1-1 AppClipboard.modal() 必须把 PermissionPromptModel.shared.visible 当普通模态')
    if not re.search(r'\.modal\s*=\s*\([^)]*\)\s*:\s*string\s*=>\s*AppClipboard\.modal\(\)', app):
        v.append('W9 S1-1 deps.modal 必须接 AppClipboard.modal()（执行层 modalChanged 与门控用同一个判定源）')
    for src in MODAL_SOURCES:
        wired = False
        slots = {}
        for p in entry_main:
            text = strip_comments(p.read_text(encoding='utf-8'))
            # 显示变化的登记：X.shared.<hook> = …（单槽回调）、X.shared.<subscribe>(…)、addMonitor(X.shared, …)
            for m in re.finditer(r'\b' + src + r'\.shared\.(on\w+)\s*=(?!=)', text):
                slots.setdefault(m.group(1), []).append(p.relative_to(root).as_posix())
                if 'modalChanged(' in statement_at(text, m.start()):
                    wired = True
            for m in re.finditer(r'\b' + src + r'\.shared\.(\w+)\s*\(', text):
                if m.group(1) != 'modalChanged' and 'modalChanged(' in statement_at(text, m.start()):
                    wired = True
            for m in re.finditer(r'\baddMonitor\s*\(\s*' + src + r'\.shared\b', text):
                if 'modalChanged(' in statement_at(text, m.start()):
                    wired = True
        if not wired:
            v.append('W9 S1-1 entry 没有订阅 ' + src + ' 的显示变化去调执行层 modalChanged()（模态收起后本轮等待的自动任务不再试）')
        for hook, where in sorted(slots.items()):
            if len(where) > 1:
                v.append('W9 S1-1 ' + src + '.shared.' + hook + ' 是单槽回调，被赋值 %d 次（%s）：后赋值的会吞掉先赋值的订阅'
                         % (len(where), ', '.join(where)))
    index = read(root, 'common/core/Index.ets')
    for name in NEW_EXPORTS:
        if not re.search(r'\b' + name + r'\b', index):
            v.append('W5 core Index 未导出 ' + name)
    # ---------------- W6 C8：设置页开关行的草稿文案仍在（标题 / 说明）；clipboard.consent.* 已由 W1 守不再引用
    drafts = read(root, 'entry/src/main/ets/clipboard/ClipboardDraftTexts.ets')
    for key in ['settings.clipboard_auto', 'settings.clipboard_auto.desc']:
        if "'" + key + "'" not in drafts:
            v.append('W6 C8 草稿表缺设置行文案 ' + key)
    # ---------------- W8 staging 钩子只在 staging
    staging = ''.join(p.read_text(encoding='utf-8') for p in sources(root, 'entry/src/staging'))
    for hook in STAGING_HOOKS:
        if hook not in staging:
            v.append('W8 staging 缺 ' + hook + '（设备用例依赖，tests-harmony-v3-handback.md §5）')
        for p in product_sources(root):
            if hook in p.read_text(encoding='utf-8'):
                v.append('W8 ' + p.relative_to(root).as_posix() + ' 在 main / release 源码里引用调试钩子 ' + hook)
    return v


def check_hap(path):
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if n.endswith('module.json')]
        if not names:
            raise ValueError('制品里没有 module.json')
        for n in names:
            data = json.loads(z.read(n).decode('utf-8'))
            perms = [p.get('name') for p in data.get('module', {}).get('requestPermissions', []) or []]
            if PERMISSION in perms:
                return ['HAP ' + n + ' 声明了 ' + PERMISSION]
    return []


# ---------------------------------------------------------------- 自测：参考桩树 + 错误实现
REFERENCE = {
    'common/core/src/main/ets/clipboard/ClipboardImport.ets':
        "export class ClipboardBuild {\n  static readonly DECLARES_READ_PASTEBOARD: boolean = false;\n}\n"
        "export class SystemClipboardAdapter {\n  probe(): string { return checkAccessToken(ohos.permission.READ_PASTEBOARD); }\n}\n"
        "export class ImportTask {\n  readonly consentVersion: string | null;\n}\n",
    'common/core/src/main/ets/clipboard/ClipboardController.ets':
        "export class PasteOutcome {\n  static readonly NO_AUTH: string = 'no_auth';\n}\n"
        "  flags(): boolean { return this.config()['features'] !== undefined; }\n",
    'common/core/src/main/ets/network/ApiClient.ets':
        "export class ConditionalSigning {\n  static readonly SIGNED_CONSENT_TYPE: string = 'clipboard_auto_import';\n}\n",
    'common/core/Index.ets': 'export { ' + ', '.join(NEW_EXPORTS) + " } from './src/main/ets/clipboard/ClipboardImport';\n",
    'entry/src/main/ets/clipboard/AppClipboard.ets':
        "deps.importPrefs = new ImportPreferenceStore(new PreferencesImportBackend(ctx, ImportPreferenceStore.FILE_NAME), clock);\n"
        "deps.adapter = BuildVariant.clipboardAdapter(context, new SystemClipboardAdapter(ClipboardBuild.DECLARES_READ_PASTEBOARD,\n"
        "  check, forever, read));\n"
        "deps.modal = (): string => AppClipboard.modal();\n"
        "AppUpdate.shared.subscribeOverlay((): void => this.controllerInstance?.modalChanged());\n"
        "PermissionPromptModel.shared.subscribeOverlay((): void => this.controllerInstance?.modalChanged());\n"
        "  private static modal(): string {\n    const update: AppUpdate = AppUpdate.shared;\n"
        "    if (update.showPrompt && update.statusRaw === UpdateStatusRaw.BELOW_RECOMMENDED) {\n      return 'update_prompt';\n    }\n"
        "    return PermissionPromptModel.shared.visible ? 'other_dialog' : ImportGates.MODAL_NONE;\n  }\n",
    'entry/src/main/ets/home/AppHome.ets':
        "    PermissionPromptModel.shared.onOverlayChanged = (): void => this.visibility.overlaysChanged();\n"
        "    AppUpdate.shared.onOverlayChanged = (): void => this.visibility.overlaysChanged();\n",
    'entry/src/main/ets/clipboard/ClipboardDraftTexts.ets':
        "['settings.clipboard_auto', '打开 App 自动识别剪贴板'],\n['settings.clipboard_auto.desc', '说明'],\n",
    'entry/src/main/module.json5': '{ "module": { "requestPermissions": [ { "name": "ohos.permission.INTERNET" } ] } }\n',
    'entry/src/release/ets/variant/BuildVariant.ets':
        "  static clipboardAdapter(_context: common.Context, real: HarmonyClipboardAdapter): HarmonyClipboardAdapter {\n"
        "    return real;\n  }\n",
    'entry/src/staging/ets/variant/DebugFakeClipboard.ets':
        "const RECEIPT: string = 'consents.clipboard_auto_import';\nconst PROBES: string = 'clipboard.auto_probes';\n",
}
COPY = ['entry/src/ohosTest/ets/test/Hm05rConsentUi.test.ets', 'tools/ci/hm05r/fixtures/device-cases.txt',
        'tools/ci/verify.sh', 'tools/ci/ds02/check_device_result.py', 'tools/ci/device-test.sh',
        'common/core/src/test/List.test.ets', 'entry/src/ohosTest/ets/test/List.test.ets']
SHEET = ("Column() {}.id('clipboard_consent_sheet')\n.bindSheet(this.model.consentOpen, this.sheet(), { dragBar: true })\n")
MUTANTS = [
    ('Release 声明了 READ_PASTEBOARD', 'entry/src/main/module.json5', '"ohos.permission.INTERNET" }',
     '"ohos.permission.INTERNET" }, { "name": "ohos.permission.READ_PASTEBOARD" }'),
    ('构建常量写成 true', 'common/core/src/main/ets/clipboard/ClipboardImport.ets', 'DECLARES_READ_PASTEBOARD: boolean = false',
     'DECLARES_READ_PASTEBOARD: boolean = true'),
    ('资格用 verifyAccessToken 推断', 'common/core/src/main/ets/clipboard/ClipboardImport.ets', 'checkAccessToken(',
     'verifyAccessTokenSync('),
    ('旧端键复活', 'common/core/src/main/ets/clipboard/ClipboardController.ets', "this.config()['features'] !== undefined",
     "this.config()['features']['flags']['clipboard.enabled.harmony'] !== false"),
    ('默认装配不用 preferences 文件', 'entry/src/main/ets/clipboard/AppClipboard.ets', 'ImportPreferenceStore.FILE_NAME', "'couli_app'"),
    ('适配器不按构建常量', 'entry/src/main/ets/clipboard/AppClipboard.ets', 'ClipboardBuild.DECLARES_READ_PASTEBOARD', 'true'),
    ('调试钩子进 main', 'entry/src/main/ets/clipboard/AppClipboard.ets', 'deps.importPrefs =',
     "const k: string = 'clipboard.auto_probes';\ndeps.importPrefs ="),
    ('Index 漏导出', 'common/core/Index.ets', 'ClipboardAutoSwitch, ', ''),
    ('主步不排除 Hm05rConsentUi', 'tools/ci/verify.sh', 'Hm07vOverlayUi,Hm05rConsentUi,Me12vUi main', 'Hm07vOverlayUi,Me12vUi main'),
    ('名单少一条', 'tools/ci/hm05r/fixtures/device-cases.txt', 'hm05r_11_', 'hm05r_99_'),
    ('device-test 不认 hm05r', 'tools/ci/device-test.sh', 'main|hm07va|hm07vb|hm05r|me12v|all)', 'main|hm07va|hm07vb|me12v|all)'),
    # ---- 测试 v2（W9）
    ('S1-1 未订阅 AppUpdate', 'entry/src/main/ets/clipboard/AppClipboard.ets',
     'AppUpdate.shared.subscribeOverlay((): void => this.controllerInstance?.modalChanged());\n', ''),
    ('S1-1 未订阅 PermissionPrompt', 'entry/src/main/ets/clipboard/AppClipboard.ets',
     'PermissionPromptModel.shared.subscribeOverlay((): void => this.controllerInstance?.modalChanged());\n', ''),
    ('S1-1 订阅了但不通知执行层', 'entry/src/main/ets/clipboard/AppClipboard.ets',
     'AppUpdate.shared.subscribeOverlay((): void => this.controllerInstance?.modalChanged());',
     'AppUpdate.shared.subscribeOverlay((): void => this.apply(this.snapshot));'),
    ('S1-1 抢了首页的单槽回调', 'entry/src/main/ets/clipboard/AppClipboard.ets',
     'AppUpdate.shared.subscribeOverlay((): void => this.controllerInstance?.modalChanged());',
     'AppUpdate.shared.onOverlayChanged = (): void => this.controllerInstance?.modalChanged();'),
    ('S1-1 modal 不认权限说明', 'entry/src/main/ets/clipboard/AppClipboard.ets',
     "return PermissionPromptModel.shared.visible ? 'other_dialog'", "return false ? 'other_dialog'"),
    ('S1-1 modal 不认更新提示', 'entry/src/main/ets/clipboard/AppClipboard.ets',
     'update.statusRaw === UpdateStatusRaw.BELOW_RECOMMENDED', 'update.statusRaw === UpdateStatusRaw.BELOW_MIN'),
    ('S1-1 deps.modal 不接 AppClipboard.modal', 'entry/src/main/ets/clipboard/AppClipboard.ets',
     'deps.modal = (): string => AppClipboard.modal();', "deps.modal = (): string => 'none';"),
    # ---- 测试 v3（2026-10-30 默认开启）
    ('C2 用途说明半屏还在（宿主文件）', 'entry/src/main/ets/clipboard/AppClipboard.ets', 'deps.modal =',
     "struct ClipboardConsentHost {}\ndeps.modal ="),
    ('C2 半屏组件 id 还在', 'entry/src/main/ets/home/AppHome.ets', '    AppUpdate.shared.onOverlayChanged',
     '    ' + SHEET + '    AppUpdate.shared.onOverlayChanged'),
    ('C2 手动粘贴仍有 NOTICE 结论', 'common/core/src/main/ets/clipboard/ClipboardController.ets', "NO_AUTH: string = 'no_auth';",
     "NO_AUTH: string = 'no_auth';\n  static readonly NOTICE: string = 'notice';\n  x(): string { return PasteOutcome.NOTICE; }"),
    ('C2 首页来源仍打开说明', 'common/core/src/main/ets/clipboard/ClipboardController.ets', '  flags(): boolean {',
     '  show(): void { this.consentNotice.open(ClipboardNoticeSource.HOME, v, page, epoch); }\n  flags(): boolean {'),
    ('C2 草稿仍有 clipboard.consent.*', 'entry/src/main/ets/clipboard/ClipboardDraftTexts.ets',
     "['settings.clipboard_auto.desc', '说明'],", "['settings.clipboard_auto.desc', '说明'],\n['clipboard.consent.title', '标题'],"),
    ('C3 仍写 clipboard_auto_import', 'common/core/src/main/ets/clipboard/ClipboardImport.ets',
     'export class ImportTask {', "export class ImportConsentRecordType {\n  static readonly T: string = 'clipboard_auto_import';\n}\n"
     'export class ImportTask {'),
    ('C3 上报器仍在', 'common/core/src/main/ets/clipboard/ClipboardController.ets', '  flags(): boolean {',
     '  readonly reporter: ImportConsentReporter = new ImportConsentReporter(api, prefs);\n  flags(): boolean {'),
    ('C4 仍读 consent_version', 'common/core/src/main/ets/clipboard/ClipboardImport.ets', '  readonly consentVersion: string | null;',
     "  readonly consentVersion: string | null;\n  static of(c: Record<string, Object>): Object { return c['consent_version']; }"),
    ('C4 entry 仍读 consent_version', 'entry/src/main/ets/clipboard/AppClipboard.ets', 'deps.modal =',
     "const v: string = AppClipboard.configData()['clipboard']['consent_version'];\ndeps.modal ="),
    ('C8 设置行文案缺', 'entry/src/main/ets/clipboard/ClipboardDraftTexts.ets', "['settings.clipboard_auto.desc', '说明'],\n", ''),
    ('staging 探测计数缺', 'entry/src/staging/ets/variant/DebugFakeClipboard.ets', "'clipboard.auto_probes'", "'clipboard.probes'"),
    ('适配器不经 BuildVariant', 'entry/src/main/ets/clipboard/AppClipboard.ets', 'deps.adapter = BuildVariant.clipboardAdapter(context, ',
     'deps.adapter = ('),
    ('Release 也包了计数适配器', 'entry/src/release/ets/variant/BuildVariant.ets', '    return real;\n',
     '    return new CountingAdapter(real);\n'),
]


def build_tree(tmp):
    for rel, text in REFERENCE.items():
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding='utf-8')
    for rel in COPY:
        p = tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / rel, p)


def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        build_tree(tmp)
        base = check_source(tmp)
        if base:
            print('参考桩树不该有违反项：', *base, sep='\n  ')
            return 1
        for name, rel, old, new in MUTANTS:
            p = tmp / rel
            original = p.read_text(encoding='utf-8')
            if original.count(old) != 1:
                failures.append(name + '：定位串在 ' + rel + ' 里不是恰好一次')
                continue
            p.write_text(original.replace(old, new), encoding='utf-8')
            got = check_source(tmp)
            p.write_text(original, encoding='utf-8')
            print(('KILLED   ' if got else 'SURVIVED ') + name + ('  ← ' + got[0] if got else ''))
            if not got:
                failures.append(name + ' 未被拦下')
    if failures:
        print('HM05R_SELF_TEST_FAIL', *failures, sep='\n  ')
        return 1
    print('HM05R_SELF_TEST_OK %d 种错误实现全部拦下' % len(MUTANTS))
    return 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    if '--hap' in argv:
        found = check_hap(argv[argv.index('--hap') + 1])
        for f in found:
            print(f)
        print('HM05R_HAP_OK' if not found else 'HM05R_HAP_FAIL')
        return 1 if found else 0
    found = check_source(ROOT)
    for f in found:
        print(f)
    print('HM05R_HOST_OK' if not found else 'HM05R_HOST_FAIL %d 项' % len(found))
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
