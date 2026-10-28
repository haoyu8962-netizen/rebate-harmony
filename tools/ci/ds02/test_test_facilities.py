#!/usr/bin/env python3
"""只自测资源断言与生成器漂移设施；不把参考件当产品实现通过。"""
import json
from pathlib import Path
import tempfile
import unittest
import os
import subprocess
from unittest.mock import patch
import test_host as host_tests
from test_host import assert_resource_palette, assert_resource_free_logic, ROOT, palette, argb
import gen
from check_device_result import expected_names, validate


class ResourceAssertionStrength(unittest.TestCase):
    def test_r2_tabbar_actual_callback_mutations(self):
        result = subprocess.run(['node', str(ROOT / 'tools/ci/ds02/check-r2-tabbar.cjs'), '--mutations'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count('KILLED R2-01 '), 7)
        print(result.stdout.strip())

    def test_r2_logic_entry_and_transitive_pollution_fail_actual_host_guard(self):
        original = Path.read_text
        targets = [ROOT / 'common/designsystem' / relative for relative in [
            'Logic.ets', 'src/main/ets/logic/StepUpPanelFit.ets',
            'src/main/ets/logic/ProductGridLayout.ets', 'src/main/ets/logic/CouliFixedTap.ets']]
        # generated 的包别名和 default/staging 目标也必须继续追踪。
        targets += [ROOT / 'common/generated' / relative for relative in [
            'src/main/ets/DesignTokens.ets', 'src/release/ets/DebugOnly.ets', 'src/staging/ets/DebugOnly.ets']]
        reads = set()

        def run(target=None, addition=''):
            def read(path, *args, **kwargs):
                reads.add(path.resolve())
                source = original(path, *args, **kwargs)
                return source + addition if path.resolve() == target else source
            result = unittest.TestResult()
            with patch.object(Path, 'read_text', read):
                host_tests.Ds02Host('test_r1_core_tests_use_resource_free_logic_entry').run(result)
            self.assertEqual(result.errors, [], result.errors)
            return result

        self.assertEqual(run().failures, [])
        for target in targets:
            self.assertIn(target.resolve(), reads, 'guard never read ' + str(target))
            ui_path = os.path.relpath(ROOT / 'common/designsystem/src/main/ets/components/Navigation', target.parent)
            if not ui_path.startswith('.'):
                ui_path = './' + ui_path
            for kind, addition in [
                ('resource', "\nexport const injectedResource = $r('app.color.color_brand_primary');\n"),
                ('ui-reexport', "\nexport { NavBar as InjectedUi } from '" + ui_path + "';\n"),
            ]:
                with self.subTest(target=target, kind=kind):
                    result = run(target.resolve(), addition)
                    self.assertEqual(len(result.failures), 1, result.failures)
                    self.assertIn('Logic ', result.failures[0][1])
                    # 不能拿解析失败冒充污染被守卫发现。
                    self.assertNotIn('Logic parse incomplete', result.failures[0][1])
                    self.assertIn(str(target) if kind == 'resource' else 'Navigation.ets', result.failures[0][1])
                    print('KILLED R2-02 ' + str(target.relative_to(ROOT)) + ' ' + kind)

    def test_r2_logic_graph_cycles_multihop_and_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix='ds02-logic-') as tmp:
            root = Path(tmp)
            folder = root / 'common/designsystem'
            folder.mkdir(parents=True)
            (folder / 'Logic.ets').write_text("export * from './first';\n")
            (folder / 'first.ets').write_text("export * from './second';\n")
            second = folder / 'second.ets'
            legal = "import './Logic';\n// $r('comment') @ComponentV2\nexport const hint: string = '$r( example @Component';\n"
            second.write_text(legal)
            self.assertEqual(len(assert_resource_free_logic(self, root)), 3)
            for bad in ["export const color = $r('app.color.bad');", "export const hidden = `value=${$r('app.color.bad')}`;",
                        "@ComponentV2 struct Bad { build() { Text('x') } }", "export function badUi(): void { Text('x'); }",
                        "import { promptAction } from '@kit.ArkUI';", "export * from './missing';",
                        "export * from 'unapproved-package';", "import(nameFromRuntime);", "export const broken = ;"]:
                second.write_text(legal + bad + '\n')
                with self.subTest(bad=bad), self.assertRaises(AssertionError):
                    assert_resource_free_logic(self, root)

    def test_v7_test_ability_has_explicit_full_suite_runner(self):
        root = Path(__file__).resolve().parents[3]
        test_root = root / 'entry/src/ohosTest'
        module = json.loads((test_root / 'module.json5').read_text())['module']
        self.assertEqual(module['name'], 'entry_test')
        self.assertEqual(module['pages'], '$profile:ds02_test_pages')
        ability = module['abilities'][0]
        self.assertEqual(ability['name'], 'Ds02R1Ability')
        self.assertFalse(ability['exported'])
        self.assertTrue((test_root / ability['srcEntry']).is_file())
        pages = json.loads((test_root / 'resources/base/profile/ds02_test_pages.json').read_text())['src']
        self.assertEqual(pages, ['pages/Ds02R1Fixture'])
        self.assertTrue((test_root / 'ets' / (pages[0] + '.ets')).is_file())
        runner = (test_root / 'ets/testrunner/OpenHarmonyTestRunner.ets').read_text()
        self.assertIn("import('../test/List.test')", runner)
        self.assertIn('Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(),', runner)
        self.assertIn('abilityDelegatorRegistry.getArguments(), testsuite)', runner)
        for folder in ['entry/src/main', 'entry/src/staging', 'entry/src/release', 'common/designsystem/src/main']:
            for p in (root / folder).rglob('*'):
                if p.is_file() and p.suffix in ['.ets', '.json', '.json5']:
                    self.assertNotIn('Ds02R1Ability', p.read_text(), str(p))

    def test_verify_dispatches_hap_and_har_and_requires_device_execution(self):
        root = Path(__file__).resolve().parents[3]
        source = (root / 'tools/ci/verify.sh').read_text()
        function = source.split('run_device_tests() {', 1)[1].split('\nrun_device_tests core ', 1)[0]
        entry_dispatch = source.split('COULI_HM_TEST_TOTAL_TIMEOUT=', 1)[1].split('\n\n', 1)[0]
        entry_dispatch = 'COULI_HM_TEST_TOTAL_TIMEOUT=' + entry_dispatch
        with tempfile.TemporaryDirectory(prefix='ds02-dispatch-') as tmp:
            folder = Path(tmp)
            (folder / 'tools/ci').mkdir(parents=True)
            device = folder / 'tools/ci/device-test.sh'
            device.write_text('''#!/bin/bash
set -eu
[ -f "$1" ]
printf '%s\\n' "$2|$4|${COULI_HM_TEST_CASE_TIMEOUT:-}|${COULI_HM_TEST_TOTAL_TIMEOUT:-}" >> "$ROOT/device-receipts"
if [ "$PROBE" = device-fails ]; then exit 1; fi
echo 'DEVICE_TEST_PASS simulated_only'
''')
            device.chmod(0o755)
            # F-X-25 t2：entry 测试包构建前后的「与被测应用同源」步骤（tools/ci/ohostest-app-source.cjs）；假 node 只记回执。
            (folder / 'bin').mkdir()
            fake_node = folder / 'bin/node'
            fake_node.write_text('''#!/bin/bash
set -eu
case "$1" in */tools/ci/ohostest-app-source.cjs) ;; *) exit 9 ;; esac
printf 'same-source|%s\\n' "$2" >> "$ROOT/build-receipts"
''')
            fake_node.chmod(0o755)
            script = folder / 'probe.sh'
            script.write_text('''#!/bin/bash
set -euo pipefail
export ROOT="$1"
export PROBE="$2"
BUILD_DIR="$ROOT"
OUT_DIR="$ROOT"
LOG_DIR="$ROOT"
HVIGORW=fake_hvigor
NODE_BIN="$ROOT/bin"
API_COMPAT_PATTERN=unreachable
step() { :; }
record() { :; }
show_matches() { :; }
api_compat_hits() { return 1; }
fail_fast() { echo "EXPECTED_FAILURE $*"; exit 1; }
fake_hvigor() {
    local args="$*" module product dir task
    case "$args" in
        *module=entry@ohosTest*) module=entry; product=staging; dir=entry; task=assembleHap ;;
        *module=core@ohosTest*) module=core; product=default; dir=common/core; task=genOnDeviceTestHap ;;
        *) return 1 ;;
    esac
    case " $args " in *" $task "*) ;; *) return 1 ;; esac
    case " $args " in *" isOhosTest=true "*) ;; *) return 1 ;; esac
    case " $args " in *" product=$product "*) ;; *) return 1 ;; esac
    printf '%s\\n' "$module|$task|$product" >> "$ROOT/build-receipts"
    mkdir -p "$BUILD_DIR/$dir/build/$product/outputs/ohosTest"
    if [ "$PROBE" != missing-hap ]; then
        touch "$BUILD_DIR/$dir/build/$product/outputs/ohosTest/$module-ohosTest-unsigned.hap"
    fi
    if [ "$PROBE" != missing-compile ]; then echo "Finished :$module:ohosTest@OhosTestCompileArkTS"; fi
}
run_device_tests() {''' + function + '''
run_device_tests core common/core core_test
''' + entry_dispatch + '\n')
            for probe in ['ok', 'missing-hap', 'missing-compile', 'device-fails']:
                for receipt in ['build-receipts', 'device-receipts']:
                    (folder / receipt).unlink(missing_ok=True)
                result = subprocess.run(['bash', str(script), tmp, probe], capture_output=True, text=True,
                                        env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
                self.assertEqual(result.returncode, 0 if probe == 'ok' else 1, result.stdout + result.stderr)
                if probe == 'ok':
                    self.assertEqual((folder / 'build-receipts').read_text().splitlines(),
                                     ['core|genOnDeviceTestHap|default', 'same-source|apply', 'entry|assembleHap|staging',
                                      'same-source|restore', 'same-source|check'])
                    self.assertEqual((folder / 'device-receipts').read_text().splitlines(),
                                     ['core_test|||', 'entry_test|' + tmp + '/Staging.hap|600000|1800'])
                print('REFERENCE_ONLY verify dispatch: ' + probe)

    def test_device_timeout_defaults_and_explicit_override(self):
        root = Path(__file__).resolve().parents[3]
        source = (root / 'tools/ci/device-test.sh').read_text()
        config = 'case_timeout=' + source.split('case_timeout=', 1)[1].split('\nwith_timeout ', 1)[0]
        self.assertIn('-s timeout "$case_timeout"', source)
        self.assertIn('[ "$elapsed_seconds" -le 1800 ]', source)
        for module, override, expected in [('entry_test', '', '600000'),
                                           ('entry_test', '180000', '600000'),
                                           ('core_test', '', '60000'),
                                           ('core_test', '120000', '120000')]:
            result = subprocess.run(['bash', '-c', config + '\nprintf "%s" "$case_timeout"'],
                                    capture_output=True, text=True,
                                    env={**os.environ, 'MODULE': module, 'COULI_HM_TEST_CASE_TIMEOUT': override})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)

    def test_device_report_requires_every_case_once_and_successful_finish(self):
        names = sorted(expected_names())
        self.assertEqual(len(names), 158)

        def report(case_names, failed='', footer=True):
            events = []
            for name in case_names:
                events += ['OHOS_REPORT_STATUS: test=' + name, 'OHOS_REPORT_STATUS_CODE: 1',
                           'OHOS_REPORT_STATUS: test=' + name,
                           'OHOS_REPORT_STATUS_CODE: ' + ('-2' if name == failed else '0')]
            # 即使坏报告谎称总数全过，也必须被逐例记录拦住。
            events += [f'Tests run: {len(case_names)}, Failure: 0, Error: 0, Pass: {len(case_names)}']
            if footer:
                events += ['OHOS_REPORT_CODE: 0', 'TestFinished-ResultCode: 0']
            return '\n'.join(events)

        self.assertEqual(validate(report(names)), 158)
        self.assertEqual(validate(report(names + ['future_extra_test'])), 158)
        # 12 个变体/主题任意漏一个都必须报红，旧聚合名不能抵账。
        product_names = [name for name in names if name.startswith('render_all_declared_states_ProductCard_')]
        self.assertEqual(len(product_names), 12)
        for missing in product_names:
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                validate(report([name for name in names if name != missing]))
        bad_reports = {
            'only_hello_world': report(['helloWorld']),
            'missing_dark_case': report([name for name in names if name != 'render_all_declared_states_ProductCard_large_dark']),
            'old_unsplit_names': report([name for name in names if not name.startswith('render_all_declared_states_ProductCard_')] + ['render_all_declared_states_ProductCard_light', 'render_all_declared_states_ProductCard_dark']),
            'missing_resource_suite': report([name for name in names if not name.startswith('real_semantic_resources_')]),
            'missing_moved_catalog': report([name for name in names if name != 'all_inventory_components_variants_states_and_kinds']),
            'missing_r2': report([name for name in names if not name.startswith('r2_')]),
            'missing_r1': report([name for name in names if not name.startswith('r1_')]),
            'duplicate': report(names + names[:1]),
            'assertion_failure_hidden_by_summary': report(names, failed=names[0]),
            'no_finish': report(names, footer=False),
            'summary_only': 'Tests run: 141, Failure: 0, Error: 0, Pass: 141',
        }
        for reason, text in bad_reports.items():
            with self.subTest(reason=reason), self.assertRaises(ValueError):
                validate(text)
            print('REFERENCE_ONLY device report rejected: ' + reason)

    def test_generator_check_covers_both_test_data_outputs(self):
        outputs = gen.build_outputs()
        original_root = gen.ROOT
        with tempfile.TemporaryDirectory(prefix='ds02-gen-probe-') as tmp:
            gen.write_outputs(tmp, outputs)
            try:
                gen.ROOT = tmp
                self.assertEqual(gen.check(outputs), [])
                for name in ['common/designsystem/src/test/Ds02Expected.ets',
                             'entry/src/ohosTest/ets/test/Ds02Expected.ets']:
                    path = Path(tmp) / name
                    original = path.read_text()
                    path.write_text(original + '// drift\n')
                    self.assertEqual(gen.check(outputs), [name])
                    path.write_text(original)
                self.assertEqual(gen.check(outputs), [])
            finally:
                gen.ROOT = original_root

    def test_legal_resource_order_and_three_independent_bad_variants(self):
        with tempfile.TemporaryDirectory(prefix='ds02-resource-probe-') as tmp:
            root = Path(tmp)
            for mode, field in [('base', 'value'), ('dark', 'dark')]:
                path = root / 'common/designsystem/src/main/resources' / mode / 'element/color.json'
                path.parent.mkdir(parents=True)
                rows = [{'name': key.replace('.', '_').replace('-', '_'), 'value': argb(leaf[field])}
                        for key, leaf in reversed(palette())]
                path.write_text(json.dumps({'color': rows}))
            assert_resource_palette(self, root)
            dark = root / 'common/designsystem/src/main/resources/dark/element/color.json'
            original = dark.read_text()
            for bad in ['missing', 'light-in-dark', 'rgba-not-argb']:
                data = json.loads(original)
                if bad == 'missing':
                    data['color'].pop()
                else:
                    row = next(r for r in data['color'] if r['name'] == 'color_overlay_scrim')
                    source = next(leaf for key, leaf in palette() if key == 'color.overlay.scrim')
                    row['value'] = argb(source['value']) if bad == 'light-in-dark' else source['dark']
                dark.write_text(json.dumps(data))
                with self.assertRaises(AssertionError, msg=bad):
                    assert_resource_palette(self, root)
                print('REFERENCE_ONLY resource mutant killed: ' + bad)
                dark.write_text(original)
            assert_resource_palette(self, root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
