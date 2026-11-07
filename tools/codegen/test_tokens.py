#!/usr/bin/env python3
"""TOKENS-PIPE-harmony 测试作者 v1：令牌生成器单测（brief-harmony §4-1、§4-5；D10-693：8 位色只认 #RRGGBBAA）。

被测：tools/codegen/gen.py（gen_tokens / build_outputs / check）、tools/codegen/gen_theme.py（build_outputs / check）、
tools/codegen/ds02_test_data.py（build_test_outputs）、tools/ci/lint.py（HM-LINT-11）。只用标准库 + node（执行生成的 ArkTS 数据文件，
见 tools/ci/tokens/eval-tokens.cjs；不靠正则猜生成物写法）。

对实现的接口约定（测试只依赖这些）：
  - 生成器读令牌的唯一位置是「仓库根 / contracts/snapshot/design/design-tokens.json」；仓库根取模块变量 ROOT（gen 另有 SNAPSHOT =
    ROOT/contracts/snapshot）。测试把 ROOT / SNAPSHOT 指到临时目录放最小夹具；另在临时目录的两处旧副本位置放「毒化」令牌，
    读了副本就会算出别的值。
  - gen.gen_tokens() 返回 DesignTokens.ets 全文；有 colorsDark / shadowsDark 两个静态字段。
  - gen_theme.build_outputs() 返回 {相对路径: 全文}，含 designsystem base / dark color.json、entry base / dark color.json、
    CouliThemeTokens.ets（§6-5：entry base 由生成器出）。
  - ds02_test_data.build_test_outputs(root) 返回两份 Ds02Expected.ets。
  - gen.build_outputs() 纳入 gen_theme 的全部产物（§6-1 A：gen.py --check 一次覆盖全部令牌生成物）。
钉值 0.5.1 只在 RealRepo 段用（DSX-122 升 v0.6.0 时换值）。

用法：python3 tools/codegen/test_tokens.py（verify.sh 在 gen.py --check 之后跑）。HM-LINT-11 一组要在临时副本里跑 4 次整份 lint.py
（约 1–2 分钟）。
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / 'tools/ci/tokens'))

import gen  # noqa: E402
import gen_theme  # noqa: E402
import ds02_test_data  # noqa: E402
from check_tokens_pipe import argb, eval_class, leaves, resource_name  # noqa: E402

SNAP_REL = 'contracts/snapshot/design/design-tokens.json'
DS_BASE = 'common/designsystem/src/main/resources/base/element/color.json'
DS_DARK = 'common/designsystem/src/main/resources/dark/element/color.json'
ENTRY_BASE = 'entry/src/main/resources/base/element/color.json'
ENTRY_DARK = 'entry/src/main/resources/dark/element/color.json'
THEME_ETS = 'common/designsystem/src/main/ets/theme/CouliThemeTokens.ets'
DESIGN_ETS = 'common/generated/src/main/ets/DesignTokens.ets'
POISON_PATHS = ['specs/design-tokens.v0.4.0.json', 'tools/ci/ds02/fixtures/design-tokens.v0.4.0.json']
# 钉值：DSX-122 升 v0.6.0 时换值。
PINNED_VERSION = '0.5.1'
PINNED_SHA256 = '97d2bf83ada062959987f348bc695c63fabc4adb3647f03e5c0895e2548e491c'


def c(value, dark=None):
    leaf = {'type': 'color', 'value': value}
    if dark is not None:
        leaf['dark'] = dark
    return leaf


def d(value, kind='dimension'):
    return {'type': kind, 'value': value}


def fixture(version='9.8.7'):
    """最小令牌夹具：含 8 位色（浅深不同）、深浅同值的 8 位色、两套阴影、none、1.5。"""
    return {
        'metadata': {'name': '夹具', 'version': version, 'modes': ['light', 'dark'], 'darkThemePhase': 'MVP'},
        'tokens': {
            'color': {
                'text': {'primary': c('#28251F', '#F2EEE6')},
                'background': {'canvas': c('#F2EEE6', '#171513')},
                'brand': {'primary': c('#C44820', '#C44820')},
                'status': {'error': {'text': c('#B42345', '#F28DA4')}},
                'overlay': {'scrim': c('#28251F66', '#0000008C'), 'on-image': c('#0000008C', '#0000008C')},
            },
            'font': {'size': {'body': d(17, 'fontSize')}, 'line-height': {'body': d(25.5, 'lineHeight')},
                     'weight': {'bold': d(700, 'fontWeight')}},
            'space': {'0': d(0), '4': d(16)},
            'radius': {'tag': d(4), 'avatar': d(10), 'card': d(16)},
            'shadow': {
                'none': {'type': 'shadow', 'value': []},
                'card': {'type': 'shadow', 'value': [{'x': 0, 'y': 2, 'blur': 8, 'spread': 0, 'color': '#28251F', 'opacity': 0.06}],
                         'dark': [{'x': 0, 'y': 2, 'blur': 8, 'spread': 0, 'color': '#000000', 'opacity': 0.3}]},
                'floating': {'type': 'shadow', 'value': [{'x': 0, 'y': 8, 'blur': 24, 'spread': 0, 'color': '#28251F', 'opacity': 0.12}],
                             'dark': [{'x': 0, 'y': 8, 'blur': 24, 'spread': 0, 'color': '#000000', 'opacity': 0.45}]},
            },
            'focus': {'width': d(2), 'offset': d(2)},
            'interaction': {'target': {'harmony': d(48)}},
            'component': {'checkbox': {'size': d(18), 'max-scale': d(1.5, 'number')}, 'button': {'min-height': d(48)}},
        },
    }


def poison():
    """旧副本位置放的毒化令牌：版本 0.4.0，颜色全不同。读到它就说明还在读副本。"""
    data = fixture('0.4.0')
    for _key, leaf in leaves(data['tokens']['color']):
        leaf['value'] = '#010203'
        leaf['dark'] = '#040506'
    return data


def as_map(pairs):
    return dict(pairs)


class FixtureRoot:
    """临时仓库根：快照 + 两处毒化副本 + ds02 inventory；把 gen / gen_theme 的 ROOT、SNAPSHOT 指过去。"""

    def __init__(self, data, poisoned=True):
        self.tmp = tempfile.mkdtemp(prefix='tokens-unit-')
        self.root = Path(self.tmp)
        self.raw = json.dumps(data, ensure_ascii=False, indent=2).encode('utf-8')
        self.write(SNAP_REL, self.raw)
        if poisoned:
            for rel in POISON_PATHS:
                self.write(rel, json.dumps(poison(), ensure_ascii=False).encode('utf-8'))
        inv = ROOT / 'tools/ci/ds02/fixtures/inventory.tsv'
        self.write('tools/ci/ds02/fixtures/inventory.tsv', inv.read_bytes())
        self.saved = []

    def write(self, rel, data):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

    def __enter__(self):
        for mod, name, value in ((gen, 'ROOT', self.tmp), (gen, 'SNAPSHOT', os.path.join(self.tmp, 'contracts', 'snapshot')),
                                 (gen_theme, 'ROOT', self.tmp)):
            self.saved.append((mod, name, getattr(mod, name)))
            setattr(mod, name, value)
        return self

    def __exit__(self, *exc):
        for mod, name, value in reversed(self.saved):
            setattr(mod, name, value)
        shutil.rmtree(self.tmp, ignore_errors=True)


def evaluate(text, cls):
    with tempfile.TemporaryDirectory(prefix='tokens-eval-') as tmp:
        p = Path(tmp) / (cls + '.ets')
        p.write_text(text, encoding='utf-8')
        return eval_class(p, cls)


def design_tokens(data):
    with FixtureRoot(data):
        return evaluate(gen.gen_tokens(), 'DesignTokens')


def theme_outputs(data):
    with FixtureRoot(data):
        return {k.replace(os.sep, '/'): v for k, v in gen_theme.build_outputs().items()}


def color_rows(text):
    rows = json.loads(text)['color']
    return {r['name']: r['value'] for r in rows}


def layers(rows):
    return [tuple(layer[f] for f in ('x', 'y', 'blur', 'spread', 'color', 'opacity')) for layer in rows]


class GeneratorUnit(unittest.TestCase):
    # ---- gen.py：颜色写法
    def test_gen_accepts_rrggbbaa_and_keeps_css_string(self):
        tokens = design_tokens(fixture())
        colors = as_map(tokens['colors'])
        self.assertEqual(colors['overlay.scrim'], '#28251F66', 'DesignTokens 保留 CSS #RRGGBBAA 原串（不换位）')
        self.assertEqual(colors['overlay.on-image'], '#0000008C')

    def test_gen_rejects_every_other_color_form(self):
        for field in ('value', 'dark'):
            for bad in ('#12345', '#1234567', '#123456789', '#FFF', '#ABCD', '#GG0000', '#28251F6G', '28251F', 'red',
                        'rgba(40, 37, 31, 0.4)', '#28 251F', '', 7):
                data = fixture()
                data['tokens']['color']['overlay']['scrim'][field] = bad
                with FixtureRoot(data):
                    with self.assertRaises(gen.GenError, msg='%s=%r 必须拒绝（只认 #RRGGBB / #RRGGBBAA）' % (field, bad)):
                        gen.gen_tokens()

    def test_gen_keeps_lowercase_css_untouched(self):
        data = fixture()
        data['tokens']['color']['overlay']['scrim'] = c('#28251f66', '#0000008c')
        tokens = design_tokens(data)
        self.assertEqual(as_map(tokens['colors'])['overlay.scrim'], '#28251f66')
        self.assertEqual(as_map(tokens['colorsDark'])['overlay.scrim'], '#0000008c')
        out = theme_outputs(data)
        self.assertEqual(color_rows(out[DS_BASE])['color_overlay_scrim'], '#6628251F')
        self.assertEqual(color_rows(out[DS_DARK])['color_overlay_scrim'], '#8C000000')

    # ---- gen.py：colorsDark
    def test_colors_dark_same_keys_and_dark_raw_values(self):
        data = fixture()
        tokens = design_tokens(data)
        self.assertIn('colorsDark', tokens, 'DesignTokens 须有 colorsDark（§6-2）')
        light, dark = tokens['colors'], tokens['colorsDark']
        self.assertEqual(sorted(k for k, _ in dark), sorted(k for k, _ in light), 'colorsDark 键集合 = colors')
        self.assertEqual(len(dark), len(light))
        want = {k: leaf['dark'] for k, leaf in leaves(data['tokens']['color'])}
        self.assertEqual(as_map(dark), want)
        self.assertEqual(as_map(dark)['text.primary'], '#F2EEE6')
        self.assertEqual(as_map(dark)['overlay.scrim'], '#0000008C')

    def test_missing_dark_is_generror_never_falls_back_to_light(self):
        data = fixture()
        del data['tokens']['color']['status']['error']['text']['dark']
        with FixtureRoot(data):
            with self.assertRaises(gen.GenError, msg='gen.py 缺 dark 必须报错，不回落浅色'):
                gen.gen_tokens()
            with self.assertRaises(gen_theme.GenError, msg='gen_theme 缺 dark 必须报错'):
                gen_theme.build_outputs()

    # ---- gen.py：shadowsDark
    def test_shadows_dark_keys_layers_and_none(self):
        data = fixture()
        tokens = design_tokens(data)
        self.assertIn('shadowsDark', tokens, 'DesignTokens 须有 shadowsDark（§6-2）')
        light, dark = as_map(tokens['shadows']), as_map(tokens['shadowsDark'])
        self.assertEqual(sorted(dark), sorted(light), 'shadowsDark 键集合 = shadows')
        self.assertEqual(dark['none'], [], 'none 取自己的 value（空数组）')
        for key in ('card', 'floating'):
            self.assertEqual(layers(light[key]), layers(data['tokens']['shadow'][key]['value']))
            self.assertEqual(layers(dark[key]), layers(data['tokens']['shadow'][key]['dark']), 'shadowsDark 取 dark，不取浅色')
        self.assertEqual(layers(dark['card']), [(0, 2, 8, 0, '#000000', 0.3)])

    def test_shadow_with_layers_but_no_dark_is_generror(self):
        data = fixture()
        del data['tokens']['shadow']['floating']['dark']
        with FixtureRoot(data):
            with self.assertRaises(gen.GenError, msg='value 非空却缺 dark 必须报错'):
                gen.gen_tokens()

    # ---- gen.py：component / 其他段
    def test_component_fraction_is_not_truncated(self):
        tokens = design_tokens(fixture())
        comp = as_map(tokens['component'])
        self.assertEqual(comp['checkbox.max-scale'], 1.5)
        self.assertIsInstance(comp['checkbox.max-scale'], float)
        self.assertEqual(comp['checkbox.size'], 18)
        self.assertEqual(sorted(comp), ['button.min-height', 'checkbox.max-scale', 'checkbox.size'])
        self.assertEqual(as_map(tokens['lineHeight'])['body'], 25.5)
        self.assertEqual(as_map(tokens['radius']), {'tag': 4, 'avatar': 10, 'card': 16})

    def test_version_comes_from_metadata_not_pinned(self):
        for version in ('9.8.7', '0.4.0', '0.6.0'):
            data = fixture(version)
            self.assertEqual(design_tokens(data)['version'], version)
            out = theme_outputs(data)
            self.assertEqual(evaluate(out[THEME_ETS], 'CouliThemeTokens')['version'], version,
                             'gen_theme 不钉版本，从快照 metadata 读')

    # ---- gen_theme.py：来源、换位、产物
    def test_theme_reads_snapshot_not_specs_copy(self):
        data = fixture()
        out = theme_outputs(data)
        base = color_rows(out[DS_BASE])
        self.assertEqual(base['color_text_primary'], '#28251F', '读到了旧副本（毒化值 #010203）')
        self.assertNotIn('#010203', out[THEME_ETS])
        self.assertNotIn('#040506', out[DS_DARK])

    def test_theme_resources_swap_css_to_argb_exactly_once(self):
        data = fixture()
        out = theme_outputs(data)
        base, dark = color_rows(out[DS_BASE]), color_rows(out[DS_DARK])
        want_names = {resource_name(k) for k, _ in leaves(data['tokens']['color'])}
        self.assertEqual({k for k in base if k.startswith('color_')}, want_names)
        self.assertEqual({k for k in dark if k.startswith('color_')}, want_names)
        for key, leaf in leaves(data['tokens']['color']):
            self.assertEqual(base[resource_name(key)], argb(leaf['value']), key)
            self.assertEqual(dark[resource_name(key)], argb(leaf['dark']), key)
        self.assertEqual(base['color_overlay_scrim'], '#6628251F')
        self.assertEqual(dark['color_overlay_scrim'], '#8C000000')
        self.assertEqual(base['color_overlay_on_image'], '#8C000000')
        self.assertEqual(dark['color_overlay_on_image'], '#8C000000')
        self.assertEqual((base['shadow_card'], dark['shadow_card']), ('#0F28251F', '#4C000000'))
        self.assertEqual((base['shadow_floating'], dark['shadow_floating']), ('#1F28251F', '#73000000'))
        theme = evaluate(out[THEME_ETS], 'CouliThemeTokens')
        rows = {r['key']: r for r in theme['colors']}
        self.assertEqual((rows['overlay.scrim']['light'], rows['overlay.scrim']['dark']), ('#6628251F', '#8C000000'))
        self.assertEqual((rows['overlay.on-image']['light'], rows['overlay.on-image']['dark']), ('#8C000000', '#8C000000'))

    def test_entry_start_window_background_both_modes_generated(self):
        out = theme_outputs(fixture())
        self.assertIn(ENTRY_BASE, out, 'entry base 的 start_window_background 由生成器输出（§6-5）')
        self.assertEqual(color_rows(out[ENTRY_BASE]), {'start_window_background': '#F2EEE6'})
        self.assertEqual(color_rows(out[ENTRY_DARK]), {'start_window_background': '#171513'})
        data = fixture()
        data['tokens']['color']['background']['canvas'] = c('#F3EFE7', '#181614')
        out = theme_outputs(data)
        self.assertEqual(color_rows(out[ENTRY_BASE]), {'start_window_background': '#F3EFE7'}, '跟着令牌走，不是写死')
        self.assertEqual(color_rows(out[ENTRY_DARK]), {'start_window_background': '#181614'})

    def test_theme_tokens_has_no_component_table(self):
        theme = evaluate(theme_outputs(fixture())[THEME_ETS], 'CouliThemeTokens')
        self.assertNotIn('component', theme, '组件尺寸只留 DesignTokens.component 一份（§6-3 A）')

    def test_theme_header_no_longer_mentions_copy(self):
        text = theme_outputs(fixture())[THEME_ETS]
        head = '\n'.join(text.split('\n')[:3])
        for needle in ('specs/', 'design-tokens.v', 'v0.4.0', '仍锁'):
            self.assertNotIn(needle, head)
        self.assertIn('contracts/snapshot/design/design-tokens.json', head)

    def test_design_and_theme_tokens_are_one_chain(self):
        data = fixture()
        with FixtureRoot(data):
            design = evaluate(gen.gen_tokens(), 'DesignTokens')
            outputs = {k.replace(os.sep, '/'): v for k, v in gen_theme.build_outputs().items()}
        theme = evaluate(outputs[THEME_ETS], 'CouliThemeTokens')
        assert_one_chain(self, design, theme)

    # ---- ds02_test_data.py
    def test_ds02_expected_derives_from_snapshot(self):
        data = fixture()
        with FixtureRoot(data) as fx:
            outputs = ds02_test_data.build_test_outputs(fx.tmp)
            sha = hashlib.sha256(fx.raw).hexdigest()
        self.assertEqual(sorted(outputs), ['common/designsystem/src/test/Ds02Expected.ets', 'entry/src/ohosTest/ets/test/Ds02Expected.ets'])
        for text in outputs.values():
            head = '\n'.join(text.split('\n')[:3])
            self.assertIn(sha, head, 'Ds02Expected 头注写快照 sha256')
            self.assertNotIn('v0.4.0', head)
            self.assertNotIn('#010203', text, '读到了 ds02 夹具副本（毒化值）')
            self.assertIn('new ExpectedColor("overlay.scrim", "#6628251F", "#8C000000")', text)
            self.assertIn('new ExpectedColor("overlay.on-image", "#8C000000", "#8C000000")', text)
            self.assertEqual(text.count('new ExpectedColor('), len(list(leaves(data['tokens']['color']))))


def assert_one_chain(case, design, theme):
    """DesignTokens（CSS 原串）与 CouliThemeTokens（ARGB 派生）同源：逐键 argb 相等、版本相等、阴影两套相等。"""
    case.assertEqual(design['version'], theme['version'])
    rows = {r['key']: r for r in theme['colors']}
    light, dark = as_map(design['colors']), as_map(design['colorsDark'])
    case.assertEqual(sorted(rows), sorted(light))
    for key, value in light.items():
        case.assertEqual(rows[key]['light'], argb(value), key)
        case.assertEqual(rows[key]['dark'], argb(dark[key]), key)
    shadows = {r['key']: r for r in theme['shadows']}
    sl, sd = as_map(design['shadows']), as_map(design['shadowsDark'])
    case.assertEqual(sorted(shadows), sorted(sl))
    for key in sl:
        case.assertEqual(layers(shadows[key]['light']), layers(sl[key]), key)
        case.assertEqual(layers(shadows[key]['dark']), layers(sd[key]), key)


class RealRepo(unittest.TestCase):
    """本仓库：gen.py 一次覆盖全部令牌生成物（§6-1 A），两条链路合一。"""

    @classmethod
    def setUpClass(cls):
        cls.gen_outputs = {k.replace(os.sep, '/'): v for k, v in gen.build_outputs().items()}
        cls.theme_outputs = {k.replace(os.sep, '/'): v for k, v in gen_theme.build_outputs().items()}

    def test_snapshot_is_locked_v0_5_1(self):
        raw = (ROOT / SNAP_REL).read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), PINNED_SHA256, '快照须是 couli f088f04 原字节（DSX-122 换值）')
        self.assertEqual(json.loads(raw)['metadata']['version'], PINNED_VERSION)

    def test_gen_build_outputs_include_every_theme_output_verbatim(self):
        self.assertEqual(sorted(self.theme_outputs), sorted([DS_BASE, DS_DARK, ENTRY_BASE, ENTRY_DARK, THEME_ETS]))
        for rel, text in self.theme_outputs.items():
            self.assertIn(rel, self.gen_outputs, 'gen.py build_outputs 未纳入 ' + rel)
            self.assertEqual(self.gen_outputs[rel], text, rel)

    def test_gen_check_reports_drift_in_each_theme_output(self):
        outputs = {k.replace(os.sep, '/'): v for k, v in gen.build_outputs().items()}
        original = gen.ROOT
        with tempfile.TemporaryDirectory(prefix='tokens-check-probe-') as tmp:
            gen.write_outputs(tmp, outputs)
            try:
                gen.ROOT = tmp
                self.assertEqual(gen.check(outputs), [])
                for rel in sorted(self.theme_outputs):
                    self.assertIn(rel, outputs, 'gen.py build_outputs 未纳入 ' + rel + '（--check 覆盖不到）')
                    p = Path(tmp) / rel
                    text = p.read_text(encoding='utf-8')
                    p.write_text(text.replace('#', '#0', 1) if '#' in text else text + ' ', encoding='utf-8')
                    self.assertEqual([x.replace(os.sep, '/') for x in gen.check(outputs)], [rel], 'gen.py --check 没覆盖 ' + rel)
                    p.write_text(text, encoding='utf-8')
                self.assertEqual(gen.check(outputs), [])
            finally:
                gen.ROOT = original

    def test_real_design_and_theme_tokens_are_one_chain(self):
        design = evaluate(self.gen_outputs[DESIGN_ETS], 'DesignTokens')
        theme = evaluate(self.gen_outputs[THEME_ETS], 'CouliThemeTokens')
        assert_one_chain(self, design, theme)
        self.assertEqual(design['version'], PINNED_VERSION)
        self.assertNotIn('component', theme)

    def test_repo_files_equal_generated(self):
        for rel, text in self.theme_outputs.items():
            self.assertEqual((ROOT / rel).read_text(encoding='utf-8'), text, rel + ' 与生成器不一致（重跑 gen.py）')


def repo_copy(dest):
    """仓库当前工作树（已跟踪 + 未忽略的新文件，不含已删）复制到 dest。只读 git；不是 git 检出时按目录遍历（跳过构建产物）。"""
    r = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '-z', '-co', '--exclude-standard'], capture_output=True)
    if r.returncode == 0:
        files = [f for f in r.stdout.decode('utf-8').split('\0') if f]
    else:
        skip = {'.git', 'build', 'oh_modules', 'node_modules', '.hvigor', '.preview', '__pycache__'}
        files = []
        for dirpath, dirnames, names in os.walk(ROOT):
            dirnames[:] = [x for x in dirnames if x not in skip]
            files += [os.path.relpath(os.path.join(dirpath, n), ROOT) for n in names]
    for rel in files:
        src = ROOT / rel
        if src.is_file():
            target = Path(dest) / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target)


class LintThemeDrift(unittest.TestCase):
    """计划验收 ④：临时副本里手改 CouliThemeTokens.ets 一个色值，lint.py 退出码 1；删一行 dark 资源、改 entry base 也红。"""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix='tokens-lint-')
        cls.clean = os.path.join(cls.tmp, 'clean')
        repo_copy(cls.clean)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def lint(self, root):
        r = subprocess.run([sys.executable, os.path.join(root, 'tools/ci/lint.py')], capture_output=True, text=True, timeout=600)
        return r.returncode, r.stdout + r.stderr

    def mutant(self, name, rel, edit):
        root = os.path.join(self.tmp, name)
        shutil.copytree(self.clean, root)
        p = Path(root) / rel
        text = p.read_text(encoding='utf-8')
        new = edit(text)
        self.assertNotEqual(new, text, name + ' 变异没套上')
        p.write_text(new, encoding='utf-8')
        return root

    def test_lint_clean_then_three_theme_mutants(self):
        rc, out = self.lint(self.clean)
        self.assertEqual(rc, 0, '对照：未改的副本 lint 应为 0\n' + out[-3000:])

        def edit_color(text):
            at = text.index('new ThemeColorToken(')
            line_end = text.index('\n', at)
            line = text[at:line_end]
            hexes = [p for p in line.split('"') if p.startswith('#')]
            return text[:at] + line.replace(hexes[0], '#123456', 1) + text[line_end:]

        def drop_dark_row(text):
            data = json.loads(text)
            data['color'] = [r for r in data['color'] if r['name'] != 'color_overlay_scrim']
            return json.dumps(data, indent=2) + '\n'

        def entry_base(text):
            return text.replace('#F2EEE6', '#F2EEE7')

        for name, rel, edit in (('theme-color', THEME_ETS, edit_color), ('dark-row', DS_DARK, drop_dark_row),
                                ('entry-base', ENTRY_BASE, entry_base)):
            rc, out = self.lint(self.mutant(name, rel, edit))
            self.assertEqual(rc, 1, name + '：lint.py 应退出 1\n' + out[-2000:])
            hits = [line for line in out.splitlines() if 'HM-LINT-11' in line]
            self.assertTrue(any(rel in line for line in hits), name + '：HM-LINT-11 应点名 ' + rel + '\n' + out[-2000:])
            self.assertTrue(any('锁定快照' in line for line in hits), name + '：提示应写「与锁定快照不一致」\n' + '\n'.join(hits))
            self.assertFalse(any('令牌源副本' in line for line in hits), name)


if __name__ == '__main__':
    unittest.main(verbosity=2)
