#!/usr/bin/env python3
"""DS-02 正式宿主测试；产品入口/资源缺失就是红，不 skip。无网络/三方依赖。"""
import hashlib
import ast
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
FIX = Path(__file__).with_name('fixtures')
sys.path.insert(0, str(ROOT / 'tools/codegen'))
from ds02_test_data import leaves, argb


def palette():
    return [(key, leaf) for key, leaf in leaves(json.loads((ROOT / 'contracts/snapshot/design/design-tokens.json').read_text())['tokens'])
            if leaf['type'] == 'color']


def assert_resource_palette(case, root):
    for mode, source in [('base', 'value'), ('dark', 'dark')]:
        path = root / 'common/designsystem/src/main/resources' / mode / 'element/color.json'
        case.assertTrue(path.is_file(), '缺颜色资源 ' + str(path))
        rows = json.loads(path.read_text())['color']
        actual = {row['name']: row['value'].upper() for row in rows}
        case.assertEqual(len(rows), len(actual), '重复资源名')
        expected = {key.replace('.', '_').replace('-', '_'): argb(leaf[source]) for key, leaf in palette()}
        case.assertEqual({k: v for k, v in actual.items() if k.startswith('color_')}, expected, mode)


_logic_lex_cache = {}


def assert_resource_free_logic(case, root):
    """从公开入口追踪实际导入/重导出；未知模块、失效路径或解析不完整都失败。"""
    root = root.resolve()
    visited = set()
    pending = [root / 'common/designsystem/Logic.ets']
    aliases = {
        'generated': [root / 'common/generated/Index.ets'],
        # 同时检查默认和 staging 分支，不能在别名处截断依赖链。
        'generated/ets/DebugOnly': [root / 'common/generated/src' / mode / 'ets/DebugOnly.ets'
                                   for mode in ['release', 'staging']],
    }
    while pending:
        batch = []
        for p in pending:
            p = p.resolve()
            if p in visited:
                continue
            visited.add(p)
            case.assertTrue(p.is_relative_to(root), 'Logic dependency escaped root: ' + str(p))
            case.assertTrue(p.is_file(), 'Logic dependency missing: ' + str(p))
            batch.append((str(p), p.read_text()))
        pending = []
        fresh = [item for item in batch if item not in _logic_lex_cache]
        if fresh:
            result = subprocess.run(['node', str(ROOT / 'tools/ci/ds02/scan-logic-dependencies.cjs')],
                                    input=json.dumps([{'name': name, 'text': text} for name, text in fresh]),
                                    capture_output=True, text=True, timeout=60)
            case.assertEqual(result.returncode, 0, result.stderr)
            parsed_batch = json.loads(result.stdout)
            case.assertEqual(len(parsed_batch), len(fresh), 'Logic scanner returned incomplete batch')
            _logic_lex_cache.update(zip(fresh, parsed_batch))
        for filename, text in batch:
            p = Path(filename)
            parsed = _logic_lex_cache[(filename, text)]
            case.assertIsNone(parsed['incomplete'], 'Logic parse incomplete: ' + filename)
            case.assertEqual(parsed['violations'], [], 'Logic resource/UI contamination: ' + filename)
            for dependency in parsed['imports']:
                name = dependency['module']
                case.assertIsInstance(name, str, 'Logic unresolved import: ' + filename)
                if name.startswith('.'):
                    base = p.parent / name
                    candidates = [base] if base.suffix else [base.with_suffix('.ets'), base.with_suffix('.ts'),
                                                             base / 'Index.ets', base / 'index.ets']
                    found = next((candidate for candidate in candidates if candidate.is_file()), None)
                    case.assertIsNotNone(found, 'Logic dependency missing: ' + filename + ' -> ' + name)
                    pending.append(found)
                else:
                    case.assertIn(name, aliases, 'Logic external/UI dependency: ' + filename + ' -> ' + name)
                    pending.extend(aliases[name])
    return visited


class Ds02Host(unittest.TestCase):
    def test_r2_tabbar_actual_callbacks_keep_click_and_controlled_sync_distinct(self):
        result = subprocess.run(['node', str(ROOT / 'tools/ci/ds02/check-r2-tabbar.cjs')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_r1_external_four_combinations_real_class_and_resources(self):
        result = subprocess.run(['node', str(ROOT / 'tools/ci/ds02/check-r1.cjs')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_r1_same_navigation_component_in_catalog_and_pages(self):
        source = (ROOT / 'common/designsystem/src/main/ets/components/Navigation.ets').read_text()
        source = re.sub(r'/\*[\s\S]*?\*/|//[^\n]*', '', source)
        navbar = source.split('export struct NavBar {', 1)[1].split('export class TabBarItem', 1)[0]
        self.assertRegex(navbar, r'build\(\)\s*\{\s*Navigation\(')
        self.assertNotRegex(navbar, r"name:\s*['\"]back['\"]")
        self.assertRegex(source.split('export struct TabBar {', 1)[1], r'build\(\)\s*\{\s*Tabs\(')
        self.assertIn("from './src/main/ets/components/Navigation'", (ROOT / 'common/designsystem/Index.ets').read_text())
        for relative in ['entry/src/staging/ets/catalog/CatalogSampleViews.ets',
                         'entry/src/staging/ets/catalog/ComponentCatalog.ets',
                         'entry/src/main/ets/shell/AppShell.ets']:
            code = (ROOT / relative).read_text()
            self.assertIn('TabBar({', code, relative)
            self.assertNotIn('CouliTabs({', code, relative)
            if 'AppShell' not in relative:
                self.assertIn('NavBar({', code, relative)
                self.assertNotRegex(code, r'Navigation\(')
        # 页面不得另定义同名替代组件；现有调用必须从交付入口导入。
        for p in list((ROOT / 'features').rglob('*.ets')) + list((ROOT / 'entry/src/main').rglob('*.ets')):
            code = re.sub(r'/\*[\s\S]*?\*/|//[^\n]*', '', p.read_text())
            self.assertNotRegex(code, r'(?:struct|class)\s+NavBar\b', str(p))
            if re.search(r'\bNavBar\s*\(', code):
                self.assertRegex(code, r"import\s*\{[^}]*\bNavBar\b[^}]*\}\s*from 'designsystem'", str(p))
        for filename in ['ProductDetailView.ets', 'WalletView.ets', 'OrderDetailView.ets', 'WithdrawRecordsView.ets',
                         'WithdrawView.ets', 'RealNameView.ets', 'PayoutAccountView.ets', 'MeKit.ets']:
            files = list((ROOT / 'features').rglob(filename))
            self.assertEqual(len(files), 1, filename)
            self.assertIn('NavBar({', files[0].read_text(), filename)
        self.assertIn('NavBar({', (ROOT / 'entry/src/main/ets/trade/AuthManagePage.ets').read_text())
        web = (ROOT / 'features/web/src/main/ets/ExternalWebView.ets').read_text()
        self.assertIn('ExternalTitleColors.of(this.config.navStyle, CouliColorMode.shared().dark)', web)
        self.assertGreaterEqual(web.count('this.titleColors().text'), 3)
        self.assertIn('this.titleColors().subtitle', web)

    def test_r1_core_tests_use_resource_free_logic_entry(self):
        pending = []
        for p in (ROOT / 'common/core/src/test').glob('*.ets'):
            code = p.read_text()
            if re.search(r"from ['\"]designsystem['\"]", code):
                pending.append(str(p.relative_to(ROOT)))
        visited = assert_resource_free_logic(self, ROOT)
        for relative in ['Logic.ets', 'src/main/ets/logic/StepUpPanelFit.ets',
                         'src/main/ets/logic/ProductGridLayout.ets', 'src/main/ets/logic/CouliFixedTap.ets']:
            self.assertIn((ROOT / 'common/designsystem' / relative).resolve(), visited)
        self.assertIn((ROOT / 'common/generated/Index.ets').resolve(), visited)
        self.assertEqual(pending, [], 'R1-08 产品缺无资源入口，仍待迁移：' + ', '.join(pending))
        print('DS02_LOGIC_GRAPH files=' + str(len(visited)) + ' entry=Logic.ets generated=release+staging resource/UI=0')

    def test_all_light_dark_resources_equal_unique_source_including_alpha(self):
        assert_resource_palette(self, ROOT)

    def test_official_platform_assets_are_byte_exact(self):
        media = ROOT / 'common/designsystem/src/main/resources/base/media'
        actual = {hashlib.sha256(p.read_bytes()).hexdigest() for p in media.rglob('*') if p.is_file()}
        for name, digest in json.loads((FIX / 'platform-sha256.json').read_text()).items():
            self.assertIn(digest, actual, '缺官方原图 ' + name)

    def test_component_colors_have_no_literals(self):
        spec = importlib.util.spec_from_file_location('couli_lint', ROOT / 'tools/ci/lint.py')
        lint = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lint)
        files = sorted((ROOT / 'common/designsystem/src/main/ets/components').rglob('*.ets'))
        parsed = lint.lex_scan([(str(p), p.read_text()) for p in files])
        violations = []
        for path, result in zip(files, parsed):
            self.assertIsNone(result['incomplete'], str(path))
            for value in result['strings']:
                if re.fullmatch(r'(?:#[0-9a-fA-F]{3,4}|#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?|rgba?\([^)]*\))', value['value']):
                    violations.append(str(path.relative_to(ROOT)) + ':' + str(value['line']))
            if re.search(r'\b0x[0-9A-Fa-f]{6,8}\b|\bColor\.(?:Black|White|Red|Blue|Green|Gray|Grey|Orange|Yellow)\b', result['code']):
                violations.append(str(path.relative_to(ROOT)))
        self.assertEqual(violations, [], '颜色应来自令牌；官方品牌颜色请随官方资源走')

    def test_catalog_is_compile_time_staging_only(self):
        profile = (ROOT / 'entry/build-profile.json5').read_text()
        self.assertRegex(profile, r'"name":\s*"default"[\s\S]*?"sourceRoots":\s*\["\./src/release"\]')
        for folder in ['entry/src/main', 'entry/src/release', 'common/designsystem/src/main']:
            for p in (ROOT / folder).rglob('*.ets'):
                self.assertNotRegex(p.read_text(), r'COULI_COMPONENT_CATALOG_DS01_7f3a9c51e2|catalogCases|CatalogManifest', str(p))
        self.assertIn('COULI_COMPONENT_CATALOG_DS01_7f3a9c51e2',
                      (ROOT / 'entry/src/staging/ets/catalog/ComponentCatalog.ets').read_text())

    def test_release_scan_rejects_catalog_and_selftest_requires_it(self):
        # 运行既有扫描器失败路径测试，含 UTF-16LE 目录标记注入；不是手写一个新扫描器。
        with tempfile.TemporaryDirectory(prefix='ds02-release-') as tmp:
            result = subprocess.run(['bash', str(ROOT / 'tools/ci/release-scan-selftest.sh'), tmp + '/cases'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            import zipfile
            # 给既有扫描器完整的合成 Debug 包作为正对照，然后只去掉目录标记。
            scanner = (ROOT / 'tools/ci/release-scan.sh').read_text().split("<<'PY'\n", 1)[1].split('\nPY', 1)[0]
            assignments = [node for node in ast.parse(scanner).body if isinstance(node, ast.Assign)]
            marker_ast = next(node.value for node in assignments
                              if any(isinstance(t, ast.Name) and t.id == 'markers' for t in node.targets))
            constants = {node.targets[0].id: ast.literal_eval(node.value) for node in assignments
                         if isinstance(node.targets[0], ast.Name) and isinstance(node.value, ast.Constant)}
            markers = [constants[node.id] if isinstance(node, ast.Name) else ast.literal_eval(node)
                       for node in marker_ast.elts]
            catalog = 'COULI_COMPONENT_CATALOG_DS01_7f3a9c51e2'
            self.assertIn(catalog, markers)
            routes = json.loads((ROOT / 'contracts/snapshot/contracts/routes.json').read_text())['routes']
            markers += [name for name, route in routes.items() if route.get('debug_only')]
            for include_catalog in [True, False]:
                hap = Path(tmp) / ('all.hap' if include_catalog else 'no-catalog.hap')
                with zipfile.ZipFile(hap, 'w') as bundle:
                    bundle.writestr('module.json', json.dumps({'app': {'bundleName': 'com.couli.hm'},
                        'module': {'abilities': [{'name': 'EntryAbility',
                            'skills': [{'uris': [{'scheme': 'couli-debug', 'host': 'r'}]}]}]}}))
                    bundle.writestr('ets/modules.abc', '\n'.join(m for m in markers if include_catalog or m != catalog))
                result = subprocess.run(['bash', str(ROOT / 'tools/ci/release-scan.sh'), '--self-test', str(hap)],
                                        capture_output=True, text=True, env={**os.environ, 'COULI_SCAN_WORK_DIR': tmp + '/scan'})
                self.assertEqual(result.returncode, 0 if include_catalog else 1, result.stdout + result.stderr)
                self.assertIn(catalog, result.stdout + result.stderr)

    def test_g1_samples_legal_self_drawn_warn_and_hard_rules_still_fail(self):
        # FU-HM-G1-SYSTEM-CONTROLS（D10-827 ③ / D10-901 ② / D10-951 ③ #24）：G1 改义为「禁止自绘系统已有控件」。
        # 原 9 个样例逐字节不动，改作合法样例：不再报 G1；g1-self-drawn/ 的四个反例各报恰好一条 [couli-g1/<规则>]，只警告（exit 0）。
        legal = ROOT / 'tools/ci/lint-fixtures/ds02-warning'
        self_drawn = ROOT / 'tools/ci/lint-fixtures/g1-self-drawn'
        old_marker = '[design-system-required]'
        new_marker = '[couli-g1/'
        controls = ['Checkbox', 'Toggle', 'Radio', 'TextInput', 'TextArea', 'Search',
                    'bindSheet', 'openCustomDialog', 'showToast']
        samples = {'S1-self-drawn-control.ets': 'couli-g1/self-drawn-control',
                   'S2-click-without-feedback.ets': 'couli-g1/click-without-feedback',
                   'S3-edge-effect-none.ets': 'couli-g1/edge-effect-none',
                   'S4-hide-title-bar.ets': 'couli-g1/hide-title-bar'}

        def lint(tmp):
            result = subprocess.run([sys.executable, str(ROOT / 'tools/ci/lint.py'), '--root', tmp],
                                    capture_output=True, text=True)
            return result, result.stdout + result.stderr

        with tempfile.TemporaryDirectory(prefix='ds02-guard-') as tmp:
            target = Path(tmp)
            for scope in ['features/auth/src/main/ets', 'entry/src/main/ets']:
                for control in controls:
                    with self.subTest(scope=scope, legal=control):
                        shutil.rmtree(target / 'features', ignore_errors=True)
                        shutil.rmtree(target / 'entry', ignore_errors=True)
                        dest = target / scope / 'Violation.ets'
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        dest.write_text((legal / (control + '.ets')).read_text())
                        result, output = lint(tmp)
                        self.assertEqual(result.returncode, 0, output)
                        self.assertNotIn(old_marker, output)
                        self.assertNotIn(new_marker, output, '系统控件不应报 G1：' + control + '\n' + output)
                for sample, rule in samples.items():
                    with self.subTest(scope=scope, sample=sample):
                        shutil.rmtree(target / 'features', ignore_errors=True)
                        shutil.rmtree(target / 'entry', ignore_errors=True)
                        dest = target / scope / 'Violation.ets'
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        dest.write_text((self_drawn / sample).read_text())
                        result, output = lint(tmp)
                        self.assertEqual(result.returncode, 0, output)
                        warning = [line for line in output.splitlines() if new_marker in line and not line.startswith('lint.py：')]
                        self.assertEqual(len(warning), 1, output)
                        self.assertIn('[' + rule + ']', warning[0])
                        self.assertIn('Violation.ets:', warning[0])
            # 组件库：系统控件不报（S3 除外：薄封装同样不得关系统回弹）。
            shutil.rmtree(target / 'features', ignore_errors=True)
            shutil.rmtree(target / 'entry', ignore_errors=True)
            library = target / 'common/designsystem/src/main/ets/Legal.ets'
            library.parent.mkdir(parents=True, exist_ok=True)
            for control in controls:
                with self.subTest(library_legal=control):
                    library.write_text((legal / (control + '.ets')).read_text())
                    result, output = lint(tmp)
                    self.assertEqual(result.returncode, 0, output)
                    self.assertNotIn(new_marker, output)
            for sample, rule in samples.items():
                with self.subTest(library_sample=sample):
                    library.write_text((self_drawn / sample).read_text())
                    result, output = lint(tmp)
                    self.assertEqual(result.returncode, 0, output)
                    warning = [line for line in output.splitlines() if new_marker in line and not line.startswith('lint.py：')]
                    self.assertEqual(len(warning), 1 if rule == 'couli-g1/edge-effect-none' else 0, output)
            # 合法对照：字符串、注释与前缀同名函数不误报。
            library.unlink()
            page = target / 'entry/src/main/ets/Legal.ets'
            page.parent.mkdir(parents=True, exist_ok=True)
            page.write_text("// Checkbox({}) EdgeEffect.None\nconst hint: string = '.hideTitleBar(true) .onClick(';\n"
                            "function MyCheckbox(): void {}\nMyCheckbox();\n")
            result, output = lint(tmp)
            self.assertEqual(result.returncode, 0, output)
            self.assertNotIn(old_marker, output)
            self.assertNotIn(new_marker, output)
            page.write_text("import router from '@ohos.router';\n")
            result, output = lint(tmp)
            self.assertEqual(result.returncode, 1, output)
            self.assertIn('HM-LINT-3', output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
