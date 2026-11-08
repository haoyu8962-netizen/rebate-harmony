#!/usr/bin/env python3
"""LINT-STYLE-harmony 宿主测试（D10-643 ④ / D10-729 / D10-734）。只用标准库 + 本机鸿蒙 SDK 解析链（与 lint.py 同一条），不需要设备。

被测实现：tools/ci/check_hardcoded_style.py（接口写死于 NATIVE/LINT-STYLE/tests-harmony-handback.md）：
    check_hardcoded_style.py [--root <目录>] [--baseline <文件>]          # 检查；默认 root=仓库根，baseline=<root>/tools/ci/hardcoded-style-baseline.json
    check_hardcoded_style.py [--root <目录>] [--baseline <文件>] --write-baseline   # 按现状写基线（不检查，exit 0）
    check_hardcoded_style.py --self-test
退出码：0 通过；1 有违反（超出 / 少于基线 / 基线里的文件不存在 / 基线外新增）；2 参数不对或基线文件缺失 / 非法；
       3 解析工具链不可用（复用 lint.hm10_toolchain）；4 无法保证扫完（语法错误、目录无法列举、文件读不出）。
命中行格式：<相对路径>:<行>: couli-style/<规则> <说明>

v8（编排 D10-901，依据 D37 / couli design/ui-rules #295，对齐安卓 D10-830）：系统控件是首选，lint 不把它们当新增违规。撤回
couli-style/design-system-required/<控件> 规则、按「文件 × 控件」计数的基线与 Divider / LoadingProgress 的豁免口径，基线允许的
规则键只剩 no-hex-color / no-numeric-style / exemption-reason；lint.py G1 名单回到 a819d7a 原 9 项（仍只警告），三个补充样例删除，
ds02-warning/README.md 回到 a819d7a 原文。写死样式、间距收紧（v5）、D10-788 lint.py 扫描范围（v6 / v7）的用例不变（其中混入的
控件计数期望只删不改，逐处见交回 v8 节）。

实现脚本缺失时所有用例应 FAIL（不是 skip、不是语法错误）。"""
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
SCRIPT = ROOT / 'tools/ci/check_hardcoded_style.py'
LINT = ROOT / 'tools/ci/lint.py'
REAL_BASELINE = ROOT / 'tools/ci/hardcoded-style-baseline.json'
BASE_COMMIT = 'cb8191fe5c2112f2e73b52c6a6d507971746ab5b'

HEX = 'couli-style/no-hex-color'
NUM = 'couli-style/no-numeric-style'
EXR = 'couli-style/exemption-reason'
STYLE_RULES = [HEX, NUM, EXR]  # v8（D10-901）：基线允许的规则键只剩这三条
# v8（D10-901）：已撤回的控件规则前缀，只用于反向断言（不得出现在任何基线 / 命中里）
DSR = 'couli-style/design-system-required/'
ORIGINAL_CONTROLS = ['Checkbox', 'Toggle', 'Radio', 'TextInput', 'TextArea', 'Search',
                     'bindSheet', 'openCustomDialog', 'showToast']
WITHDRAWN_CONTROLS = ['Button', 'Divider', 'LoadingProgress']  # D10-734 补进 G1，D10-901 撤回
ALL_CONTROLS = ORIGINAL_CONTROLS + WITHDRAWN_CONTROLS
DS02_WARNING = ROOT / 'tools/ci/lint-fixtures/ds02-warning'
DS02_README_SHA256 = 'e8cbef0641fa89f571716a0547c472e4c6366a9902dbbfdb3e231a6939dddcc4'  # FU-HM-G1-SYSTEM-CONTROLS #24，换值见交回 §6-3
CASE_DIR = 'features/home/src/main/ets/cases'


def page(body, top=''):
    """把若干行 ArkUI 放进一个合成页面的 build() 里。"""
    return (top + '@Entry\n@ComponentV2\nstruct P {\n  build() {\n    Column() {\n'
            + '\n'.join('      ' + line for line in body.split('\n')) + '\n    }\n  }\n}\n')


def method(body):
    """放进普通方法体（openCustomDialog / showToast 等非 build 调用）。"""
    return ('@ComponentV2\nexport struct P {\n  show(): void {\n    ' + body + '\n  }\n  build() {\n    Column() {}\n  }\n}\n')


# v8（D10-901）：12 个系统控件（lint 原 9 项 + 撤回的 3 项）各一种直接调用写法
CONTROL_CALLS = {
    'Checkbox': "Checkbox({ name: 'c' })", 'Toggle': 'Toggle({ type: ToggleType.Switch })',
    'Radio': "Radio({ value: 'r', group: 'g' })", 'TextInput': "TextInput({ placeholder: 'p' })",
    'TextArea': 'TextArea()', 'Search': 'Search()', 'bindSheet': "Text('a').bindSheet(true, this.panel())",
    'openCustomDialog': 'this.getUIContext().getPromptAction().openCustomDialog(this.node);',
    'showToast': "this.getUIContext().getPromptAction().showToast({ message: 'x' });",
    'Button': "Button('ok')", 'Divider': 'Divider()', 'LoadingProgress': 'LoadingProgress()',
}
METHOD_CONTROLS = {'openCustomDialog', 'showToast'}


def control_page(controls, extra=()):
    """v8：合成页面——extra 各行与组件类控件放进 build() 的 Column，弹窗方法（openCustomDialog / showToast）放进 show()。"""
    body = list(extra) + [CONTROL_CALLS[c] for c in controls if c not in METHOD_CONTROLS]
    calls = [CONTROL_CALLS[c] for c in controls if c in METHOD_CONTROLS]
    return ('@Entry\n@ComponentV2\nstruct P {\n  show(): void {\n' + ''.join('    ' + c + '\n' for c in calls)
            + '  }\n  build() {\n    Column() {\n' + ''.join('      ' + b + '\n' for b in body) + '    }\n  }\n}\n')


DISABLE = '// couli-style-disable-next-line '

# (名字, 源码, 期望的「规则 → 计数」；None = 本文件不得出现在基线里；partial=True 时只核对列出的规则)
CASES = [
    # ---- no-hex-color 命中 ----
    ('HexRRGGBB', page("Text('a').fontColor('#FF0000')"), {HEX: 1}),
    ('HexAARRGGBB', page("Text('a').backgroundColor('#CC000000')"), {HEX: 1}),
    ('HexRGB', page("Text('a').fontColor('#FFF')"), {HEX: 1}),
    ('HexRGBA', page("Text('a').fontColor('#FFFA')"), {HEX: 1}),
    ('HexLowerDouble', page('Text(\'a\').fontColor("#00ff00")'), {HEX: 1}),
    ('Hex0x8', page("Text('a').fontColor(0xFF112233)"), {HEX: 1}),
    ('Hex0x6', page("Text('a').fontColor(0x112233)"), {HEX: 1}),
    ('HexFuncRgba', page("Text('a').backgroundColor('rgba(0, 0, 0, 0.5)')"), {HEX: 1}),
    ('HexFuncRgb', page("Text('a').backgroundColor('rgb(1, 2, 3)')"), {HEX: 1}),
    ('HexColorWhite', page("Text('a').fontColor(Color.White)"), {HEX: 1}),
    ('HexColorEnums', page("Text('a').fontColor(Color.Black)\nText('b').backgroundColor(Color.Red)\nText('c').fontColor(Color.Gray)"),
     {HEX: 3}),
    ('HexGradient', page("Text('a').linearGradient({ colors: [['#00000000', 0.0], ['#99000000', 1.0]] })"), {HEX: 2}),
    # ---- no-hex-color 不命中 ----
    ('HexTransparent', page("Text('a').backgroundColor(Color.Transparent)"), None),
    ('HexRoute', page("Text(ROUTE)", top="const ROUTE: string = '#/route';\nconst ANCHOR: string = '#section-1';\n"
                      "const NOT_HEX: string = '#GGGGGG';\n"), None),
    ('HexComment', page("// Text('a').fontColor('#FF0000')\n/* Color.White 0xFF000000 rgba(0, 0, 0, 0.5) */\nText('a')"), None),
    ('HexBitmask', page("Text('a')", top='const MASK: number = 0x1F;\n'), None),
    ('HexTokens', page("Text('a').fontColor(CouliColors.textPrimary)\nText('b').fontColor($r('app.color.color_brand'))\n"
                       "Text('c').fontColor(couliColorResource('color_brand'))"), None),
    ('HexInsideOtherString', page("Text('.fontColor(Color.White)')"), None),
    # ---- no-numeric-style 命中 ----
    ('NumFontSize', page("Text('a').fontSize(14)"), {NUM: 1}),
    ('NumFontSizeVp', page("Text('a').fontSize('14vp')"), {NUM: 1}),
    ('NumFontSizeFp', page("Text('a').fontSize('16fp')"), {NUM: 1}),
    ('NumFontSizeDecimal', page("Text('a').fontSize(13.5)"), {NUM: 1}),
    ('NumFontSizeProp', page("Text('a')", top='interface TitleStyle {\n  fontSize: number\n}\n'
                                          'const TITLE: TitleStyle = { fontSize: 14 };\n'), {NUM: 1}),
    ('NumRadius', page("Text('a').borderRadius(8)"), {NUM: 1}),
    ('NumRadiusVp', page("Text('a').borderRadius('12vp')"), {NUM: 1}),
    ('NumRadiusCorners', page("Text('a').borderRadius({ topLeft: 8, topRight: 8 })"), {NUM: 2}),
    ('NumRadiusCornersZero', page("Text('a').borderRadius({ topLeft: 12, bottomRight: 0, bottomLeft: CouliRadius.card })"),
     {NUM: 1}),
    ('NumBorderRadiusKey', page("Text('a').border({ width: 1, radius: 8, color: CouliColors.divider })"), {NUM: 1}),
    ('NumPadding', page("Text('a').padding(8)"), {NUM: 1}),
    ('NumPaddingPx', page("Text('a').padding('8px')"), {NUM: 1}),
    ('NumMarginLpx', page("Text('a').margin('4lpx')"), {NUM: 1}),
    ('NumPaddingObj', page("Text('a').padding({ top: 8, left: 12 })"), {NUM: 2}),
    ('NumPaddingMultiline', page("Text('a')\n  .padding({\n    top: 6,\n    bottom: 6\n  })"), {NUM: 2}),
    ('NumPaddingMixed', page("Text('a').padding({ top: CouliSpacing.space2, bottom: 6 })"), {NUM: 1}),
    ('NumMarginNegObj', page("Text('a').margin({ top: -12 })"), {NUM: 1}),
    ('NumMarginNeg', page("Text('a').margin(-5)"), {NUM: 1}),
    ('NumMarginNegVp', page("Text('a').margin('-4vp')"), {NUM: 1}),
    ('NumMarginRightZero', page("Text('a').margin({ right: 7, bottom: 0 })"), {NUM: 1}),
    ('NumRowSpace', page("Row({ space: 2 }) {\n  Text('a')\n}"), {NUM: 1}),
    ('NumColumnSpace', page("Column({ space: 6 }) {\n  Text('a')\n}"), {NUM: 1}),
    ('NumListSpace', page("List({ space: 8 }) {\n}"), {NUM: 1}),
    ('NumRowSpaceVp', page("Row({ space: '4vp' }) {\n  Text('a')\n}"), {NUM: 1}),
    # ---- v3（评审 r1 S1-2 / S2-1 / S2-4）----
    ('NumFontObj', page("Text('a').font({ size: 14 })"), {NUM: 1}),
    ('NumFontObjVp', page("Text('a').font({ size: '14vp', weight: FontWeight.Bold })"), {NUM: 1}),
    # v8（D10-901）：下面三例只删掉期望里的 TextInput 控件计数（系统控件不再计），源码与写死样式期望原样
    ('NumPlaceholderFont', page("TextInput().placeholderFont({ size: '14fp' })"), {NUM: 1}),
    ('NumPlaceholderFontNum', page("TextInput().placeholderFont({ size: 13, weight: FontWeight.Normal })"),
     {NUM: 1}),
    ('NumFontObjTokens', page("Text('a').font({ size: CouliTypography.body.fontSize })\n"
                              "TextInput().placeholderFont({ size: $r('app.float.body') })\nText('b').font({ size: 0 })"),
     None),
    ('NumRadiusBottomCorners', page("Text('a').borderRadius({ bottomLeft: 8, bottomRight: 8 })"), {NUM: 2}),
    ('NumRadiusAllCorners', page("Text('a').borderRadius({ topLeft: 1, topRight: 2, bottomLeft: 3, bottomRight: 4 })"), {NUM: 4}),
    # v4（评审 r2 S3）：本地化角键
    ('NumRadiusLocalizedCorners',
     page("Text('a').borderRadius({ topStart: 1, topEnd: 2, bottomStart: 3, bottomEnd: 4 })"), {NUM: 4}),
    ('NumBorderRadiusLocalizedCorners',
     page("Text('a').border({ radius: { topStart: 8, topEnd: 8, bottomStart: 8, bottomEnd: 8 } })"), {NUM: 4}),
    ('NumFontSizePropNotFirst', page("Text('a')", top='interface TitleStyle {\n  color: ResourceColor\n  fontSize: number\n}\n'
                                                   'const TITLE: TitleStyle = { color: CouliColors.textPrimary, fontSize: 14 };\n'),
     {NUM: 1}),
    ('NumFontSizePropMany', page("Text('a')", top='interface TitleStyle {\n  color?: ResourceColor\n  fontSize: number\n}\n'
                                               'const TITLES: TitleStyle[] = [{ fontSize: 12 }, { color: CouliColors.textPrimary, fontSize: 14 }];\n'),
     {NUM: 2}),
    ('NumBorderRadiusCorners', page("Text('a').border({ radius: { topLeft: 8, bottomRight: 8 } })"), {NUM: 2}),
    ('NumBorderRadiusCornerOne', page("Text('a').border({ width: 1, radius: { bottomLeft: 6 }, color: CouliColors.divider })"),
     {NUM: 1}),
    ('NumListItemGroupSpace', page("List() {\n  ListItemGroup({ space: 8 }) {\n  }\n}"), {NUM: 1}),
    # ---- v5（对照安卓评审 r1 S1：间距类命名参数不只 padding / margin）----
    ('GapGridColumns', page("Grid() {\n}\n.columnsGap(8)"), {NUM: 1}),
    ('GapGridRowsVp', page("Grid() {\n}\n.rowsGap('12vp')"), {NUM: 1}),
    ('GapGridNegative', page("Grid() {\n}\n.columnsGap(-4)"), {NUM: 1}),
    ('GapWaterFlowBoth', page("WaterFlow() {\n}\n.columnsGap(10)\n.rowsGap(10)"), {NUM: 2}),
    ('GapSwiperItemSpace', page("Swiper() {\n}\n.itemSpace(8)"), {NUM: 1}),
    ('GapSwiperItemSpaceVp', page("Swiper() {\n}\n.itemSpace('8vp')"), {NUM: 1}),
    ('GapSwiperItemSpaceNeg', page("Swiper() {\n}\n.itemSpace(-2)"), {NUM: 1}),
    ('GapSwiperPrevNextMargin', page("Swiper() {\n}\n.prevMargin(16)\n.nextMargin(16)"), {NUM: 2}),
    ('GapListLanesGutter', page("List() {\n}\n.lanes(2, 8)"), {NUM: 1}),
    ('GapListLanesConstrainGutter', page("List() {\n}\n.lanes({ minLength: 100, maxLength: 200 }, 12)"), {NUM: 1}),
    ('GapGridRowGutter', page("GridRow({ gutter: 8 }) {\n}"), {NUM: 1}),
    ('GapGridRowGutterXY', page("GridRow({ columns: 4, gutter: { x: 8, y: 12 } }) {\n}"), {NUM: 2}),
    ('GapTabsBarGridAlign', page("Tabs() {\n}\n.barGridAlign({ sm: 4, margin: 12, gutter: 8 })"), {NUM: 2}),
    ('GapSafeAreaPadding', page("Text('a').safeAreaPadding(8)"), {NUM: 1}),
    ('GapSafeAreaPaddingObj', page("Text('a').safeAreaPadding({ top: 8, bottom: 0 })"), {NUM: 1}),
    ('GapSelectSpace', page("Select([{ value: 'a' }])\n  .space(8)"), {NUM: 1}),
    ('GapNotHits', page("Grid() {\n}\n.columnsGap(CouliSpacing.space2)\n.rowsGap(0)\n"
                        "WaterFlow() {\n}\n.columnsGap($r('app.float.gap'))\n.rowsGap('0vp')\n"
                        "Swiper() {\n}\n.itemSpace(CouliSpacing.space1)\n.prevMargin(0)\n.nextMargin(CouliSpacing.space4)\n"
                        "List() {\n}\n.lanes(3)\nList() {\n}\n.lanes(2, CouliSpacing.space2)\n"
                        "GridRow({ columns: 4, gutter: { x: CouliSpacing.space2, y: 0 } }) {\n}\n"
                        "Tabs() {\n}\n.barGridAlign({ sm: 4 })\nText('a').safeAreaPadding(0)"), None),
    ('GapFlexSpaceWrapped', page("Flex({ space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(4) } }) {\n}"), None),
    # ---- no-numeric-style 不命中 ----
    ('NumZero', page("Text('a').fontSize(0)\nText('b').padding(0)\nText('c').margin({ top: 0, left: 0 })\n"
                     "Text('d').borderRadius('0vp')\nColumn({ space: 0 }) {\n}"), None),
    ('NumPercent', page("Text('a').margin({ left: '5%' })\nText('b').padding('10%')"), None),
    ('NumTokens', page("Text('a').fontSize(CouliTypography.body.fontSize)\nText('b').borderRadius(CouliRadius.button)\n"
                       "Text('c').padding(CouliSpacing.space4)\nText('d').margin({ top: CouliSpacing.space2 })\n"
                       "Row({ space: CouliSpacing.space1 }) {\n}\nText('e').fontSize($r('app.float.title'))"), None),
    ('NumLocalConst', page("Text('a').padding(GAP).borderRadius(BRAND_RADIUS)",
                           top='const GAP: number = 6;\nconst BRAND_RADIUS: number = 20;\n'), None),
    ('NumCalls', page("Text('a').fontSize(iconVp(CouliComponentMetrics.iconMedium))\n"
                      "Text('b').padding({ start: LengthMetrics.vp(8) })"), None),
    ('NumSize', page("Text('a').width(100).height(48)\nText('b').size({ width: 24, height: 24 })"), None),
    ('NumBorderWidth', page("Text('a').border({ width: { top: 1 }, color: CouliColors.divider })\nText('b').borderWidth(1)"), None),
    ('NumShadow', page("Text('a').shadow({ radius: 8, color: CouliColors.divider, offsetX: 0, offsetY: 2 })"), None),
    ('NumPlainObject', page("Text('a')", top='interface Edges {\n  top: number\n  left: number\n}\n'
                                          'const EDGES: Edges = { top: 8, left: 4 };\n'), None),
    ('NumOffset', page("Text('a').offset({ x: 2, y: -4 }).position({ x: 8 })"), None),
    ('NumCommentString', page("// Text('a').fontSize(14).padding(8)\n/* Row({ space: 2 }) .borderRadius(8) */\n"
                              "Text('.padding(8) fontSize: 14 .borderRadius(8)')"), None),
    ('NumTypePosition', page("Text('a')", top='interface S {\n  fontSize: number\n  space: number\n}\n'), None),
    # ---- exemption-reason ----
    ('ExHexReason', page(DISABLE + "couli-style/no-hex-color -- 渐变透明端点\nText('a').fontColor('#00000000')"), None),
    ('ExNumReason', page(DISABLE + "couli-style/no-numeric-style -- 设计稿特例\nText('a').padding(6)"), None),
    ('ExTwoOnLine', page(DISABLE + "couli-style/no-hex-color -- 渐变两端\n"
                         "Text('a').linearGradient({ colors: [['#00000000', 0.0], ['#99000000', 1.0]] })"), None),
    ('ExNoReason', page(DISABLE + "couli-style/no-hex-color\nText('a').fontColor('#CC000000')"), {HEX: 1, EXR: 1}),
    ('ExEmptyReason', page(DISABLE + "couli-style/no-hex-color -- \nText('a').fontColor('#CC000000')"), {HEX: 1, EXR: 1}),
    ('ExNoReasonNothingBelow', page(DISABLE + "couli-style/no-numeric-style\nText('a')"), {EXR: 1}),
    ('ExWrongRule', page(DISABLE + "couli-style/no-numeric-style -- 理由\nText('a').fontColor('#CC000000')"), {HEX: 1}),
    ('ExNextLineOnly', page(DISABLE + "couli-style/no-hex-color -- 理由\nText('a')\nText('b').fontColor('#CC000000')"), {HEX: 1}),
    ('ExInString', page("Text('a').fontColor('#CC000000')",
                        top="const S: string = '// couli-style-disable-next-line couli-style/no-hex-color -- x';\n"), {HEX: 1}),
    # v8（D10-901）：Divider / LoadingProgress 的豁免口径撤回，ExDividerReason / ExLoadingReason 两例删除。点名已撤回的控件规则的
    # 豁免注释不再特殊：没写理由照报 exemption-reason（同 ExNoReasonNothingBelow），写了理由不报任何违规；下一行的控件不计
    ('ExDividerNoReason', page(DISABLE + "couli-style/design-system-required/Divider\nDivider()"), {EXR: 1}),
    ('ExWithdrawnButtonRule', page(DISABLE + "couli-style/design-system-required/Button -- 想豁免\nButton('ok')"), None),
    # ---- v8（D10-901 翻转）：12 个系统控件直接用——不报任何违规、不进基线（原为各计 1）----
    ('DsCheckbox', page("Checkbox({ name: 'c' })"), None),
    ('DsToggle', page('Toggle({ type: ToggleType.Switch })'), None),
    ('DsRadio', page("Radio({ value: 'r', group: 'g' })"), None),
    ('DsTextInput', page("TextInput({ placeholder: 'p' })"), None),
    ('DsTextArea', page('TextArea()'), None),
    ('DsSearch', page('Search()'), None),
    ('DsBindSheet', page("Text('a').bindSheet(true, this.panel())", ), None),
    ('DsOpenCustomDialog', method('this.getUIContext().getPromptAction().openCustomDialog(this.node);'), None),
    ('DsShowToast', method("this.getUIContext().getPromptAction().showToast({ message: 'x' });"), None),
    ('DsButton', page("Button('ok')"), None),
    ('DsButtonTwice', page("Button('ok')\nButton('cancel')"), None),
    ('DsDivider', page('Divider()'), None),
    ('DsLoadingProgress', page('LoadingProgress()'), None),
    # 系统控件身上的写死样式照报（只是控件本身不计）
    ('DsButtonStyled', page("Button('ok').fontSize(14).backgroundColor('#FF0000')\nLoadingProgress().margin(6)"),
     {NUM: 2, HEX: 1}),
    ('DsNotHits', page("CouliButton({ text: 'ok' })\nMyLoadingProgress()\n// Button('x') Divider()\nText('Divider() Button()')\n"
                       "this.kit.Button()"), None),
]


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


class Base(unittest.TestCase):
    maxDiff = None

    def run_script(self, *args, env=None, cwd=None):
        self.assertTrue(SCRIPT.is_file(), '实现脚本不存在：' + str(SCRIPT))
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True,
                              env={**os.environ, **(env or {})}, cwd=cwd or str(ROOT), timeout=900)

    def write_baseline(self, root, baseline):
        r = self.run_script('--root', str(root), '--baseline', str(baseline), '--write-baseline')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(Path(baseline).is_file(), '--write-baseline 没有写出基线\n' + r.stdout + r.stderr)
        return json.loads(Path(baseline).read_text(encoding='utf-8'))

    def check(self, root, baseline_data):
        baseline = Path(root) / '_baseline.json'
        baseline.write_text(json.dumps(baseline_data, ensure_ascii=False), encoding='utf-8')
        r = self.run_script('--root', str(root), '--baseline', str(baseline))
        return r.returncode, r.stdout + r.stderr

    def tmp(self):
        d = tempfile.TemporaryDirectory(prefix='lint-style-')
        self.addCleanup(d.cleanup)
        return Path(d.name)


def per_file(baseline):
    out = {}
    for rule, files in baseline.items():
        for path, count in files.items():
            out.setdefault(path, {})[rule] = count
    return out


def git_show(rel, commit=BASE_COMMIT):
    """底版里该文件的原文（bytes）；取不到时以断言失败（不是 skip）。"""
    r = subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (commit, rel)], capture_output=True)
    if r.returncode != 0:
        raise AssertionError('git show %s:%s 失败：%s' % (commit, rel, r.stderr.decode('utf-8', 'replace')))
    return r.stdout


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def g1_section(lint_source):
    """lint.py 文件头里 [design-system-required] 那一段（到 HM-LINT-10 为止）。"""
    head = lint_source.split('"""', 2)[1]
    return head.split('[design-system-required]', 1)[1].split('HM-LINT-10', 1)[0]


def g1_list_block(lint_source):
    """lint.py 里 DESIGN_SYSTEM_REQUIRED = [ … ] 的源码块（含块内注释）。"""
    m = re.search(r'^DESIGN_SYSTEM_REQUIRED = \[\n.*?^\]\n', lint_source, re.M | re.S)
    if m is None:
        raise AssertionError('lint.py 里找不到 DESIGN_SYSTEM_REQUIRED = [ … ] 源码块')
    return m.group(0)


class RuleCases(Base):
    """§2.1 三类规则 + 豁免：每个样例一份文件，按 --write-baseline 的计数核对命中 / 不命中。
    v8（D10-901）：12 个系统控件的样例翻转为「不命中」（不进基线），控件身上的写死样式照报。"""

    def test_rule_cases_counts(self):
        root = self.tmp()
        for name, src, *_ in CASES:
            write(root / CASE_DIR / (name + '.ets'), src)
        got = per_file(self.write_baseline(root, root / 'baseline.json'))
        for name, src, want, *rest in CASES:
            partial = bool(rest and rest[0])
            rel = CASE_DIR + '/' + name + '.ets'
            with self.subTest(case=name):
                actual = got.get(rel, {})
                if want is None:
                    self.assertEqual(actual, {}, '%s 不应命中\n%s' % (name, src))
                elif partial:
                    self.assertEqual({k: actual.get(k) for k in want}, want, src)
                else:
                    self.assertEqual(actual, want, src)

    def test_fixture_page_hits_lines_and_clean_page(self):
        expected = json.loads((FIX / 'PageHits.expected.json').read_text(encoding='utf-8'))
        root = self.tmp()
        write(root / expected['path'], (FIX / 'PageHits.ets').read_text(encoding='utf-8'))
        write(root / 'features/home/src/main/ets/PageClean.ets', (FIX / 'PageClean.ets').read_text(encoding='utf-8'))
        got = per_file(self.write_baseline(root, root / 'baseline.json'))
        self.assertEqual(got.get(expected['path']), expected['counts'])
        self.assertNotIn('features/home/src/main/ets/PageClean.ets', got)
        code, out = self.check(root, {})
        self.assertEqual(code, 1, out)
        for rule, lines in expected['lines'].items():
            for line in lines:
                self.assertRegex(out, re.escape('%s:%d:' % (expected['path'], line)) + r'.*' + re.escape(rule) + r'(\s|$)',
                                 '缺命中行 %s %d\n%s' % (rule, line, out))
        self.assertNotIn('PageClean.ets', out)


class Scope(Base):
    """§1.3 / D10-734 ④：features/*/src/main、entry/src/main、entry/src/release 纳入；其余排除。
    v3（评审 r1 S1-1，规则修正）：范围内任意层名为 mock / build 的目录照扫（会编进安装包），不再排除。
    v8（D10-901）：HIT 里的 Button 不再计（系统控件撤出本脚本），纳入路径的期望只剩 HEX / NUM 各 1。"""
    HIT = page("Text('a').fontColor('#FF0000').fontSize(14)\nButton('ok')")
    INCLUDED = ['features/home/src/main/ets/A.ets', 'features/wallet/src/main/ets/sub/B.ets',
                'entry/src/main/ets/trade/C.ets', 'entry/src/release/ets/D.ets',
                'features/home/src/main/ets/mock/L.ets', 'entry/src/main/ets/mock/M.ets',
                'features/home/src/main/ets/build/O.ets', 'entry/src/release/ets/mock/P.ets',
                'entry/src/main/ets/build/Q.ets',
                # v4（评审 r2 S2-2）：lint.SKIP_DIRS 里其余目录名（ohosTest 属测试语义，不在此列）在页面范围内同样照扫
                'features/home/src/main/ets/oh_modules/R.ets', 'entry/src/main/ets/node_modules/S.ets',
                'features/wallet/src/main/ets/.hvigor/T.ets', 'entry/src/release/ets/.test/U.ets',
                'features/me/src/main/ets/.preview/V.ets']
    EXCLUDED = ['entry/src/staging/ets/catalog/E.ets', 'common/designsystem/src/main/ets/components/F.ets',
                'common/core/src/main/ets/G.ets', 'common/generated/src/main/ets/H.ets',
                'features/home/src/test/I.ets', 'features/home/src/ohosTest/ets/test/J.ets',
                'entry/src/ohosTest/ets/test/K.ets', 'tools/ci/hardcoded-style/fixtures/N.ets']

    def test_scope(self):
        root = self.tmp()
        for rel in self.INCLUDED + self.EXCLUDED:
            write(root / rel, self.HIT)
        got = per_file(self.write_baseline(root, root / 'baseline.json'))
        for rel in self.INCLUDED:
            with self.subTest(included=rel):
                self.assertEqual(got.get(rel), {HEX: 1, NUM: 1})
        for rel in self.EXCLUDED:
            with self.subTest(excluded=rel):
                self.assertNotIn(rel, got)
        self.assertEqual(sorted(got), sorted(self.INCLUDED))

    def test_excluded_only_tree_passes_with_empty_baseline(self):
        root = self.tmp()
        for rel in self.EXCLUDED:
            write(root / rel, self.HIT)
        code, out = self.check(root, {})
        self.assertEqual(code, 0, out)


class BaselineJudgement(Base):
    """§2.1 判定 / D10-734 ①：规则 × 文件计数；超出失败、变少失败须降基线、基线里文件不存在失败、基线外新增失败。"""
    F = 'features/home/src/main/ets/A.ets'
    TWO_HEX = page("Text('a').fontColor('#FF0000')\nText('b').fontColor('#00FF00')")  # 命中在第 6、7 行

    def tree(self, text=None):
        root = self.tmp()
        write(root / self.F, text or self.TWO_HEX)
        return root

    def test_equal_passes(self):
        code, out = self.check(self.tree(), {HEX: {self.F: 2}})
        self.assertEqual(code, 0, out)

    def test_exceed_fails_and_lists_all_hit_lines(self):
        code, out = self.check(self.tree(), {HEX: {self.F: 1}})
        self.assertEqual(code, 1, out)
        for line in (6, 7):
            self.assertRegex(out, re.escape('%s:%d:' % (self.F, line)) + r'.*' + re.escape(HEX), out)

    def test_decrease_fails_and_asks_to_lower_baseline(self):
        code, out = self.check(self.tree(), {HEX: {self.F: 3}})
        self.assertEqual(code, 1, out)
        self.assertIn(self.F, out)
        self.assertIn(HEX, out)
        self.assertIn('降到 2', out)

    def test_decrease_to_zero_asks_to_delete_entry(self):
        code, out = self.check(self.tree(page("Text('a')")), {HEX: {self.F: 1}})
        self.assertEqual(code, 1, out)
        self.assertIn(self.F, out)
        self.assertIn('删除', out)

    def test_baseline_file_missing_from_tree_fails(self):
        gone = 'features/home/src/main/ets/Gone.ets'
        code, out = self.check(self.tree(), {HEX: {self.F: 2, gone: 1}})
        self.assertEqual(code, 1, out)
        self.assertIn(gone, out)
        self.assertIn('不存在', out)

    def test_new_file_outside_baseline_fails(self):
        root = self.tree()
        write(root / 'entry/src/main/ets/New.ets', page("Text('a').fontSize(13)"))
        code, out = self.check(root, {HEX: {self.F: 2}})
        self.assertEqual(code, 1, out)
        self.assertRegex(out, re.escape('entry/src/main/ets/New.ets:6:') + r'.*' + re.escape(NUM))

    # v8（D10-901）：test_swap_control_same_total_fails（换控件不换总数也失败）随控件计数撤回删除；反向口径见 SystemControls。

    def test_swap_rule_same_total_fails(self):
        code, out = self.check(self.tree(page("Text('a').fontSize(13)")), {HEX: {self.F: 1}})
        self.assertEqual(code, 1, out)
        self.assertIn(NUM, out)

    def test_injection_of_each_kind_fails(self):
        """§5：注入 '#123456'、.fontSize(13) 各自失败。v8（D10-901）：注入 Button( 不再失败（移到 SystemControls 反向断言）。"""
        for name, line, rule in [('hex', "Text('a').fontColor('#123456')", HEX), ('font', "Text('a').fontSize(13)", NUM)]:
            with self.subTest(inject=name):
                root = self.tree(page("Text('a').fontColor('#FF0000')\nText('b').fontColor('#00FF00')\n" + line))
                code, out = self.check(root, {HEX: {self.F: 2}})
                self.assertEqual(code, 1, out)
                self.assertRegex(out, re.escape(self.F + ':8:') + r'.*' + re.escape(rule))

    def test_default_baseline_path_under_root(self):
        root = self.tree()
        default = root / 'tools/ci/hardcoded-style-baseline.json'
        r = self.run_script('--root', str(root))
        self.assertEqual(r.returncode, 2, '基线文件缺失应以 2 退出\n' + r.stdout + r.stderr)
        write(default, json.dumps({HEX: {self.F: 2}}))
        r = self.run_script('--root', str(root))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_invalid_baseline_exit_2(self):
        root = self.tree()
        for name, text in [('not-json', '{oops'), ('count-not-int', json.dumps({HEX: {self.F: '2'}})),
                           ('not-object', json.dumps([1, 2])), ('unknown-rule', json.dumps({'couli-style/nope': {self.F: 1}}))]:
            with self.subTest(baseline=name):
                b = root / ('b-%s.json' % name)
                b.write_text(text, encoding='utf-8')
                r = self.run_script('--root', str(root), '--baseline', str(b))
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)


class WriteBaseline(Base):
    """§2.1 生成：按 key 排序、indent=2、ensure_ascii=False、末尾换行、无 0 计数、无时间戳；两次逐字节相同。"""
    FILES = {
        'features/me/src/main/ets/页面.ets': page("Text('a').fontColor('#FF0000').padding(8)"),
        'features/home/src/main/ets/B.ets': page("Button('x')\nDivider()\nText('a').fontSize(14)"),
        'entry/src/main/ets/A.ets': page("Row({ space: 2 }) {\n}\nTextInput()"),
        'entry/src/release/ets/Clean.ets': page("Text('a').padding(CouliSpacing.space2)"),
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
        for rule, files in data.items():
            self.assertTrue(rule.startswith('couli-style/'), rule)
            self.assertTrue(files, '空规则不应写出：' + rule)
            for path, count in files.items():
                self.assertIsInstance(count, int)
                self.assertGreater(count, 0)
                self.assertNotIn('\\', path)
                self.assertFalse(os.path.isabs(path), path)
        self.assertNotIn('entry/src/release/ets/Clean.ets', per_file(data))
        # v8（D10-901）：B.ets 的 Button / Divider、A.ets 的 TextInput 不再计，期望只删这三项
        self.assertEqual(per_file(data), {
            'features/me/src/main/ets/页面.ets': {HEX: 1, NUM: 1},
            'features/home/src/main/ets/B.ets': {NUM: 1},
            'entry/src/main/ets/A.ets': {NUM: 1},
        })

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
    """§3-7：解析不完整以 4、工具链缺失以 3（复用 lint 约定）；参数不对以 2；自测。"""

    def test_syntax_error_exit_4(self):
        root = self.tmp()
        write(root / 'features/home/src/main/ets/Broken.ets', 'const s: string = `abc\n')
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
        """v3（评审 r1 S2-1 M4）：范围内的符号链接（文件或目录）不得静默跳过，以 4 失败。"""
        for kind in ('file', 'dir'):
            with self.subTest(kind=kind):
                root = self.tmp()
                write(root / 'features/home/src/main/ets/A.ets', page("Text('a')"))
                outside = root / 'outside'
                write(outside / 'Hidden.ets', page("Text('a').fontColor('#FF0000')"))
                link = root / 'features/home/src/main/ets' / ('Linked.ets' if kind == 'file' else 'linked')
                os.symlink(str(outside / 'Hidden.ets') if kind == 'file' else str(outside), str(link))
                code, out = self.check(root, {})
                self.assertEqual(code, 4, out)
                self.assertIn('features/home/src/main/ets/' + link.name, out)

    def test_symlinked_module_or_scope_root_exit_4(self):
        """v4（评审 r2 S2-1）：features/<模块> 本身、或范围根 src/main 是符号链接时以 4 失败，不得整体静默跳过。"""
        for kind in ('module', 'scope-root'):
            with self.subTest(kind=kind):
                root = self.tmp()
                write(root / 'features/home/src/main/ets/A.ets', page("Text('a')"))
                outside = root / 'outside'
                write(outside / 'src/main/ets/Hidden.ets', page("Text('a').fontColor('#FF0000')"))
                if kind == 'module':
                    link = root / 'features/linked'
                    os.symlink(str(outside), str(link))
                else:
                    link = root / 'features/other/src/main'
                    link.parent.mkdir(parents=True)
                    os.symlink(str(outside / 'src/main'), str(link))
                code, out = self.check(root, {})
                self.assertEqual(code, 4, out)
                self.assertIn(str(link.relative_to(root)), out)

    def test_tokenizer_parser_mismatch_not_silent(self):
        """v3（评审 r1 S2-1 M5）：`i++ / … / 1` 里的除号容易被记号切分当成正则，吞掉其中的 '#FF0000'。实现要么正确切分并报出
        no-hex-color（exit 1），要么在与解析器字符串核对时发现不一致以 4 失败；静默 exit 0 即漏报。"""
        root = self.tmp()
        write(root / 'features/home/src/main/ets/A.ets',
              "let i: number = 0;\nconst n: number = i++ / Number('#FF0000'.length) / 1;\n" + page("Text('a')"))
        code, out = self.check(root, {})
        self.assertIn(code, (1, 4), '记号切分出错时静默放行\n' + out)
        if code == 1:
            self.assertRegex(out, re.escape('features/home/src/main/ets/A.ets:2:') + r'.*' + re.escape(HEX), out)

    def test_non_null_then_division_not_exit_4(self):
        """FU-HM-G1-SYSTEM-CONTROLS 测试 v3（同 lint.py 评审 r1 S2-1）：后缀非空断言 `x!` 后接除号是合法语法，不是正则开头；不得 exit 4，
        写死样式正常判定。两个除号之间是代码，里面的色值照报。前缀取反 `!/re/` 仍是正则（防矫枉过正：正则里的单引号不得被当成字符串开头）。"""
        rel = 'features/home/src/main/ets/A.ets'
        for name, expr in [('member', 'this.x! / 2'), ('element', 'this.a[0]! / 2'), ('call', 'this.f()! / 2')]:
            with self.subTest(form=name):
                root = self.tmp()
                write(root / rel, page("Text(String(%s)).fontColor('#FF0000')\nText('b').fontSize(14)" % expr))
                code, out = self.check(root, {HEX: {rel: 1}, NUM: {rel: 1}})
                self.assertEqual(code, 0, out)
                code, out = self.check(root, {})
                self.assertEqual(code, 1, out)
                self.assertRegex(out, re.escape(rel + ':6:') + r'.*' + re.escape(HEX), out)
                self.assertRegex(out, re.escape(rel + ':7:') + r'.*' + re.escape(NUM), out)
        with self.subTest(form='two-divisions'):
            root = self.tmp()
            write(root / rel, page("Text('a')", top="const B: number = 4;\nconst V: number = B! / Number('#FF0000')! / 2;\n"))
            code, out = self.check(root, {})
            self.assertEqual(code, 1, out)
            self.assertRegex(out, re.escape(rel + ':2:') + r'.*' + re.escape(HEX), out)
        with self.subTest(form='prefix-negation-regex'):
            root = self.tmp()
            write(root / rel, page("Text('a')", top="const S: string = 'x';\nconst OK: boolean = !/a'b/.test(S);\n"
                                                    "function g(s: string): boolean {\n  return !/c'd/.test(s);\n}\n"))
            code, out = self.check(root, {})
            self.assertEqual(code, 0, out)

    def test_toolchain_missing_exit_3(self):
        root = self.tmp()
        write(root / 'features/home/src/main/ets/A.ets', page("Text('a').fontColor('#FF0000')"))
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
        for rule in STYLE_RULES:  # v8（D10-901）：只要求覆盖写死样式三条规则（design-system-required 已撤回）
            self.assertIn(rule, out, '自测输出没有覆盖 ' + rule)


class SystemControls(Base):
    """v8（编排 D10-901，依据 D37 / couli design/ui-rules #295，对齐安卓 D10-830）：系统控件是首选，check_hardcoded_style.py 不再把
    它们当违规。页面里直接用 lint 原 9 项与 Button / Divider / LoadingProgress：不报任何违规、不进基线、exit 0；已与基线持平的页面
    再新增控件调用仍 exit 0（「新增即失败」撤回）。接口约定 §2（v8 改）：基线允许的规则键只剩写死样式三条，
    couli-style/design-system-required 及其 /<控件> 键按「未知规则 key」→ exit 2。"""
    F = 'features/home/src/main/ets/A.ets'
    TWO_HEX = ["Text('a').fontColor('#FF0000')", "Text('b').fontColor('#00FF00')"]
    SCOPES = ['features/home/src/main/ets', 'features/wallet/src/main/ets/mock', 'entry/src/main/ets', 'entry/src/release/ets']

    def test_controls_in_page_scopes_are_not_violations(self):
        root = self.tmp()
        for scope in self.SCOPES:
            write(root / scope / 'Controls.ets', control_page(ALL_CONTROLS))
        code, out = self.check(root, {})
        self.assertEqual(code, 0, '页面直接用系统控件不应失败\n' + out)
        self.assertNotIn('design-system-required', out)
        self.assertNotIn('Controls.ets:', out)
        gen = root / 'gen.json'
        self.write_baseline(root, gen)
        self.assertEqual(gen.read_text(encoding='utf-8'), '{}\n', '只有系统控件的树，生成的基线应是空对象')

    def test_write_baseline_keeps_only_style_rules(self):
        root = self.tmp()
        write(root / 'features/home/src/main/ets/Controls.ets', control_page(ALL_CONTROLS))
        write(root / 'entry/src/main/ets/Styled.ets',
              control_page(['Button', 'Divider', 'TextInput'],
                           extra=["Button('ok').fontSize(14)", "Text('a').fontColor('#FF0000')", 'LoadingProgress().margin(6)']))
        data = self.write_baseline(root, root / 'gen.json')
        self.assertEqual(data, {HEX: {'entry/src/main/ets/Styled.ets': 1}, NUM: {'entry/src/main/ets/Styled.ets': 2}})

    def test_adding_controls_to_baselined_page_passes(self):
        root = self.tmp()
        base = {HEX: {self.F: 2}}
        write(root / self.F, control_page([], extra=self.TWO_HEX))
        code, out = self.check(root, base)
        self.assertEqual(code, 0, '对照：注入前计数与基线持平\n' + out)
        for control in ALL_CONTROLS:
            with self.subTest(inject=control):
                write(root / self.F, control_page([control], extra=self.TWO_HEX))
                code, out = self.check(root, base)
                self.assertEqual(code, 0, '新增 %s 调用不应失败\n%s' % (control, out))
                self.assertNotIn('design-system-required', out)

    def test_style_rule_keys_accepted(self):
        """基线里写死样式三条规则的键照收：各一处命中、各计 1 → exit 0。"""
        root = self.tmp()
        write(root / self.F, page("Text('a').fontColor('#FF0000')\nText('b').fontSize(14)\n"
                                  + DISABLE + "couli-style/no-hex-color\nText('c')"))
        code, out = self.check(root, {HEX: {self.F: 1}, NUM: {self.F: 1}, EXR: {self.F: 1}})
        self.assertEqual(code, 0, out)

    def test_control_rule_keys_rejected(self):
        """基线里出现 couli-style/design-system-required 或其 /<控件> 键 = 未知规则 → exit 2（页面里该控件恰有 1 处调用）。"""
        for control in ALL_CONTROLS + [None]:
            key = DSR + control if control else DSR.rstrip('/')
            with self.subTest(key=key):
                root = self.tmp()
                write(root / self.F, control_page([control] if control else [], extra=self.TWO_HEX[:1]))
                code, out = self.check(root, {HEX: {self.F: 1}, key: {self.F: 1}})
                self.assertEqual(code, 2, '基线含已撤回的规则键 %s 应以 2 退出\n%s' % (key, out))


class LintWarnings(Base):
    """§2.3 / D10-734 ⑤：lint.py G1 只警告（exit 0），不改 ds02/test_host.py。
    v8（D10-901 ①③，取代 D10-734 ⑦ 的补名单）：G1 名单回到 a819d7a 原 9 项、仍只警告；Button / Divider / LoadingProgress 不再警告；
    三个补充样例删除，ds02-warning/README.md 回到 a819d7a 原文（DS-02 指纹原值）；文件头 [design-system-required] 文案回到原文。"""

    def run_lint(self, root):
        r = subprocess.run([sys.executable, str(LINT), '--root', str(root)], capture_output=True, text=True, timeout=900)
        return r.returncode, r.stdout + r.stderr

    def test_g1_list_replaced_by_whitelist(self):
        """FU-HM-G1-SYSTEM-CONTROLS（D10-951 ③ #24）：G1 不再是 9 类判定名单，改成 lint.SYSTEM_CONTROLS 白名单（新判据由
        tools/ci/system-controls/test_system_controls.py 接管），原 9 项都在白名单里。"""
        cur = load_module(LINT, 'couli_lint_style_probe')
        self.assertFalse(hasattr(cur, 'DESIGN_SYSTEM_REQUIRED'), 'DESIGN_SYSTEM_REQUIRED 应已由 SYSTEM_CONTROLS 取代')
        self.assertEqual(sorted(set(ORIGINAL_CONTROLS) - set(cur.SYSTEM_CONTROLS)), [])

    def test_original_nine_no_longer_warn(self):
        """FU-HM-G1-SYSTEM-CONTROLS（#24）：原 9 个样例放进 features / entry：lint.py exit 0，不再报任何 G1 警告（系统控件是 D37 首选）。"""
        root = self.tmp()
        scopes = ['features/auth/src/main/ets', 'entry/src/main/ets']
        for scope in scopes:
            for control in ORIGINAL_CONTROLS:
                write(root / scope / control / 'Violation.ets', (DS02_WARNING / (control + '.ets')).read_text(encoding='utf-8'))
        code, out = self.run_lint(root)
        self.assertEqual(code, 0, out)
        self.assertNotIn('[design-system-required]', out)
        self.assertNotIn('[couli-g1/', out)

    def test_withdrawn_controls_do_not_warn(self):
        """D10-901 ①：Button / Divider / LoadingProgress 不在 G1 名单——页面直接用不警告、exit 0。
        取代 v1 的 test_new_controls_warn_without_failing。"""
        sources = {'Button': page("Button('ok')\nButton({ type: ButtonType.Capsule }) {\n  Text('b')\n}"),
                   'Divider': page('Divider()\nDivider().strokeWidth(1)'),
                   'LoadingProgress': page('LoadingProgress()\nLoadingProgress().width(24)')}
        root = self.tmp()
        scopes = ['features/auth/src/main/ets', 'entry/src/main/ets']
        for scope in scopes:
            for control in WITHDRAWN_CONTROLS:
                write(root / scope / control / 'Page.ets', sources[control])
        code, out = self.run_lint(root)
        self.assertEqual(code, 0, out)
        for scope in scopes:
            for control in WITHDRAWN_CONTROLS:
                with self.subTest(scope=scope, control=control):
                    rel = '%s/%s/Page.ets:' % (scope, control)
                    self.assertEqual([l for l in out.splitlines() if l.startswith(rel) and '[design-system-required]' in l], [], out)
        self.assertNotIn('[design-system-required]', out)

    def test_prefixed_names_do_not_warn(self):
        root = self.tmp()
        write(root / 'entry/src/main/ets/Legal.ets',
              page("CouliButton({ text: 'ok' })\nMyDivider()\nthis.kit.LoadingProgress()\n// Button()\nText('Divider()')"))
        r = subprocess.run([sys.executable, str(LINT), '--root', str(root)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn('[design-system-required]', r.stdout + r.stderr)

    def test_lint_header_g1_section_new_wording(self):
        """FU-HM-G1-SYSTEM-CONTROLS（#24）：文件头不再有 [design-system-required] 段，改写四条新规则口径；HM-LINT-11 文案不动。"""
        head = LINT.read_text(encoding='utf-8').split('"""', 2)[1]
        self.assertNotIn('[design-system-required]', head)
        for rule in ('couli-g1/self-drawn-control', 'couli-g1/click-without-feedback', 'couli-g1/edge-effect-none', 'couli-g1/hide-title-bar'):
            self.assertIn(rule, head)
        self.assertIn('HM-LINT-11 theme-drift', head)

    def test_frozen_files_unchanged(self):
        frozen = ['tools/ci/lint-fixtures/ds02-warning/%s.ets' % c for c in ORIGINAL_CONTROLS]  # D10-951 ③：test_host.py 按 #24 反向，不再冻结
        for rel in frozen:
            with self.subTest(frozen=rel):
                old = subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (BASE_COMMIT, rel)], capture_output=True)
                self.assertEqual(old.returncode, 0, old.stderr.decode('utf-8', 'replace'))
                self.assertEqual((ROOT / rel).read_bytes(), old.stdout, rel + ' 被改动（冻结文件）')

    def test_withdrawn_samples_removed(self):
        """D10-901 ③：ds02-warning/ 下不再有 Button / Divider / LoadingProgress 三个样例，.ets 样例恰为 a819d7a 的 9 个。"""
        for control in WITHDRAWN_CONTROLS:
            with self.subTest(sample=control):
                self.assertFalse((DS02_WARNING / (control + '.ets')).exists(), '撤回的样例仍在：%s.ets' % control)
        listed = subprocess.run(['git', '-C', str(ROOT), 'ls-tree', '--name-only', BASE_COMMIT, 'tools/ci/lint-fixtures/ds02-warning/'],
                                capture_output=True, text=True)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        base = sorted(Path(p).name for p in listed.stdout.splitlines() if p.endswith('.ets'))
        self.assertEqual(base, sorted(c + '.ets' for c in ORIGINAL_CONTROLS), '底版样例自检')
        self.assertEqual(sorted(p.name for p in DS02_WARNING.iterdir() if p.name.endswith('.ets')), base)

    def test_ds02_readme_rewritten(self):
        """FU-HM-G1-SYSTEM-CONTROLS（#24）：README 改写成「原九类，D37 下作合法样例」，sha 改钉新值（落地时按新 README 算）。"""
        rel = 'tools/ci/lint-fixtures/ds02-warning/README.md'
        raw = (ROOT / rel).read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), DS02_README_SHA256, rel + ' 与钉住的新 sha 不一致')
        self.assertIn('D37', raw.decode('utf-8'))


class VerifyStep(Base):
    """§2.2：verify.sh 只新增一步；现有行全部原样保留、顺序不变。"""

    def lines(self):
        old = subprocess.run(['git', '-C', str(ROOT), 'show', BASE_COMMIT + ':tools/ci/verify.sh'], capture_output=True)
        self.assertEqual(old.returncode, 0, old.stderr.decode('utf-8', 'replace'))
        return old.stdout.decode('utf-8').splitlines(), (ROOT / 'tools/ci/verify.sh').read_text(encoding='utf-8').splitlines()

    def test_existing_lines_kept_in_order(self):
        old, new = self.lines()
        i = 0
        for line in new:
            if i < len(old) and line == old[i]:
                i += 1
        self.assertEqual(i, len(old), 'verify.sh 现有行被删改或换序，第一处缺失：%r' % (old[i] if i < len(old) else None))

    def test_new_step_present_after_ds02_host(self):
        old, new = self.lines()
        added = [l for l in new if l not in set(old)]
        self_test = [k for k, l in enumerate(new)
                     if 'tools/ci/check_hardcoded_style.py" --self-test' in l and 'fail_fast' in l]
        check = [k for k, l in enumerate(new)
                 if re.search(r'tools/ci/check_hardcoded_style\.py"\s*\|\|\s*fail_fast', l)]
        self.assertEqual(len(self_test), 1, '缺「--self-test || fail_fast」一行')
        self.assertEqual(len(check), 1, '缺「查本仓库 || fail_fast」一行')
        ds02 = new.index('record "ds02-host" PASS')
        self.assertGreater(self_test[0], ds02)
        self.assertGreater(check[0], self_test[0])
        self.assertTrue(any(l.startswith('step ') for l in added), '新增内容应是独立的一步（step）')
        # FU-HM-G1-SYSTEM-CONTROLS（#24）：verify.sh 之后又加了 G1 一步，白名单只查 LINT-STYLE 这一步的行块，不再要求全局新增行都满足。
        start = new.index('step "LINT-STYLE 写死样式基线"')
        end = new.index('record "lint-style" PASS "写死样式基线"')
        block = new[start:end + 1]
        self.assertTrue(all('hardcoded' in l or 'LINT-STYLE' in l or 'lint-style' in l or l.startswith('#') or not l.strip()
                            for l in block), 'LINT-STYLE 一步里混进了其他内容：%r' % block)

    def test_new_step_wording_has_no_system_controls(self):
        """v8（D10-901）：本步只查写死样式——新增的注释、step 名与 record 说明不再提系统控件（「控件」/ design-system）。"""
        _, new = self.lines()
        # FU-HM-G1-SYSTEM-CONTROLS（#24，书 §3.2 未列）：G1 一步名字里就有「控件」；本条只管 LINT-STYLE 那一步的行块。
        start = new.index('step "LINT-STYLE 写死样式基线"')
        end = new.index('record "lint-style" PASS "写死样式基线"')
        added = new[start:end + 1]
        self.assertTrue(added, 'verify.sh 缺本单新增的一步')
        self.assertEqual([l for l in added if '控件' in l or 'design-system' in l], [],
                         'verify.sh 本步的说明文字仍提系统控件（D10-901 已撤回控件计数）')


class LintScanScope(Base):
    """v6（编排 D10-788）：lint.py HM-LINT-1…9 的扫描范围（SCAN_DIRS = entry / common / features）里，**源码集内**（<模块>/src/<集>/**，
    集 = main / staging / release 等会进制品的源码树）不再套 SKIP_DIRS——名为 mock / build / oh_modules / node_modules / .hvigor /
    .preview / .test / ohosTest 的子目录照扫，与 HM-LINT-10（FU-HM-0718：范围内不套 SKIP_DIRS）同口径。
    保持现状：测试源码集 src/ohosTest、src/mock（Hypium 本地测试 mock 源码集，如 common/core/src/mock）整体不扫；src/test 现状照扫。
    模块根下的生成 / 依赖目录（<模块>/build、oh_modules、node_modules、.hvigor、.preview、.test）不是源码集，继续跳过：
    HM-LINT-10 的范围本身就是一个源码集（entry/src/staging），它的「不套 SKIP_DIRS」只针对源码集内部；模块根下这些目录是
    hvigor / ohpm 产出的编译中间物与三方依赖，不是本仓库手写源码，扫它们只会把三方库的写法误报成违反。"""
    PRIVACY = "import { MobPush } from 'mobpush';\nexport function boot(ctx: object): void {\n  MobPush.init(ctx);\n}\n"
    V1 = "@Component\nexport struct OldView {\n  @State n: number = 0;\n  build() {}\n}\n"
    INCLUDED_DIRS = [
        'features/home/src/main/ets/mock', 'features/home/src/main/ets/build', 'entry/src/main/ets/oh_modules',
        'entry/src/main/ets/.hvigor', 'entry/src/release/ets/.preview', 'common/core/src/main/ets/node_modules',
        'features/me/src/main/ets/.test', 'features/me/src/main/ets/ohosTest', 'entry/src/staging/ets/mock',
        'entry/src/staging/ets/build', 'common/core/src/release/ets/mock', 'common/core/src/staging/ets/build',
        # 现状已扫，钉住不回退
        'features/home/src/main/ets/plain', 'features/home/src/test',
        # v7（评审 r4 S2-1）：集内多层嵌套、集内名为 src 的子目录、嵌套模块的源码集
        'features/home/src/main/ets/mock/build/oh_modules', 'features/home/src/main/ets/src/ohosTest',
        'features/home/sub/src/main/ets/mock',
    ]
    EXCLUDED_DIRS = [
        # 测试源码集（保持现状）
        'features/home/src/ohosTest/ets/test', 'entry/src/ohosTest/ets/test', 'common/core/src/mock',
        # 模块根下的生成 / 依赖目录（非源码集）
        'features/home/build/default/intermediates/ets', 'features/home/oh_modules/lib', 'features/home/node_modules/lib',
        'entry/.hvigor/cache', 'entry/.preview/ets', 'common/core/.test/ets', 'entry/build/default/ets',
    ]

    def run_lint(self, root):
        r = subprocess.run([sys.executable, str(LINT), '--root', str(root)], capture_output=True, text=True, timeout=900)
        return r.returncode, r.stdout + r.stderr

    def test_skip_dirs_inside_source_sets_are_scanned(self):
        root = self.tmp()
        for d in self.INCLUDED_DIRS + self.EXCLUDED_DIRS:
            write(root / d / 'PushBoot.ets', self.PRIVACY)
            write(root / d / 'OldView.ets', self.V1)
        code, out = self.run_lint(root)
        self.assertEqual(code, 1, out)
        for d in self.INCLUDED_DIRS:
            with self.subTest(included=d):
                self.assertRegex(out, re.escape(d + '/PushBoot.ets:3:') + r'.*HM-LINT-4', '隐私类规则漏扫 ' + d + '\n' + out)
                self.assertRegex(out, re.escape(d + '/OldView.ets:1:') + r'.*HM-LINT-2', '普通规则漏扫 ' + d + '\n' + out)
        for d in self.EXCLUDED_DIRS:
            with self.subTest(excluded=d):
                self.assertNotIn(d + '/', out)

    def test_real_tree_lint_still_clean(self):
        code, out = self.run_lint_real()
        self.assertEqual(code, 0, out)
        self.assertIn('lint.py：0 处违反', out)

    def run_lint_real(self):
        r = subprocess.run([sys.executable, str(LINT)], capture_output=True, text=True, timeout=900)
        return r.returncode, r.stdout + r.stderr


class RealTree(Base):
    """实现与正式基线落地后才能绿：真实工作树按正式基线 exit 0，正式基线 == 生成结果。"""

    def test_real_baseline_exists_and_repo_passes(self):
        self.assertTrue(REAL_BASELINE.is_file(), '缺正式基线 ' + str(REAL_BASELINE))
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_real_baseline_equals_generated(self):
        self.assertTrue(REAL_BASELINE.is_file(), '缺正式基线 ' + str(REAL_BASELINE))
        out = self.tmp() / 'gen.json'
        r = self.run_script('--baseline', str(out), '--write-baseline')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(out.read_bytes(), REAL_BASELINE.read_bytes(), '正式基线与 --write-baseline 生成结果不一致')
        data = json.loads(REAL_BASELINE.read_text(encoding='utf-8'))
        scope = re.compile(r'^(features/[^/]+/src/main/|entry/src/main/|entry/src/release/)')
        for path in per_file(data):
            with self.subTest(path=path):
                self.assertRegex(path, scope)
                self.assertTrue((ROOT / path).is_file(), path)
        self.assertIn('features/web/src/main/ets/TrustedWebView.ets', data.get(HEX, {}))
        # 与调研估计对照（不作硬断言）：写死样式 69（D10-901 撤回控件计数后应不变）；控件计数应为 0（撤回前 38 + 78）。
        style = sum(sum(data.get(r, {}).values()) for r in (HEX, NUM))
        controls = sum(sum(files.values()) for rule, files in data.items() if rule.startswith(DSR))
        print('\n[LINT-STYLE 现状] 写死样式 %d（估 69）、系统控件 %d（D10-901 撤回，应 0）' % (style, controls))
        # v8（D10-901）：正式基线只许写死样式三条规则的键，不得再有 couli-style/design-system-required/<控件>
        self.assertEqual(sorted(set(data) - set(STYLE_RULES)), [], '正式基线里还有已撤回的规则键')


if __name__ == '__main__':
    unittest.main(verbosity=2)
