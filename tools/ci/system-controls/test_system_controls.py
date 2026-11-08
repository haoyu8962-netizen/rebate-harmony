#!/usr/bin/env python3
"""FU-HM-G1-SYSTEM-CONTROLS-harmony 宿主测试（测试作者 v1；D10-823 / D10-827 ③ / D10-901 ② / D10-951）。只用标准库 + 本机鸿蒙 SDK 解析链，
不需要设备。

被测实现（接口写死于 NATIVE/FU-HM-G1-SYSTEM-CONTROLS/tests-harmony-handback.md §2）：
    tools/ci/check_system_controls.py [--root <目录>] [--baseline <文件>]          # 检查；默认 root=仓库根，baseline=<root>/tools/ci/system-controls-baseline.json
    tools/ci/check_system_controls.py [--root <目录>] [--baseline <文件>] --write-baseline   # 按现状写基线（不判定，exit 0）
    tools/ci/check_system_controls.py --self-test
退出码：0 通过；1 有违反（超出 / 少于基线 / 基线里的文件不存在 / 基线外新增）；2 参数不对或基线缺失 / 非法；
       3 解析工具链不可用（复用 lint.hm10_toolchain）；4 无法保证扫完。
命中行：<相对路径>:<行>: couli-g1/<规则> <说明>
lint.py 警告行：<相对路径>:<行>: [couli-g1/<规则>] <说明>（只警告，exit 不变）

用例分三类（交回 §3 逐条对照）：
- A 新脚本与 lint.py 的判定：实现前全红（脚本不存在 / lint.py 还是旧九类），是断言失败不是导入错误。
- B #24 判据改变的反向期望：G1HostReversal 对应 ds02/test_host.py:217-254，LintStyleReversal 对应 test_hardcoded_style.py 的 6 条，
  FrozenNarrowing / Me12Behaviour 对应 me12 四份。冻结文件本身由后续专人按交回 §6 改，本文件不动它们。
- C RealTree：实现且生成正式基线后才绿。"""
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
FIX = HERE / 'fixtures'
SCRIPT = ROOT / 'tools/ci/check_system_controls.py'
LINT = ROOT / 'tools/ci/lint.py'
STYLE_SCRIPT = ROOT / 'tools/ci/check_hardcoded_style.py'
VERIFY = ROOT / 'tools/ci/verify.sh'
REAL_BASELINE = ROOT / 'tools/ci/system-controls-baseline.json'
DS02_WARNING = ROOT / 'tools/ci/lint-fixtures/ds02-warning'
G1_SAMPLES = ROOT / 'tools/ci/lint-fixtures/g1-self-drawn'

S1 = 'couli-g1/self-drawn-control'
S2 = 'couli-g1/click-without-feedback'
S3 = 'couli-g1/edge-effect-none'
S4 = 'couli-g1/hide-title-bar'
EXR = 'couli-g1/exemption-reason'
DETECTORS = [S1, S2, S3, S4]
ALL_RULES = DETECTORS + [EXR]
OLD_MARKER = '[design-system-required]'
DISABLE = '// couli-style-disable-next-line '
CASE_DIR = 'features/home/src/main/ets/cases'
ORIGINAL_NINE = ['Checkbox', 'Toggle', 'Radio', 'TextInput', 'TextArea', 'Search', 'bindSheet', 'openCustomDialog', 'showToast']
# 九个样例在 f293d3d 的 sha256：原样改作合法样例，逐字节不动（§2.3）
SAMPLE_SHA256 = {
    'Checkbox.ets': '18ee2d6c36ebaa64a9c08c154609ae9205f40379ad6740dd7de378e0e2271ed6',
    'Radio.ets': '9981ffabf99ad228d26786c1abfec9d5a3c07ff2d517f75efa13f65688082fd4',
    'Search.ets': '84e66374b5eadec024beb66b6eef694d8c874714fb332bf6192ee83faa4d4e4f',
    'TextArea.ets': '459d6b181f0742c8b391301dcb1f9c01af786222aaa04150c87cf79f494072e7',
    'TextInput.ets': '6d071704436a3695ca08ded5cb39a061f0fb4762e7637645be00f3e669280bc1',
    'Toggle.ets': '94b3a16509d27fa596c5c51d77c6cc2c6f5802c5f0b6a5e9e39db497dff8f870',
    'bindSheet.ets': '727347cff58bdc258670920ff7091b605bc75c7b09c1a9d3ac1f74a2d968a449',
    'openCustomDialog.ets': '9b64c39e9455ae0998dd8a496952819c06f0494170c8d28508a124e01a7576c2',
    'showToast.ets': '3a2681f42c939734c4c4d00ca5eee00093fa45352059dba551f36a331b36f739',
}


def page(body, top=''):
    """把若干行 ArkUI 放进合成页面的 build() 里；top 为空时 body 第一行是文件第 6 行。"""
    return (top + '@Entry\n@ComponentV2\nstruct P {\n  build() {\n    Column() {\n'
            + '\n'.join('      ' + line for line in body.split('\n')) + '\n    }\n  }\n}\n')


def role(kind):
    return '.accessibilityRole(AccessibilityRoleType.%s)' % kind


def builder_page(builders, body):
    """builders 是同文件 @Builder 方法的源码（整段），body 放 build()。"""
    return ('@ComponentV2\nexport struct P {\n' + builders + '\n  build() {\n    Column() {\n'
            + '\n'.join('      ' + line for line in body.split('\n')) + '\n    }\n  }\n}\n')


KNOB = 'Row() {\n  Column()\n}\n'
# (名字, 源码, 期望「规则 → 计数」；None = 不得出现在基线里)
CASES = [
    # ---- S1 命中：自绘系统控件（§1.5 现场写法缩写）----
    ('S1SwitchMeKit', page('Row() {\n  Text(\'label\')\n  Row() {\n    Column()\n  }\n}\n' + role('SWITCH')), {S1: 1}),
    ('S1SwitchPrivacyParts', page('Row() {\n  Column() {\n    Text(\'a\')\n  }\n  Row() {\n    Column()\n  }\n}\n' + role('SWITCH')), {S1: 1}),
    ('S1SwitchSettingsColumn', page('Column() {\n  Row() {\n    Text(\'a\')\n    Row() {\n      Column()\n    }\n  }\n}\n' + role('SWITCH')), {S1: 1}),
    ('S1CheckboxSelfDrawn', page("Row() {\n  Row() {\n    CouliIcon({ name: 'check' })\n  }\n  Text('agree')\n}\n" + role('CHECKBOX')), {S1: 1}),
    ('S1TabBarOnText', page("Text('tab')\n  " + role('TAB_BAR')), {S1: 1}),
    ('S1RadioCheckRow', page("Row() {\n  Text('a')\n  if (this.selected) {\n    CouliIcon({ name: 'check' })\n  }\n}\n" + role('RADIO')), {S1: 1}),
    ('S1ConditionalSwitch', page(KNOB + '.accessibilityRole(this.flag ? AccessibilityRoleType.SWITCH : AccessibilityRoleType.BUTTON)'), {S1: 1}),
    ('S1ConditionalElseBranch', page(KNOB + '.accessibilityRole(this.flag ? AccessibilityRoleType.BUTTON : AccessibilityRoleType.RADIO)'), {S1: 1}),
    ('S1WrongSystemControl', page("Row() {\n  Checkbox({ name: 'c' })\n}\n" + role('SWITCH')), {S1: 1}),
    ('S1TwoRows', page(KNOB + role('SWITCH') + '\n' + KNOB + role('RADIO')), {S1: 2}),
    # 同文件 @Builder 里没有系统件 → 照报（展开了一层也判不到）
    ('S1BuilderNoSystem', builder_page('  @Builder\n  knob() {\n    Column()\n  }\n', 'Row() {\n  this.knob()\n}\n' + role('SWITCH')), {S1: 1}),
    # 只展开一层：@Builder 里再调 @Builder 才有 Toggle，不算（§2.1「展开一层再判」）
    ('S1BuilderTwoLayers',
     builder_page('  @Builder\n  outer() {\n    this.inner()\n  }\n\n  @Builder\n  inner() {\n    Toggle({ type: ToggleType.Switch })\n  }\n',
                  'Row() {\n  this.outer()\n}\n' + role('SWITCH')), {S1: 1}),
    # ---- S1 不命中 ----
    ('S1LegalCheckboxChild', page("Row() {\n  Checkbox({ name: 'c' })\n    .hitTestBehavior(HitTestMode.None)\n}\n" + role('CHECKBOX')), None),
    ('S1LegalCheckboxGroup', page("Row() {\n  CheckboxGroup({ group: 'g' })\n}\n" + role('CHECKBOX')), None),
    ('S1LegalRadioChild', page("Row() {\n  Radio({ value: 'a', group: 'g' })\n    .hitTestBehavior(HitTestMode.None)\n  Text('a')\n}\n" + role('RADIO')), None),
    ('S1LegalToggleChild', page('Row() {\n  Toggle({ type: ToggleType.Switch })\n}\n' + role('SWITCH')), None),
    ('S1LegalTabsChild', page('Column() {\n  Tabs() {\n  }\n}\n' + role('TAB_BAR')), None),
    ('S1LegalTabContentChild', page('Column() {\n  TabContent() {\n  }\n}\n' + role('TAB_BAR')), None),
    ('S1LegalSegmentButtonChild', page('Column() {\n  SegmentButton({ tabs: this.tabs })\n}\n' + role('TAB_BAR')), None),
    ('S1LegalSegmentButtonV2Child', page('Column() {\n  TabSegmentButtonV2({ items: this.items })\n}\n' + role('TAB_BAR')), None),
    ('S1LegalSelf', page('Toggle({ type: ToggleType.Switch })\n  ' + role('SWITCH')), None),
    ('S1LegalSelfCheckbox', page("Checkbox({ name: 'c' })\n  " + role('CHECKBOX')), None),
    ('S1LegalSelfRadio', page("Radio({ value: 'a', group: 'g' })\n  " + role('RADIO')), None),
    ('S1LegalSameFileBuilder', builder_page('  @Builder\n  toggleBody() {\n    Toggle({ type: ToggleType.Switch })\n  }\n',
                                            'Row() {\n  this.toggleBody()\n}\n' + role('SWITCH')), None),
    ('S1LegalWrapperSwitch', page('Row() {\n  CouliSwitch({ on: this.on })\n}\n' + role('SWITCH')), None),
    ('S1LegalWrapperCheckbox', page('Row() {\n  CouliCheckbox({ on: this.on })\n}\n' + role('CHECKBOX')), None),
    ('S1LegalWrapperCheckboxRow', page('Column() {\n  CouliCheckboxRow({ on: this.on })\n}\n' + role('CHECKBOX')), None),
    ('S1LegalWrapperAgreement', page('Column() {\n  AgreementCheckRow({ agreed: this.on })\n}\n' + role('CHECKBOX')), None),
    ('S1LegalWrapperRadio', page('Row() {\n  CouliRadio({ on: this.on })\n}\n' + role('RADIO')), None),
    ('S1LegalWrapperSegmented', page('Column() {\n  Segmented({ items: this.items })\n}\n' + role('TAB_BAR')), None),
    ('S1LegalWrapperTopTabs', page('Column() {\n  TopTabs({ items: this.items })\n}\n' + role('TAB_BAR')), None),
    ('S1RoleButton', page(KNOB + role('BUTTON')), None),
    ('S1RoleTitleBar', page(KNOB + role('TITLE_BAR')), None),
    ('S1NoRole', page(KNOB.rstrip('\n')), None),
    ('S1CommentString', page("// Row().accessibilityRole(AccessibilityRoleType.SWITCH)\n/* .accessibilityRole(AccessibilityRoleType.CHECKBOX) */\n"
                             "Text('.accessibilityRole(AccessibilityRoleType.RADIO)')"), None),
    ('S1PrefixedName', page(KNOB + '.myAccessibilityRole(AccessibilityRoleType.SWITCH)\n'
                            + KNOB + '.accessibilityRole(MyAccessibilityRoleType.SWITCH)'), None),
    # ---- S2 命中：无按压反馈的可点 ----
    ('S2Row', page('Row() {\n}\n.onClick(() => {\n})'), {S2: 1}),
    ('S2Column', page('Column() {\n}\n.onClick(() => {\n})'), {S2: 1}),
    ('S2Stack', page('Stack() {\n}\n.onClick(() => {\n})'), {S2: 1}),
    ('S2Flex', page('Flex() {\n}\n.onClick(() => {\n})'), {S2: 1}),
    ('S2Text', page("Text('a')\n  .onClick(() => {\n  })"), {S2: 1}),
    ('S2Image', page("Image($r('app.media.a'))\n  .onClick(() => {\n  })"), {S2: 1}),
    ('S2RelativeContainer', page('RelativeContainer() {\n}\n.onClick(() => {\n})'), {S2: 1}),
    ('S2NestedBothCount', page("Row() {\n  Text('a')\n    .onClick(() => {\n    })\n}\n.onClick(() => {\n})"), {S2: 2}),
    ('S2MaskEmptyHandler', page('Stack() {\n}\n.width(\'100%\')\n.onClick(() => {\n})'), {S2: 1}),
    ('S2AfterOtherAttrs', page("Text('link')\n  .fontColor(CouliColors.textLink)\n  .onClick(() => this.open())"), {S2: 1}),
    ('S2InsideForEach', page("ForEach(this.items, (s: string) => {\n  Text(s)\n    .onClick(() => {\n    })\n}, (s: string) => s)"), {S2: 1}),
    ('S2ChildHasFeedbackOnly', page("Row() {\n  Text('a')\n    .clickEffect({ level: ClickEffectLevel.LIGHT })\n}\n.onClick(() => {\n})"), {S2: 1}),
    # ---- S2 不命中 ----
    ('S2StateStyles', page('Row() {\n}\n.stateStyles({ pressed: this.pressedStyle })\n.onClick(() => {\n})'), None),
    ('S2StateStylesAfter', page('Row() {\n}\n.onClick(() => {\n})\n.stateStyles({ pressed: this.pressedStyle })'), None),
    ('S2ClickEffect', page("Text('a')\n  .clickEffect({ level: ClickEffectLevel.LIGHT })\n  .onClick(() => {\n  })"), None),
    ('S2Button', page("Button('ok')\n  .onClick(() => {\n  })"), None),
    ('S2ListItem', page('List() {\n  ListItem() {\n  }\n  .onClick(() => {\n  })\n}'), None),
    ('S2GridItem', page('Grid() {\n  GridItem() {\n  }\n  .onClick(() => {\n  })\n}'), None),
    ('S2Toggle', page('Toggle({ type: ToggleType.Switch })\n  .onClick(() => {\n  })'), None),
    ('S2Checkbox', page("Checkbox({ name: 'c' })\n  .onClick(() => {\n  })"), None),
    ('S2Radio', page("Radio({ value: 'a', group: 'g' })\n  .onClick(() => {\n  })"), None),
    ('S2CustomHead', page('CouliButton({ text: this.t })\n  .onClick(() => {\n  })'), None),
    ('S2CommentString', page("// Row().onClick(() => {})\n/* .onClick( */\nText('.onClick(() => {})')"), None),
    ('S2PrefixedAttr', page("Row() {\n}\n.onClickX(() => {\n})\nText('a')\n  .myonClick(() => {\n  })"), None),
    ('S2NonComponentCall', '@ComponentV2\nexport struct P {\n  show(): void {\n    this.bus.onClick(() => {\n    });\n  }\n\n  build() {\n    Column()\n  }\n}\n', None),
    ('S2ObjectKey', page("Text('a')", top='interface H {\n  onClick: () => void\n}\nconst H1: H = { onClick: () => {} };\n'), None),
    # ---- S3 ----
    ('S3Hit', page('List() {\n}\n.edgeEffect(EdgeEffect.None)'), {S3: 1}),
    ('S3Scroll', page('Scroll() {\n}\n.edgeEffect(EdgeEffect.None)\nList() {\n}\n.edgeEffect(EdgeEffect.None)'), {S3: 2}),
    ('S3Conditional', page('List() {\n}\n.edgeEffect(this.flag ? EdgeEffect.None : EdgeEffect.Spring)'), {S3: 1}),
    ('S3OutsideChain', page("Text('a')", top='const EFFECT: EdgeEffect = EdgeEffect.None;\n'), {S3: 1}),
    ('S3Spring', page('List() {\n}\n.edgeEffect(EdgeEffect.Spring)\nScroll() {\n}\n.edgeEffect(EdgeEffect.Fade)'), None),
    ('S3CommentString', page("// .edgeEffect(EdgeEffect.None)\n/* EdgeEffect.None */\nText('EdgeEffect.None')"), None),
    ('S3PrefixAndLookalike', page("Text('a')", top='const A: number = MyEdgeEffect.None;\nconst B: number = EdgeEffect.NoneLike;\n'), None),
    # ---- S4 ----
    ('S4True', page('NavDestination() {\n}\n.hideTitleBar(true)'), {S4: 1}),
    ('S4Variable', page('NavDestination() {\n}\n.hideTitleBar(this.hidden)'), {S4: 1}),
    ('S4Expression', page('NavDestination() {\n}\n.hideTitleBar(!this.shown)'), {S4: 1}),
    ('S4TrueWithAnimation', page('NavDestination() {\n}\n.hideTitleBar(true, false)'), {S4: 1}),
    ('S4ChainedAttrs', page('NavDestination() {\n}\n.mode(NavDestinationMode.STANDARD)\n.hideTitleBar(true)\n.backgroundColor(CouliColors.backgroundCanvas)'), {S4: 1}),
    ('S4False', page('NavDestination() {\n}\n.hideTitleBar(false)'), None),
    ('S4RootNavigation', page('Navigation() {\n}\n.hideTitleBar(true)\n.mode(NavigationMode.Stack)'), None),
    ('S4NavigationVariable', page('Navigation() {\n}\n.hideTitleBar(this.hidden)'), None),
    ('S4CommentString', page("// NavDestination().hideTitleBar(true)\nText('.hideTitleBar(true)')"), None),
    ('S4PrefixedAttr', page('NavDestination() {\n}\n.hideTitleBarX(true)\n.myhideTitleBar(true)'), None),
    # ---- 豁免 ----
    ('ExS3Reason', page('List() {\n}\n' + DISABLE + S3 + ' -- 弹层与系统拖拽冲突\n.edgeEffect(EdgeEffect.None)'), None),
    ('ExS1Reason', page(KNOB + DISABLE + S1 + ' -- 目录示意\n' + role('SWITCH')), None),
    ('ExS2Reason', page('Row() {\n}\n' + DISABLE + S2 + ' -- 遮罩吞点击\n.onClick(() => {\n})'), None),
    ('ExS4Reason', page('NavDestination() {\n}\n' + DISABLE + S4 + ' -- 全屏网页\n.hideTitleBar(true)'), None),
    ('ExNoReason', page('List() {\n}\n' + DISABLE + S3 + '\n.edgeEffect(EdgeEffect.None)'), {S3: 1, EXR: 1}),
    ('ExEmptyReason', page('List() {\n}\n' + DISABLE + S3 + ' -- \n.edgeEffect(EdgeEffect.None)'), {S3: 1, EXR: 1}),
    ('ExNoReasonNothingBelow', page(DISABLE + S3 + "\nText('a')"), {EXR: 1}),
    ('ExWrongRule', page('List() {\n}\n' + DISABLE + S1 + ' -- 理由\n.edgeEffect(EdgeEffect.None)'), {S3: 1}),
    ('ExNextLineOnly', page(DISABLE + S3 + " -- 理由\nText('a')\nList() {\n}\n.edgeEffect(EdgeEffect.None)"), {S3: 1}),
    ('ExInString', page('List() {\n}\n.edgeEffect(EdgeEffect.None)',
                        top="const S: string = '// couli-style-disable-next-line couli-g1/edge-effect-none -- x';\n"), {S3: 1}),
    ('ExTwoRulesOneLine', page('List() {\n}\n' + DISABLE + S3 + ' ' + S2 + ' -- 同一行两条\n.edgeEffect(EdgeEffect.None)'), None),
    # 只点名写死样式规则、没写理由：归 LINT-STYLE 报，本脚本既不报 exemption-reason 也不豁免
    ('ExStyleRuleNoReason', page('List() {\n}\n' + DISABLE + 'couli-style/no-hex-color\n.edgeEffect(EdgeEffect.None)'), {S3: 1}),
    ('ExStyleRuleWithReason', page('List() {\n}\n' + DISABLE + 'couli-style/no-hex-color -- 理由\n.edgeEffect(EdgeEffect.None)'), {S3: 1}),
    # 系统控件身上的写死样式归 LINT-STYLE，这里不报
    ('StyleNotMine', page("Button('ok').fontSize(14).backgroundColor('#FF0000')"), None),
]

# §2.1 白名单的每个控件各一种用法（组件类放 build()，方法类放 show()）
WHITELIST_BUILD = {
    'Tabs': 'Tabs() {\n}',
    'TabContent': 'TabContent() {\n}',
    'BottomTabBarStyle': "TabContent() {\n}\n.tabBar(new BottomTabBarStyle($r('app.media.a'), 'a'))",
    'SubTabBarStyle': "TabContent() {\n}\n.tabBar(new SubTabBarStyle('a'))",
    'Navigation': 'Navigation() {\n}',
    'NavDestination': 'NavDestination() {\n}',
    'bindSheet': "Text('a').bindSheet(true, this.panel())",
    'bindMenu': "Text('a').bindMenu(this.items)",
    'bindContextMenu': "Text('a').bindContextMenu(this.panel(), ResponseType.LongPress)",
    'List': 'List() {\n}',
    'ListItem': 'List() {\n  ListItem() {\n  }\n}',
    'ListItemGroup': 'List() {\n  ListItemGroup() {\n  }\n}',
    'Refresh': 'Refresh({ refreshing: false }) {\n}',
    'Toggle': 'Toggle({ type: ToggleType.Switch })',
    'Checkbox': "Checkbox({ name: 'c' })",
    'CheckboxGroup': "CheckboxGroup({ group: 'g' })",
    'Radio': "Radio({ value: 'a', group: 'g' })",
    'SegmentButton': 'SegmentButton({ tabs: this.tabs })',
    'TabSegmentButtonV2': 'TabSegmentButtonV2({ items: this.items })',
    'CapsuleSegmentButtonV2': 'CapsuleSegmentButtonV2({ items: this.items })',
    'MultiCapsuleSegmentButtonV2': 'MultiCapsuleSegmentButtonV2({ items: this.items })',
    'Search': 'Search()',
    'TextInput': 'TextInput()',
    'TextArea': 'TextArea()',
    'DatePicker': 'DatePicker()',
    'TextPicker': 'TextPicker({ range: this.items })',
    'Button': "Button('ok')",
    'Divider': 'Divider()',
    'LoadingProgress': 'LoadingProgress()',
    'SymbolGlyph': "SymbolGlyph($r('sys.symbol.checkmark'))",
    'Image': "Image($r('app.media.a'))",
    'Badge': 'Badge({ count: 1, style: {} }) {\n}',
    'PasteButton': 'PasteButton()',
    'ExceptionPrompt': 'ExceptionPrompt({ options: this.options })',
}
WHITELIST_METHOD = {
    'showAlertDialog': "this.getUIContext().showAlertDialog({ message: 'x' });",
    'AlertDialog': "AlertDialog.show({ message: 'x' });",
    'openCustomDialog': 'this.getUIContext().getPromptAction().openCustomDialog(this.node);',
    'ActionSheet': "ActionSheet.show({ title: 'x', message: 'y', sheets: [] });",
    'showToast': "this.getUIContext().getPromptAction().showToast({ message: 'x' });",
}
# lint.SYSTEM_CONTROLS 必须包含的名字（§2.1 第 1 条，SegmentButton 的 V2 各型单独列）
WHITELIST_NAMES = sorted(set(WHITELIST_BUILD) | set(WHITELIST_METHOD))


def whitelist_page(times):
    body = []
    for name in sorted(WHITELIST_BUILD):
        body.extend([WHITELIST_BUILD[name]] * times)
    show = []
    for name in sorted(WHITELIST_METHOD):
        show.extend([WHITELIST_METHOD[name]] * times)
    return ('@Entry\n@ComponentV2\nstruct P {\n  show(): void {\n' + ''.join('    ' + c + '\n' for c in show)
            + '  }\n  build() {\n    Column() {\n'
            + ''.join('      ' + line + '\n' for block in body for line in block.split('\n')) + '    }\n  }\n}\n')


# 四条规则各命中一次的页面（S1 的链上不放 onClick，避免同时算 S2）
ALL_FOUR = page(KNOB + role('SWITCH') + "\nRow() {\n}\n.onClick(() => {\n})\nList() {\n}\n.edgeEffect(EdgeEffect.None)\n"
                "NavDestination() {\n}\n.hideTitleBar(true)")


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def per_file(baseline):
    out = {}
    for rule, files in baseline.items():
        for path, count in files.items():
            out.setdefault(path, {})[rule] = count
    return out


LINT_G1_LINE = re.compile(r'^(\S+):(\d+): \[(couli-g1/[a-z-]+)\] \S')


def g1_lint_hits(out):
    hits = []
    for line in out.splitlines():
        m = LINT_G1_LINE.match(line)
        if m:
            hits.append((m.group(1), int(m.group(2)), m.group(3)))
    return sorted(hits)


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Base(unittest.TestCase):
    maxDiff = None

    def run_script(self, *args, env=None, cwd=None):
        self.assertTrue(SCRIPT.is_file(), '实现脚本不存在：' + str(SCRIPT))
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True,
                              env={**os.environ, **(env or {})}, cwd=cwd or str(ROOT), timeout=900)

    def write_baseline(self, root, baseline):
        r = self.run_script('--root', str(root), '--baseline', str(baseline), '--write-baseline')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return json.loads(baseline.read_text(encoding='utf-8'))

    def check(self, root, baseline_data):
        baseline = root / 'baseline-under-test.json'
        baseline.write_text(json.dumps(baseline_data, ensure_ascii=False), encoding='utf-8')
        r = self.run_script('--root', str(root), '--baseline', str(baseline))
        return r.returncode, r.stdout + r.stderr

    def run_lint(self, root=None):
        args = [sys.executable, str(LINT)] + (['--root', str(root)] if root else [])
        r = subprocess.run(args, capture_output=True, text=True, timeout=900)
        return r.returncode, r.stdout + r.stderr

    def tmp(self):
        d = tempfile.TemporaryDirectory(prefix='g1-controls-')
        self.addCleanup(d.cleanup)
        return Path(d.name)


class RuleCases(Base):
    """§2.1 S1–S4 + §2.2 豁免：每个样例一份文件，按 --write-baseline 的计数核对命中 / 不命中。"""

    def test_rule_cases_counts(self):
        root = self.tmp()
        for name, src, _ in CASES:
            write(root / CASE_DIR / (name + '.ets'), src)
        got = per_file(self.write_baseline(root, root / 'baseline.json'))
        for name, src, want in CASES:
            rel = CASE_DIR + '/' + name + '.ets'
            with self.subTest(case=name):
                self.assertEqual(got.get(rel, {}), want or {}, src)

    def test_fixture_page_hits_lines_and_clean_page(self):
        expected = json.loads((FIX / 'PageHits.expected.json').read_text(encoding='utf-8'))
        root = self.tmp()
        write(root / expected['path'], (FIX / 'PageHits.ets').read_text(encoding='utf-8'))
        clean = 'features/home/src/main/ets/cases/PageClean.ets'
        write(root / clean, (FIX / 'PageClean.ets').read_text(encoding='utf-8'))
        got = per_file(self.write_baseline(root, root / 'baseline.json'))
        self.assertEqual(got.get(expected['path']), expected['counts'])
        self.assertNotIn(clean, got)
        code, out = self.check(root, {})
        self.assertEqual(code, 1, out)
        for rule, lines in expected['lines'].items():
            for line in lines:
                self.assertRegex(out, re.escape('%s:%d:' % (expected['path'], line)) + r'\s*' + re.escape(rule) + r'(\s|$)',
                                 '缺命中行 %s %d\n%s' % (rule, line, out))
        self.assertNotIn('PageClean.ets', out)

    def test_exemption_reason_reported_on_comment_line(self):
        root = self.tmp()
        rel = CASE_DIR + '/Ex.ets'
        write(root / rel, page('List() {\n}\n' + DISABLE + S3 + '\n.edgeEffect(EdgeEffect.None)'))  # 注释在第 8 行，命中在第 9 行
        code, out = self.check(root, {})
        self.assertEqual(code, 1, out)
        self.assertRegex(out, re.escape(rel + ':8:') + r'\s*' + re.escape(EXR))
        self.assertRegex(out, re.escape(rel + ':9:') + r'\s*' + re.escape(S3))


class Whitelist(Base):
    """§3.1-5：白名单里的每个控件在页面范围用 0 次和 N 次，生成的基线都是 {}。"""

    def test_whitelist_controls_never_counted(self):
        for times in (1, 3):
            with self.subTest(times=times):
                root = self.tmp()
                for scope in ['features/home/src/main/ets', 'entry/src/main/ets', 'entry/src/release/ets']:
                    write(root / scope / 'Controls.ets', whitelist_page(times))
                gen = root / 'gen.json'
                self.write_baseline(root, gen)
                self.assertEqual(gen.read_text(encoding='utf-8'), '{}\n', '系统控件不是违反')

    def test_empty_tree_baseline_empty(self):
        root = self.tmp()
        write(root / 'features/home/src/main/ets/A.ets', page("Text('a')"))
        gen = root / 'gen.json'
        self.write_baseline(root, gen)
        self.assertEqual(gen.read_text(encoding='utf-8'), '{}\n')


class Scope(Base):
    """§2.1-3：S1 / S2 / S4 = features/*/src/main、entry/src/main、entry/src/release；S3 另加 common/designsystem/src/main；其余不计。"""
    PAGE_SCOPE = ['features/home/src/main/ets/A.ets', 'features/wallet/src/main/ets/sub/B.ets', 'entry/src/main/ets/trade/C.ets',
                  'entry/src/release/ets/D.ets', 'features/home/src/main/ets/mock/E.ets', 'entry/src/main/ets/build/F.ets']
    LIBRARY = ['common/designsystem/src/main/ets/components/G.ets', 'common/designsystem/src/main/ets/mock/H.ets']
    EXCLUDED = ['entry/src/staging/ets/catalog/I.ets', 'entry/src/staging/ets/variant/J.ets', 'common/core/src/main/ets/K.ets',
                'common/generated/src/main/ets/L.ets', 'features/home/src/test/M.ets', 'features/home/src/ohosTest/ets/test/N.ets',
                'entry/src/ohosTest/ets/test/O.ets', 'common/designsystem/src/ohosTest/ets/test/P.ets',
                'common/designsystem/src/test/Q.ets', 'tools/ci/system-controls/fixtures/R.ets']

    def test_scope_per_rule(self):
        root = self.tmp()
        for rel in self.PAGE_SCOPE + self.LIBRARY + self.EXCLUDED:
            write(root / rel, ALL_FOUR)
        got = per_file(self.write_baseline(root, root / 'baseline.json'))
        for rel in self.PAGE_SCOPE:
            with self.subTest(page=rel):
                self.assertEqual(got.get(rel), {S1: 1, S2: 1, S3: 1, S4: 1})
        for rel in self.LIBRARY:
            with self.subTest(library=rel):
                self.assertEqual(got.get(rel), {S3: 1}, '组件库只算 S3')
        self.assertEqual(sorted(got), sorted(self.PAGE_SCOPE + self.LIBRARY), '范围外不得进基线')

    def test_excluded_only_tree_passes_with_empty_baseline(self):
        root = self.tmp()
        for rel in self.EXCLUDED:
            write(root / rel, ALL_FOUR)
        code, out = self.check(root, {})
        self.assertEqual(code, 0, out)


class BaselineJudgement(Base):
    """§2.2 / §3.1-6：规则 × 文件计数；超出失败、变少失败须降基线、基线里文件不存在失败、基线外新增失败。"""
    F = 'features/home/src/main/ets/A.ets'
    TWO = page('List() {\n}\n.edgeEffect(EdgeEffect.None)\nScroll() {\n}\n.edgeEffect(EdgeEffect.None)')  # 命中在第 8、11 行

    def tree(self, text=None):
        root = self.tmp()
        write(root / self.F, text or self.TWO)
        return root

    def test_equal_passes(self):
        code, out = self.check(self.tree(), {S3: {self.F: 2}})
        self.assertEqual(code, 0, out)

    def test_exceed_fails_and_lists_all_hit_lines(self):
        code, out = self.check(self.tree(), {S3: {self.F: 1}})
        self.assertEqual(code, 1, out)
        for line in (8, 11):
            self.assertRegex(out, re.escape('%s:%d:' % (self.F, line)) + r'\s*' + re.escape(S3), out)

    def test_decrease_fails_and_asks_to_lower_baseline(self):
        code, out = self.check(self.tree(), {S3: {self.F: 3}})
        self.assertEqual(code, 1, out)
        self.assertIn(self.F, out)
        self.assertIn(S3, out)
        self.assertIn('降到 2', out)

    def test_decrease_to_zero_asks_to_delete_entry(self):
        code, out = self.check(self.tree(page("Text('a')")), {S3: {self.F: 1}})
        self.assertEqual(code, 1, out)
        self.assertIn(self.F, out)
        self.assertIn('删除', out)

    def test_baseline_file_missing_from_tree_fails(self):
        gone = 'features/home/src/main/ets/Gone.ets'
        code, out = self.check(self.tree(), {S3: {self.F: 2, gone: 1}})
        self.assertEqual(code, 1, out)
        self.assertIn(gone, out)
        self.assertIn('不存在', out)

    def test_new_file_outside_baseline_fails(self):
        root = self.tree()
        write(root / 'entry/src/main/ets/New.ets', page('NavDestination() {\n}\n.hideTitleBar(true)'))
        code, out = self.check(root, {S3: {self.F: 2}})
        self.assertEqual(code, 1, out)
        self.assertRegex(out, re.escape('entry/src/main/ets/New.ets:8:') + r'\s*' + re.escape(S4))

    def test_swap_rule_same_total_fails(self):
        code, out = self.check(self.tree(page('NavDestination() {\n}\n.hideTitleBar(true)')), {S3: {self.F: 1}})
        self.assertEqual(code, 1, out)
        self.assertIn(S4, out)

    def test_injection_of_each_rule_fails(self):
        for name, snippet, rule, line in [
                ('S1', KNOB + role('SWITCH'), S1, 15), ('S2', 'Row() {\n}\n.onClick(() => {\n})', S2, 14),
                ('S3', 'List() {\n}\n.edgeEffect(EdgeEffect.None)', S3, 14), ('S4', 'NavDestination() {\n}\n.hideTitleBar(true)', S4, 14)]:
            with self.subTest(inject=name):
                root = self.tree(page('List() {\n}\n.edgeEffect(EdgeEffect.None)\nScroll() {\n}\n.edgeEffect(EdgeEffect.None)\n' + snippet))
                code, out = self.check(root, {S3: {self.F: 2}})
                self.assertEqual(code, 1, out)
                self.assertRegex(out, re.escape('%s:%d:' % (self.F, line)) + r'\s*' + re.escape(rule))

    def test_default_baseline_path_under_root(self):
        root = self.tree()
        default = root / 'tools/ci/system-controls-baseline.json'
        r = self.run_script('--root', str(root))
        self.assertEqual(r.returncode, 2, '基线文件缺失应以 2 退出\n' + r.stdout + r.stderr)
        write(default, json.dumps({S3: {self.F: 2}}))
        r = self.run_script('--root', str(root))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_invalid_baseline_exit_2(self):
        root = self.tree()
        for name, text in [('not-json', '{oops'), ('count-not-int', json.dumps({S3: {self.F: '2'}})),
                           ('count-zero', json.dumps({S3: {self.F: 0}})), ('not-object', json.dumps([1, 2])),
                           ('unknown-rule', json.dumps({'couli-g1/nope': {self.F: 1}})),
                           ('style-rule-key', json.dumps({'couli-style/no-hex-color': {self.F: 1}}))]:
            with self.subTest(baseline=name):
                b = root / ('b-%s.json' % name)
                b.write_text(text, encoding='utf-8')
                r = self.run_script('--root', str(root), '--baseline', str(b))
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_all_five_rule_keys_accepted(self):
        root = self.tmp()
        write(root / self.F, page(DISABLE + S3 + "\nText('a')\n" + KNOB + role('SWITCH') + '\nRow() {\n}\n.onClick(() => {\n})\n'
                                  'List() {\n}\n.edgeEffect(EdgeEffect.None)\nNavDestination() {\n}\n.hideTitleBar(true)'))
        code, out = self.check(root, {S1: {self.F: 1}, S2: {self.F: 1}, S3: {self.F: 1}, S4: {self.F: 1}, EXR: {self.F: 1}})
        self.assertEqual(code, 0, out)


class WriteBaseline(Base):
    """§2.2-2：sort_keys、indent=2、ensure_ascii=False、末尾换行、无 0 计数、无时间戳；两次逐字节相同、与创建顺序无关。"""
    FILES = {
        'features/me/src/main/ets/页面.ets': ALL_FOUR,
        'features/home/src/main/ets/B.ets': page('Row() {\n}\n.onClick(() => {\n})\nColumn() {\n}\n.onClick(() => {\n})'),
        'entry/src/main/ets/A.ets': page('NavDestination() {\n}\n.hideTitleBar(true)'),
        'common/designsystem/src/main/ets/components/C.ets': page('List() {\n}\n.edgeEffect(EdgeEffect.None)'),
        'entry/src/release/ets/Clean.ets': page("Button('ok')"),
    }

    def build(self, order):
        root = self.tmp()
        for rel in order:
            write(root / rel, self.FILES[rel])
        return root

    def test_byte_identical_and_canonical(self):
        root = self.build(list(self.FILES))
        a, b = root / 'a.json', root / 'b.json'
        data = self.write_baseline(root, a)
        self.write_baseline(root, b)
        raw = a.read_bytes()
        self.assertEqual(raw, b.read_bytes(), '同一棵树两次 --write-baseline 不一致')
        self.assertEqual(raw.decode('utf-8'), json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + '\n')
        self.assertIn('页面.ets'.encode('utf-8'), raw)
        self.assertEqual(per_file(data), {
            'features/me/src/main/ets/页面.ets': {S1: 1, S2: 1, S3: 1, S4: 1},
            'features/home/src/main/ets/B.ets': {S2: 2},
            'entry/src/main/ets/A.ets': {S4: 1},
            'common/designsystem/src/main/ets/components/C.ets': {S3: 1},
        })
        for rule, files in data.items():
            self.assertIn(rule, ALL_RULES)
            self.assertTrue(files)
            for path, count in files.items():
                self.assertIsInstance(count, int)
                self.assertGreater(count, 0)
                self.assertNotIn('\\', path)
                self.assertFalse(os.path.isabs(path), path)

    def test_independent_of_creation_order(self):
        a = self.build(list(self.FILES))
        b = self.build(list(reversed(list(self.FILES))))
        self.write_baseline(a, a / 'out.json')
        self.write_baseline(b, b / 'out.json')
        self.assertEqual((a / 'out.json').read_bytes(), (b / 'out.json').read_bytes())

    def test_roundtrip_passes(self):
        root = self.build(list(self.FILES))
        self.write_baseline(root, root / 'base.json')
        r = self.run_script('--root', str(root), '--baseline', str(root / 'base.json'))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_incomplete_tree_does_not_write(self):
        root = self.build(list(self.FILES))
        write(root / 'features/home/src/main/ets/Broken.ets', 'const s: string = `abc\n')
        out = root / 'never.json'
        r = self.run_script('--root', str(root), '--baseline', str(out), '--write-baseline')
        self.assertEqual(r.returncode, 4, r.stdout + r.stderr)
        self.assertFalse(out.exists(), '扫不完时不得写出半份基线')


class ExitCodes(Base):
    """§3.1-8：语法错误、不可列举目录、符号链接 → 4；工具链缺失 → 3；参数错 → 2；自测。"""

    def test_syntax_error_exit_4(self):
        for rel in ('features/home/src/main/ets/Broken.ets', 'common/designsystem/src/main/ets/Broken.ets'):
            with self.subTest(path=rel):
                root = self.tmp()
                write(root / rel, 'const s: string = `abc\n')
                code, out = self.check(root, {})
                self.assertEqual(code, 4, out)
                self.assertIn('Broken.ets', out)

    def test_unlistable_dir_exit_4(self):
        root = self.tmp()
        write(root / 'features/home/src/main/ets/A.ets', page("Text('a')"))
        locked = root / 'features/home/src/main/ets/locked'
        write(locked / 'B.ets', page("Text('b')"))
        locked.chmod(0)
        self.addCleanup(locked.chmod, stat.S_IRWXU)
        if os.access(str(locked), os.R_OK):
            self.fail('当前用户能读 chmod 0 的目录（root？），本用例无法构造')
        code, out = self.check(root, {})
        self.assertEqual(code, 4, out)

    def test_symlink_in_scope_exit_4(self):
        for base in ('features/home/src/main/ets', 'common/designsystem/src/main/ets'):
            for kind in ('file', 'dir'):
                with self.subTest(base=base, kind=kind):
                    root = self.tmp()
                    write(root / base / 'A.ets', page("Text('a')"))
                    outside = root / 'outside'
                    write(outside / 'Hidden.ets', page('List() {\n}\n.edgeEffect(EdgeEffect.None)'))
                    link = root / base / ('Linked.ets' if kind == 'file' else 'linked')
                    os.symlink(str(outside / 'Hidden.ets') if kind == 'file' else str(outside), str(link))
                    code, out = self.check(root, {})
                    self.assertEqual(code, 4, out)
                    self.assertIn(base + '/' + link.name, out)

    def test_symlinked_module_or_scope_root_exit_4(self):
        for kind in ('module', 'scope-root', 'library-root'):
            with self.subTest(kind=kind):
                root = self.tmp()
                write(root / 'features/home/src/main/ets/A.ets', page("Text('a')"))
                outside = root / 'outside'
                write(outside / 'src/main/ets/Hidden.ets', page('List() {\n}\n.edgeEffect(EdgeEffect.None)'))
                if kind == 'module':
                    link = root / 'features/linked'
                    os.symlink(str(outside), str(link))
                elif kind == 'scope-root':
                    link = root / 'features/other/src/main'
                    link.parent.mkdir(parents=True)
                    os.symlink(str(outside / 'src/main'), str(link))
                else:
                    link = root / 'common/designsystem/src/main'
                    link.parent.mkdir(parents=True)
                    os.symlink(str(outside / 'src/main'), str(link))
                code, out = self.check(root, {})
                self.assertEqual(code, 4, out)
                self.assertIn(str(link.relative_to(root)), out)

    def test_toolchain_missing_exit_3(self):
        root = self.tmp()
        write(root / 'features/home/src/main/ets/A.ets', page('List() {\n}\n.edgeEffect(EdgeEffect.None)'))
        b = root / 'b.json'
        b.write_text('{}', encoding='utf-8')
        r = self.run_script('--root', str(root), '--baseline', str(b), env={'COULI_HM_NODE': '/nonexistent/couli-node'})
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)

    def test_bad_args_exit_2(self):
        r = self.run_script('--no-such-flag')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_self_test_passes_and_covers_each_rule(self):
        cwd = self.tmp()
        r = self.run_script('--self-test', cwd=str(cwd))
        out = r.stdout + r.stderr
        self.assertEqual(r.returncode, 0, out)
        for rule in ALL_RULES:
            self.assertIn(rule, out, '自测输出没有覆盖 ' + rule)


class LintStyleCoexistence(Base):
    """§2.2-3：豁免注释两边通用；LINT-STYLE 脚本见到 couli-g1/ 规则的有理由注释不报 EXR、也不把 S1–S4 当违反。本类不依赖新脚本。"""

    def test_style_script_ignores_g1_exemption_with_reason(self):
        root = self.tmp()
        rel = 'features/home/src/main/ets/A.ets'
        write(root / rel, page('List() {\n}\n' + DISABLE + S3 + ' -- 弹层与系统拖拽冲突\n.edgeEffect(EdgeEffect.None)\n'
                               'NavDestination() {\n}\n.hideTitleBar(true)'))
        b = root / 'b.json'
        b.write_text('{}', encoding='utf-8')
        r = subprocess.run([sys.executable, str(STYLE_SCRIPT), '--root', str(root), '--baseline', str(b)],
                           capture_output=True, text=True, timeout=900)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class LintWarnings(Base):
    """§2.1 / §3.1-10 / D10-734 ⑤：lint.py 四条只警告（exit 不变），带行号与规则 ID；原 9 类不再警告；HM-LINT 行为不变。"""
    def test_all_four_warn_with_line_and_rule_exit_0(self):
        root = self.tmp()
        rel = 'features/auth/src/main/ets/Page.ets'
        write(root / rel, ALL_FOUR)
        code, out = self.run_lint(root)
        self.assertEqual(code, 0, out)
        self.assertEqual(g1_lint_hits(out), [(rel, 9, S1), (rel, 12, S2), (rel, 16, S3), (rel, 19, S4)], out)

    def test_scopes_match_script(self):
        root = self.tmp()
        for rel in Scope.PAGE_SCOPE[:4] + ['common/designsystem/src/main/ets/components/G.ets'] + Scope.EXCLUDED[:2] + Scope.EXCLUDED[5:8]:
            write(root / rel, ALL_FOUR)
        code, out = self.run_lint(root)
        self.assertEqual(code, 0, out)
        hits = g1_lint_hits(out)
        got = {}
        for rel, _, rule in hits:
            got.setdefault(rel, set()).add(rule)
        for rel in Scope.PAGE_SCOPE[:4]:
            with self.subTest(page=rel):
                self.assertEqual(got.get(rel), set(DETECTORS), out)
        self.assertEqual(got.get('common/designsystem/src/main/ets/components/G.ets'), {S3}, out)
        self.assertEqual(len(got), 5, '范围外不得警告：' + str(sorted(got)))

    def test_original_nine_no_longer_warn(self):
        root = self.tmp()
        for scope in ['features/auth/src/main/ets', 'entry/src/main/ets']:
            for control in ORIGINAL_NINE:
                write(root / scope / control / 'Page.ets', (DS02_WARNING / (control + '.ets')).read_text(encoding='utf-8'))
        code, out = self.run_lint(root)
        self.assertEqual(code, 0, out)
        self.assertNotIn(OLD_MARKER, out)
        self.assertEqual(g1_lint_hits(out), [], out)

    def test_comment_string_prefix_do_not_warn(self):
        root = self.tmp()
        write(root / 'entry/src/main/ets/Legal.ets',
              page("// Row().onClick(() => {}) EdgeEffect.None .hideTitleBar(true)\nText('.onClick( EdgeEffect.None .hideTitleBar(true)')\n"
                   'CouliThing({})\n  .myOnClick(() => {\n  })'))
        code, out = self.run_lint(root)
        self.assertEqual(code, 0, out)
        self.assertEqual(g1_lint_hits(out), [], out)

    def test_hard_rule_still_fails(self):
        root = self.tmp()
        write(root / 'entry/src/main/ets/Bad.ets', "import router from '@ohos.router';\n" + ALL_FOUR)
        code, out = self.run_lint(root)
        self.assertEqual(code, 1, out)
        self.assertIn('HM-LINT-3', out)

    def test_hm_lint_fixtures_still_blocked(self):
        """HM-LINT-1…10 样例目录照旧以 1 失败（行为不变；HM-LINT-11 只在查仓库本身时跑，由 RealTree 覆盖 exit 0）。"""
        for d in sorted(p for p in (ROOT / 'tools/ci/lint-fixtures').iterdir() if p.is_dir() and p.name.startswith('HM-LINT-')):
            with self.subTest(rule=d.name):
                code, out = self.run_lint(d)
                self.assertEqual(code, 1, out)
                self.assertIn(d.name, out)


class G1HostReversal(Base):
    """#24 第一处：ds02/test_host.py:217-254 的反向期望（§2.3）。冻结文件本身由后续专人按交回 §6-1 改；这里先把新判据写成可跑的用例。"""
    SAMPLES = {S1: 'S1-self-drawn-control.ets', S2: 'S2-click-without-feedback.ets', S3: 'S3-edge-effect-none.ets',
               S4: 'S4-hide-title-bar.ets'}
    PAGE_SCOPES = ['features/auth/src/main/ets', 'entry/src/main/ets']
    LIB = 'common/designsystem/src/main/ets/components'

    def lint_one(self, rel, text):
        root = self.tmp()
        write(root / rel, text)
        code, out = self.run_lint(root)
        return code, out, g1_lint_hits(out)

    def test_nine_samples_legal_no_g1_warning_exit_0(self):
        for scope in self.PAGE_SCOPES:
            for control in ORIGINAL_NINE:
                with self.subTest(scope=scope, control=control):
                    code, out, g1 = self.lint_one(scope + '/Violation.ets', (DS02_WARNING / (control + '.ets')).read_text(encoding='utf-8'))
                    self.assertEqual(code, 0, out)
                    self.assertNotIn(OLD_MARKER, out)
                    self.assertEqual(g1, [], out)

    def test_each_self_drawn_sample_warns_exactly_once(self):
        for scope in self.PAGE_SCOPES:
            for rule, sample in self.SAMPLES.items():
                with self.subTest(scope=scope, rule=rule):
                    rel = scope + '/Violation.ets'
                    code, out, g1 = self.lint_one(rel, (G1_SAMPLES / sample).read_text(encoding='utf-8'))
                    self.assertEqual(code, 0, out)
                    self.assertEqual([(p, r) for p, _, r in g1], [(rel, rule)], out)

    def test_library_system_controls_do_not_warn_except_s3(self):
        for control in ORIGINAL_NINE:
            with self.subTest(control=control):
                code, out, g1 = self.lint_one(self.LIB + '/Legal.ets', (DS02_WARNING / (control + '.ets')).read_text(encoding='utf-8'))
                self.assertEqual(code, 0, out)
                self.assertEqual(g1, [], out)
        for rule, sample in self.SAMPLES.items():
            with self.subTest(library_rule=rule):
                rel = self.LIB + '/Legal.ets'
                code, out, g1 = self.lint_one(rel, (G1_SAMPLES / sample).read_text(encoding='utf-8'))
                self.assertEqual(code, 0, out)
                self.assertEqual([r for _, _, r in g1], [S3] if rule == S3 else [], out)

    def test_comment_string_prefixed_function_no_warning_and_hard_rule_fails(self):
        code, out, g1 = self.lint_one('entry/src/main/ets/Legal.ets',
                                      "// Checkbox({})\nconst hint: string = 'Toggle({})';\nfunction MyCheckbox(): void {}\nMyCheckbox();\n")
        self.assertEqual(code, 0, out)
        self.assertEqual(g1, [], out)
        code, out, _ = self.lint_one('entry/src/main/ets/Legal.ets', "import router from '@ohos.router';\n")
        self.assertEqual(code, 1, out)
        self.assertIn('HM-LINT-3', out)

    def test_nine_samples_byte_identical(self):
        for name, want in SAMPLE_SHA256.items():
            with self.subTest(sample=name):
                self.assertEqual(hashlib.sha256((DS02_WARNING / name).read_bytes()).hexdigest(), want, name + ' 被改动（§2.3 原 9 个样例逐字节不动）')


class LintStyleReversal(Base):
    """#24 第三处：test_hardcoded_style.py 里钉 G1 现状的 6 条（§3.2-2）的反向期望，冻结文件本身由后续专人按交回 §6-3 改。
    test_original_nine_still_warn_only → G1HostReversal.test_nine_samples_legal_no_g1_warning_exit_0；test_frozen_files_unchanged →
    G1HostReversal.test_nine_samples_byte_identical（列表去掉 test_host.py）；其余 4 条在本类。"""

    def test_g1_list_replaced_by_whitelist(self):
        """取代 test_g1_list_is_base_nine：不再有 9 类判定名单，改成 SYSTEM_CONTROLS 白名单（扁平的名字集合）。"""
        lint = load_module(LINT, 'couli_lint_g1_probe')
        self.assertFalse(hasattr(lint, 'DESIGN_SYSTEM_REQUIRED'), 'lint.DESIGN_SYSTEM_REQUIRED 应已删除（§2.1-1）')
        self.assertTrue(hasattr(lint, 'SYSTEM_CONTROLS'), 'lint.SYSTEM_CONTROLS 白名单缺失（§2.1-1）')
        names = lint.SYSTEM_CONTROLS
        self.assertIsInstance(names, (list, tuple, set, frozenset), '接口约定：扁平的名字集合')
        self.assertTrue(all(isinstance(n, str) for n in names), names)
        self.assertEqual(sorted(set(WHITELIST_NAMES) - set(names)), [], '白名单缺项（§2.1-1）')

    def test_lint_header_g1_section_new_wording(self):
        """取代 test_lint_header_g1_section_restored：文件头不再有 [design-system-required] 段，改写新口径，HM-LINT-11 文案不动。"""
        head = LINT.read_text(encoding='utf-8').split('"""', 2)[1]
        self.assertNotIn(OLD_MARKER, head)
        for rule in DETECTORS:
            self.assertIn(rule, head, '文件头缺新规则 ' + rule)
        self.assertIn('HM-LINT-11 theme-drift', head)
        self.assertIn('锁定快照', head[head.index('HM-LINT-11 theme-drift'):], 'HM-LINT-11 文案由 TOKENS T14 钉住，不能动')

    def test_ds02_readme_rewritten(self):
        """取代 test_ds02_readme_restored：README 改写成「原九类，D37 下作合法样例」（新 sha 走 #24 换值）。"""
        text = (DS02_WARNING / 'README.md').read_text(encoding='utf-8')
        self.assertIn('D37', text)
        self.assertIn('合法样例', text)
        self.assertNotIn('必须输出 ' + OLD_MARKER, text)

    def test_verify_new_lines_scoped_to_two_steps(self):
        """取代 VerifyStep.test_new_step_present_after_ds02_host 的「新增行白名单」：只检查 LINT-STYLE 那一步的行块，新增的 G1 步另查（VerifyStep 类）。"""
        lines = VERIFY.read_text(encoding='utf-8').splitlines()
        start = lines.index('step "LINT-STYLE 写死样式基线"')
        end = lines.index('record "lint-style" PASS "写死样式基线"')
        block = lines[start:end + 1]
        self.assertTrue(all('hardcoded' in l or 'LINT-STYLE' in l or 'lint-style' in l or l.startswith('#') or not l.strip() for l in block),
                        block)


class VerifyStep(Base):
    """§2.2-4：verify.sh 在「LINT-STYLE 写死样式基线」之后、lint.py 之后加一步「G1 禁自绘系统控件基线」：先 --self-test 再查仓库。"""

    def lines(self):
        return VERIFY.read_text(encoding='utf-8').splitlines()

    def test_step_order_and_commands(self):
        lines = self.lines()
        step = [i for i, l in enumerate(lines) if l.strip() == 'step "G1 禁自绘系统控件基线"']
        self.assertEqual(len(step), 1, '缺步骤「G1 禁自绘系统控件基线」')
        self_test = [i for i, l in enumerate(lines) if 'tools/ci/check_system_controls.py" --self-test' in l and 'fail_fast' in l]
        check = [i for i, l in enumerate(lines) if re.search(r'tools/ci/check_system_controls\.py"\s*\|\|\s*fail_fast', l)]
        self.assertEqual(len(self_test), 1, '缺「--self-test || fail_fast」一行')
        self.assertEqual(len(check), 1, '缺「查本仓库 || fail_fast」一行')
        style = lines.index('record "lint-style" PASS "写死样式基线"')
        lint_step = next(i for i, l in enumerate(lines) if 'tools/ci/lint.py" ||' in l)
        self.assertGreater(step[0], style)
        self.assertGreater(step[0], lint_step)
        self.assertGreater(self_test[0], step[0])
        self.assertGreater(check[0], self_test[0])

    def test_lint_fixtures_step_still_only_hm_lint(self):
        """g1-self-drawn 样例不进 lint-fixtures 步（§2.3）：该步仍只遍历 HM-LINT-*，且样例数仍是 10。"""
        text = VERIFY.read_text(encoding='utf-8')
        self.assertIn('lint-fixtures/HM-LINT-*', text)
        self.assertIn('"$FIXTURE_COUNT" -eq 10', text)


# ---------------------------------------------------------------------------------------- #24 第二处：me12 四份冻结收窄（D10-951 ②）
_DS = 'common/designsystem/src/main/ets/'
EXPECTED_KEEP = {
    'me12v': sorted(_DS + p for p in ['format/CouliFormat.ets', 'format/PriceTerms.ets']),
    'me12wa': sorted(_DS + p for p in ['format/CouliFormat.ets', 'format/PriceTerms.ets', 'components/PendingConfirm.ets',
                                       'components/StepUpPanel.ets', 'components/CodeCells.ets', 'logic/StepUpPanelFit.ets']),
    'me12wb': sorted(_DS + p for p in ['format/CouliFormat.ets', 'format/PriceTerms.ets', 'components/PendingConfirm.ets',
                                       'components/StepUpPanel.ets', 'components/CodeCells.ets', 'logic/StepUpPanelFit.ets',
                                       'components/Clipboard.ets', 'logic/ClipboardPromptLayout.ets']),
    'me12wc': sorted(_DS + p for p in ['format/CouliFormat.ets', 'format/PriceTerms.ets', 'components/PendingConfirm.ets',
                                       'components/StepUpPanel.ets', 'components/CodeCells.ets', 'logic/StepUpPanelFit.ets']),
}
GUARD_SCRIPTS = {'me12v': 'tools/ci/me12v/check_me_visual.py', 'me12wa': 'tools/ci/me12wa/check_settings_visual.py',
                 'me12wb': 'tools/ci/me12wb/check_privacy_visual.py', 'me12wc': 'tools/ci/me12wc/check_risk_visual.py'}
GUARD_OK = {'me12v': 'ME12V_HOST_OK', 'me12wa': 'ME12WA_HOST_OK', 'me12wb': 'ME12WB_HOST_OK', 'me12wc': 'ME12WC_HOST_OK'}


def fixture_tree(rel):
    data = json.loads((ROOT / rel).read_text(encoding='utf-8'))
    return {item[1]: item[0] for item in data['tree']}, data


class FrozenNarrowing(Base):
    """D10-951 ②：冻结清单按 import 图实算（frozen_deps.py，算法写在该文件头），不凭印象。"""

    def deps(self):
        module = load_module(HERE / 'frozen_deps.py', 'couli_frozen_deps')
        return module, module.derive(str(ROOT))

    def test_import_graph_gives_expected_lists(self):
        """算法在当前树上的输出 = 本表（2 / 6 / 8 / 6）。产品 import 变化使本条红时：先判断新依赖是否应进清单，再走 #24 改表和 fixture。"""
        _, report = self.deps()
        for guard, want in EXPECTED_KEEP.items():
            with self.subTest(guard=guard):
                self.assertEqual(report[guard]['keep'], want, report[guard])
                self.assertEqual(report[guard]['missing_guarded'], [], '被守文件在树里找不到，图不完整')

    def test_fixture_designsystem_entries_equal_derived_list(self):
        """收窄后每份 fixture 的 tree 里，common/designsystem/ 的条目恰好等于算出来的清单（实现 #24 后才绿）。"""
        module, report = self.deps()
        for guard, rel in module.FIXTURES.items():
            with self.subTest(guard=guard):
                tree, _ = fixture_tree(rel)
                kept = sorted(p for p in tree if p.startswith('common/designsystem/'))
                self.assertEqual(kept, report[guard]['keep'], guard + ' 的 designsystem 冻结条目应收窄到清单')

    def test_me12wa_staging_tree_removed_append_only_kept(self):
        """D10-951 ②：me12wa 的 staging 整树移出；只许追加的 DebugFakeMe / DebugFakeAccount / BuildVariant 保留。"""
        module, _ = self.deps()
        tree, data = fixture_tree(module.FIXTURES['me12wa'])
        self.assertEqual([p for p in tree if p.startswith('entry/src/staging/')], [], 'staging 整树应移出 tree')
        for rel in ['entry/src/staging/ets/variant/DebugFakeMe.ets', 'entry/src/staging/ets/variant/DebugFakeAccount.ets',
                    'entry/src/staging/ets/variant/BuildVariant.ets']:
            self.assertIn(rel, data['append_only'], '只许追加的文件应保留：' + rel)


class Me12Behaviour(Base):
    """§2.4 / §3.4 / §3.5：判据从整树改成清单后的行为，在真实树的临时副本上跑四份脚本（脚本按自身位置定 ROOT）。
    清单外文件增删改不红（实现前红）；清单内文件改 / 删、只许追加文件被改已有行仍红。"""
    OUTSIDE_MODIFY = _DS + 'components/Overlays.ets'  # C 类，§2.4 的正对照
    OUTSIDE_DELETE = _DS + 'CouliLayout.ets'  # D 类
    OUTSIDE_ADD = _DS + 'components/ZzzNotFrozen.ets'
    INSIDE_MODIFY = _DS + 'format/PriceTerms.ets'
    INSIDE_DELETE = _DS + 'format/CouliFormat.ets'
    STAGING_MODIFY = 'entry/src/staging/ets/variant/DebugFakeHome.ets'
    STAGING_ADD = 'entry/src/staging/ets/catalog/ZzzNotFrozen.ets'

    @classmethod
    def setUpClass(cls):
        cls.tmpdir = tempfile.TemporaryDirectory(prefix='g1-me12-')
        cls.copy = Path(cls.tmpdir.name)
        ignore = shutil.ignore_patterns('build', '.test', 'oh_modules', '.hvigor', '.preview', 'node_modules', '.git')
        for item in sorted(ROOT.iterdir()):
            if item.name == '.git':
                continue
            if item.is_dir():
                shutil.copytree(item, cls.copy / item.name, ignore=ignore, symlinks=True)
            else:
                shutil.copy2(item, cls.copy / item.name)

    @classmethod
    def tearDownClass(cls):
        cls.tmpdir.cleanup()

    def run_guard(self, guard):
        r = subprocess.run([sys.executable, str(self.copy / GUARD_SCRIPTS[guard])], capture_output=True, text=True, timeout=600)
        return r.returncode, r.stdout + r.stderr

    @contextlib.contextmanager
    def mutated(self, rel, fn):
        """改动 / 删除 / 新增一个文件，with 结束恢复（失败时也恢复，互不污染）。"""
        path = self.copy / rel
        original = path.read_bytes() if path.exists() else None
        try:
            fn(path)
            yield
        finally:
            if original is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(original)

    def assertGuardPasses(self, guard, mentioned):
        code, out = self.run_guard(guard)
        self.assertEqual(code, 0, '清单外改动不应使 %s 变红\n%s' % (guard, out))
        self.assertNotIn(mentioned, out)
        self.assertIn(GUARD_OK[guard], out)

    def assertGuardFails(self, guard, mentioned):
        code, out = self.run_guard(guard)
        self.assertEqual(code, 1, '%s 应拦下对 %s 的改动\n%s' % (guard, mentioned, out))
        self.assertIn(mentioned, out)

    def test_control_unmodified_copy_passes_all_four(self):
        for guard in GUARD_SCRIPTS:
            with self.subTest(guard=guard):
                code, out = self.run_guard(guard)
                self.assertEqual(code, 0, out)

    def test_outside_list_modify_not_red(self):
        for guard in GUARD_SCRIPTS:
            with self.subTest(guard=guard), self.mutated(self.OUTSIDE_MODIFY, lambda p: p.write_bytes(p.read_bytes() + b'\n// outside the frozen list\n')):
                self.assertGuardPasses(guard, 'Overlays.ets')

    def test_outside_list_delete_not_red(self):
        for guard in GUARD_SCRIPTS:
            with self.subTest(guard=guard), self.mutated(self.OUTSIDE_DELETE, lambda p: p.unlink()):
                self.assertGuardPasses(guard, 'CouliLayout.ets')

    def test_outside_list_add_not_red(self):
        for guard in GUARD_SCRIPTS:
            with self.subTest(guard=guard), self.mutated(self.OUTSIDE_ADD, lambda p: p.write_text('export const ZZZ: number = 1;\n', encoding='utf-8')):
                self.assertGuardPasses(guard, 'ZzzNotFrozen.ets')

    def test_inside_list_modify_red(self):
        for guard in GUARD_SCRIPTS:
            with self.subTest(guard=guard), self.mutated(self.INSIDE_MODIFY, lambda p: p.write_bytes(p.read_bytes() + b'\n// mutated\n')):
                self.assertGuardFails(guard, 'PriceTerms.ets')

    def test_inside_list_delete_red(self):
        for guard in GUARD_SCRIPTS:
            with self.subTest(guard=guard), self.mutated(self.INSIDE_DELETE, lambda p: p.unlink()):
                self.assertGuardFails(guard, 'CouliFormat.ets')

    def test_clipboard_only_in_wb_list(self):
        """Clipboard.ets 只在 me12wb 的清单里（import 图）：wb 改了红，其余三份不红。"""
        rel = _DS + 'components/Clipboard.ets'
        for guard, red in [('me12wb', True), ('me12v', False), ('me12wa', False), ('me12wc', False)]:
            with self.subTest(guard=guard), self.mutated(rel, lambda p: p.write_bytes(p.read_bytes() + b'\n// mutated\n')):
                if red:
                    self.assertGuardFails(guard, 'Clipboard.ets')
                else:
                    self.assertGuardPasses(guard, 'Clipboard.ets')

    def test_me12wa_staging_tree_no_longer_frozen(self):
        with self.mutated(self.STAGING_MODIFY, lambda p: p.write_bytes(p.read_bytes() + b'\n// not frozen\n')):
            self.assertGuardPasses('me12wa', 'DebugFakeHome.ets')
        with self.mutated(self.STAGING_ADD, lambda p: p.write_text('export const ZZZ: number = 1;\n', encoding='utf-8')):
            self.assertGuardPasses('me12wa', 'ZzzNotFrozen.ets')

    def test_append_only_staging_file_existing_line_red(self):
        rel = 'entry/src/staging/ets/variant/DebugFakeMe.ets'
        for guard in ('me12wa', 'me12wb', 'me12wc'):
            with self.subTest(guard=guard), self.mutated(rel, lambda p: p.write_bytes(re.sub(br'^[^\n]*', b'// mutated first line', p.read_bytes(), count=1))):
                self.assertGuardFails(guard, 'DebugFakeMe.ets')


class NonNullDivision(Base):
    """v2（评审 r1 S2-1）：后缀非空断言 `x!` 后接除号是合法语法，不是正则开头。lint.py 与 check_system_controls.py 都不得因此 exit 4，
    也不得把两个除号之间的代码当正则吞掉；前缀取反 `!/re/` 仍是正则（防矫枉过正）。真正切不准时 exit 4 的用例（ExitCodes、WriteBaseline）不动。"""
    REL = 'features/home/src/main/ets/A.ets'
    FORMS = {'member': 'this.x! / 2', 'element': 'this.a[0]! / 2', 'call': 'this.f()! / 2'}

    def tree(self, text):
        root = self.tmp()
        write(root / self.REL, text)
        return root

    def assert_clean(self, text):
        root = self.tree(text)
        code, out = self.run_lint(root)
        self.assertEqual(code, 0, out)
        self.assertEqual(g1_lint_hits(out), [], out)
        code, out = self.check(root, {})
        self.assertEqual(code, 0, out)
        gen = root / 'gen.json'
        self.write_baseline(root, gen)
        self.assertEqual(gen.read_text(encoding='utf-8'), '{}\n')

    def assert_s3_at(self, text, line):
        root = self.tree(text)
        code, out = self.run_lint(root)
        self.assertEqual(code, 0, out)
        self.assertEqual(g1_lint_hits(out), [(self.REL, line, S3)], out)
        code, out = self.check(root, {S3: {self.REL: 1}})
        self.assertEqual(code, 0, out)
        self.assertEqual(per_file(self.write_baseline(root, root / 'gen.json')), {self.REL: {S3: 1}})

    def test_non_null_then_division_not_exit_4(self):
        for name, expr in self.FORMS.items():
            with self.subTest(form=name):
                self.assert_clean(page('Text(String(%s))' % expr))

    def test_hit_after_division_still_counted(self):
        for name, expr in self.FORMS.items():
            with self.subTest(form=name):
                self.assert_s3_at(page('Text(String(%s))\nList() {\n}\n.edgeEffect(EdgeEffect.None)' % expr), 9)

    def test_code_between_two_divisions_not_swallowed(self):
        """`a! / b! / 2` 同一行两个除号：中间一段是代码，里面的 EdgeEffect.None 照报（第 2 行）。"""
        self.assert_s3_at(page("Text('a')", top='const B: number = 4;\nconst V: number = B! / Number(EdgeEffect.None)! / 2;\n'), 2)

    def test_prefix_negation_regex_still_regex(self):
        """前缀取反：`= !/…/` 与 `return !/…/` 的 `/` 仍是正则开头（正则里的未配对括号不参与配对）。"""
        self.assert_clean(page("Text('a')", top="const S: string = 'x';\nconst OK: boolean = !/a\\(/.test(S);\n"
                                                'function g(s: string): boolean {\n  return !/b\\[/.test(s);\n}\n'))


class RealTree(Base):
    """实现与正式基线落地后才能绿（基线必须在规则提交之后单独生成，§2.2）：真实工作树按正式基线 exit 0，正式基线 == 生成结果。"""

    def test_real_baseline_exists_and_repo_passes(self):
        self.assertTrue(REAL_BASELINE.is_file(), '缺正式基线 ' + str(REAL_BASELINE))
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_real_baseline_equals_generated_twice(self):
        self.assertTrue(REAL_BASELINE.is_file(), '缺正式基线 ' + str(REAL_BASELINE))
        a, b = self.tmp() / 'a.json', self.tmp() / 'b.json'
        for out in (a, b):
            r = self.run_script('--baseline', str(out), '--write-baseline')
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(a.read_bytes(), b.read_bytes(), '两次生成不一致')
        self.assertEqual(a.read_bytes(), REAL_BASELINE.read_bytes(), '正式基线与 --write-baseline 生成结果不一致')

    def test_real_baseline_shape_and_estimates(self):
        self.assertTrue(REAL_BASELINE.is_file(), '缺正式基线 ' + str(REAL_BASELINE))
        data = json.loads(REAL_BASELINE.read_text(encoding='utf-8'))
        self.assertEqual(sorted(set(data) - set(ALL_RULES)), [], '正式基线里有未知规则键')
        page_scope = re.compile(r'^(features/[^/]+/src/main/|entry/src/main/|entry/src/release/)')
        for rule, files in data.items():
            for path in files:
                with self.subTest(rule=rule, path=path):
                    self.assertTrue((ROOT / path).is_file(), path)
                    if rule == S3:
                        self.assertRegex(path, r'^(features/[^/]+/src/main/|entry/src/main/|entry/src/release/|common/designsystem/src/main/)')
                    else:
                        self.assertRegex(path, page_scope)
        self.assertNotIn('entry/src/main/ets/pages/RootPage.ets', data.get(S4, {}), '根 Navigation 不计（§2.1 S4）')
        counts = {rule: sum(data.get(rule, {}).values()) for rule in ALL_RULES}
        # 软断言（§3.1-9）：与任务书估计对照，打印不判，差异由实现者在交回里逐条解释
        print('\n[G1 现状] S1 %d（估 6）、S2 %d（估 85±5）、S3 %d（估 16）、S4 %d（估 21）、exemption %d（估 0）、文件 %d（估 40）'
              % (counts[S1], counts[S2], counts[S3], counts[S4], counts[EXR], len(per_file(data))))

    def test_lint_warning_total_equals_baseline_total(self):
        """§5：真实树 lint.py exit 0、0 处违反、原 9 类警告 0 条、S1–S4 警告总数 = 基线总数。"""
        self.assertTrue(REAL_BASELINE.is_file(), '缺正式基线 ' + str(REAL_BASELINE))
        code, out = self.run_lint()
        self.assertEqual(code, 0, out)
        self.assertIn('lint.py：0 处违反', out)
        self.assertNotIn(OLD_MARKER, out)
        warned = g1_lint_hits(out)
        data = json.loads(REAL_BASELINE.read_text(encoding='utf-8'))
        self.assertEqual(len(warned), sum(sum(data.get(r, {}).values()) for r in DETECTORS), '警告总数与基线总数不一致')


if __name__ == '__main__':
    unittest.main(verbosity=2)
