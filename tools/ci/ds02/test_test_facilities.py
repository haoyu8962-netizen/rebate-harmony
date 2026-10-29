#!/usr/bin/env python3
"""只自测资源断言与生成器漂移设施；不把参考件当产品实现通过。"""
import json
import re
from pathlib import Path
import tempfile
import unittest
import os
import subprocess
from unittest.mock import patch
import test_host as host_tests
from test_host import assert_resource_palette, assert_resource_free_logic, ROOT, palette, argb
import gen
from check_device_result import expected_names, validate, FX25_DEVICE_CASES


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
        # F-X-05a 追加测试宿主页 Fx05aFixture（Fx05aAbility）；DS-02 宿主仍是第一项。F-X-25 的 Fx25TestAbility 走命名路由、不进页面 profile（变基到 7d5ebe7 合并）。
        # HM-07v-a 测试 v3（评审 r1 R1-01）追加横滑卡宿主页 Hm07vTileFixture（Hm07vAbility），同样只在测试 HAP。
        self.assertEqual(pages, ['pages/Ds02R1Fixture', 'pages/Fx05aFixture', 'pages/Hm07vTileFixture'])
        self.assertEqual([a['name'] for a in module['abilities']],
                         ['Ds02R1Ability', 'Fx25TestAbility', 'Fx05aAbility', 'Hm07vAbility'])
        self.assertFalse(module['abilities'][3]['exported'])
        self.assertTrue((test_root / 'ets' / (pages[0] + '.ets')).is_file())
        runner = (test_root / 'ets/testrunner/OpenHarmonyTestRunner.ets').read_text()
        self.assertIn("import('../test/List.test')", runner)
        self.assertIn('Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(),', runner)
        self.assertIn('abilityDelegatorRegistry.getArguments(), testsuite)', runner)
        for folder in ['entry/src/main', 'entry/src/staging', 'entry/src/release', 'common/designsystem/src/main']:
            for p in (root / folder).rglob('*'):
                if p.is_file() and p.suffix in ['.ets', '.json', '.json5']:
                    self.assertNotIn('Ds02R1Ability', p.read_text(), str(p))
                    self.assertNotIn('Fx05aAbility', p.read_text(), str(p))
                    self.assertNotIn('Fx05aFixture', p.read_text(), str(p))
                    self.assertNotIn('Hm07vAbility', p.read_text(), str(p))
                    self.assertNotIn('Hm07vTileFixture', p.read_text(), str(p))

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
printf '%s\\n' "$2|$4|${COULI_HM_TEST_CASE_TIMEOUT:-}|${COULI_HM_TEST_TOTAL_TIMEOUT:-}|${COULI_HM_TEST_FILTER:-}|${COULI_HM_DEVICE_SET:-}|$(basename "$3")" >> "$ROOT/device-receipts"
if [ "$PROBE" = device-fails ]; then exit 1; fi
# HM-07v-a 拆步（D10-405 D4）：第二个 entry 步失败也必须让 verify 失败。
if [ "$PROBE" = hm07va-step-fails ] && [ "${COULI_HM_DEVICE_SET:-}" = hm07va ]; then exit 1; fi
# HM-07v-b 第三步（弹窗与剪贴板浮层）失败同样必须让 verify 失败。
if [ "$PROBE" = hm07vb-step-fails ] && [ "${COULI_HM_DEVICE_SET:-}" = hm07vb ]; then exit 1; fi
# HM-05r 第四步（剪贴板用途说明与设置开关）失败同样必须让 verify 失败。
if [ "$PROBE" = hm05r-step-fails ] && [ "${COULI_HM_DEVICE_SET:-}" = hm05r ]; then exit 1; fi
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
            for probe in ['ok', 'missing-hap', 'missing-compile', 'device-fails', 'hm07va-step-fails', 'hm07vb-step-fails',
                          'hm05r-step-fails']:
                for receipt in ['build-receipts', 'device-receipts']:
                    (folder / receipt).unlink(missing_ok=True)
                result = subprocess.run(['bash', str(script), tmp, probe], capture_output=True, text=True,
                                        env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
                self.assertEqual(result.returncode, 0 if probe == 'ok' else 1, result.stdout + result.stderr)
                if probe == 'ok':
                    self.assertEqual((folder / 'build-receipts').read_text().splitlines(),
                                     ['core|genOnDeviceTestHap|default', 'same-source|apply', 'entry|assembleHap|staging',
                                      'same-source|restore', 'same-source|check'])
                    # 测试包只构建一次（上面 build-receipts 里 entry 只有一行）；entry 分三步各跑一次，各自 1800 秒、各自名单、
                    # 各自工作目录（HM-07v-a，编排 D10-405 D4；HM-07v-b 测试 v1 加第三步 hm07vb，主步同时排除两个视觉套件；
                    # HM-05r 测试 v1 加第四步 hm05r，主步再排除 Hm05rConsentUi）。
                    self.assertEqual((folder / 'device-receipts').read_text().splitlines(),
                                     ['core_test|||||all|device-test',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|'
                                      'notClass=Hm07vHomeUi,Hm07vOverlayUi,Hm05rConsentUi|main|device-test',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=Hm07vHomeUi|hm07va|'
                                      'device-test-entry-hm07va',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=Hm07vOverlayUi|hm07vb|'
                                      'device-test-entry-hm07vb',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=Hm05rConsentUi|hm05r|'
                                      'device-test-entry-hm05r'])
                if probe == 'hm07va-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-hm07va', result.stdout)
                if probe == 'hm07vb-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-hm07vb', result.stdout)
                if probe == 'hm05r-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-hm05r', result.stdout)
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
        # 合集（--set all）：DS-02 158 条 + F-X-05a 9 条（tools/ci/fx05a/fixtures/device-cases.txt；v3 加剪贴板天猫徽标 1 条，
        # 评审 r1 R1-01）+ F-X-25 6 条（AuthChangeDevice_FX25）+ HM-07v-a 17 条（tools/ci/hm07v/fixtures/device-cases.txt；测试 v3 加横滑卡 amount_unknown 1 条（R1-01）、320 金刚区命中区 1 条（R1-02））
        # + HM-07v-b 11 条（tools/ci/hm07v/fixtures/device-cases-b.txt，弹窗与剪贴板浮层）
        # + HM-05r 11 条（tools/ci/hm05r/fixtures/device-cases.txt；测试 v1 为 9 条用途说明与设置开关，测试 v3 按 2026-10-30 默认开启
        # 改为默认开启 / 关闭态 / 升级迁移四种旧状态 / 撤回与重新同意，共 11 条：只增不减，合集 210 → 212）。
        self.assertEqual(len(names), 212)
        self.assertEqual(len([name for name in names if name.startswith('hm05r_')]), 11)
        self.assertEqual(len([name for name in names if name.startswith('hm07va_')]), 17)
        self.assertEqual(len([name for name in names if name.startswith('hm07vb_')]), 11)
        self.assertIn('hm07vb_popup_image_only_close_layer_reader_focus_font200_and_dark_tokens_on_one_instance', names)
        self.assertIn('hm07va_scroll_tile_amount_unknown_hides_price_shows_label_and_reads_no_price', names)
        self.assertIn('hm07va_w320_icon_cells_hit_region_48vp_and_not_overlapping', names)
        self.assertIn('fx05a_r1_clipboard_tmall_badge_text_only_others_keep_official_icon', names)

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

        self.assertEqual(validate(report(names)), 212)
        self.assertEqual(validate(report(names + ['future_extra_test'])), 212)
        for missing in [name for name in names if name.startswith('fx05a_') or name.startswith('hm07va_')
                        or name.startswith('hm07vb_') or name.startswith('hm05r_') or name in FX25_DEVICE_CASES]:
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                validate(report([name for name in names if name != missing]))
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

    def test_split_entry_steps_each_require_their_own_list(self):
        """HM-07v-a（编排 D10-405 D4）：entry 各设备步各自的必跑名单；合集 = 三份之和，两两不相交，原 167 条一条不少。
        HM-07v-b 测试 v1：加第三步 hm07vb（11 条）。"""
        main, hm07va, every = expected_names('main'), expected_names('hm07va'), expected_names('all')
        hm07vb = expected_names('hm07vb')
        hm05r = expected_names('hm05r')
        self.assertEqual(len(main), 173)
        self.assertEqual(len(hm07va), 17)
        self.assertEqual(len(hm07vb), 11)
        self.assertEqual(len(hm05r), 11)
        self.assertEqual(main | hm07va | hm07vb | hm05r, every)
        self.assertEqual(main & hm07va, set())
        self.assertEqual(main & hm07vb, set())
        self.assertEqual(hm07va & hm07vb, set())
        self.assertEqual((main | hm07va | hm07vb) & hm05r, set())
        self.assertTrue(all(name.startswith('hm05r_') for name in hm05r))
        self.assertFalse(any(name.startswith('hm05r_') for name in main))
        consent = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Hm05rConsentUi.test.ets').read_text()
        self.assertEqual(sorted(re.findall(r"'(hm05r_\d\d_[a-z0-9_]+)'", consent)), sorted(hm05r))
        self.assertTrue(all(name.startswith('hm07va_') for name in hm07va))
        self.assertTrue(all(name.startswith('hm07vb_') for name in hm07vb))
        self.assertFalse(any(name.startswith('hm07va_') or name.startswith('hm07vb_') for name in main))
        # HM-07v-b 名单与套件 it() / 导出常量一致。
        overlay = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Hm07vOverlayUi.test.ets').read_text()
        self.assertEqual(sorted(re.findall(r"\bit\('(hm07vb_[a-z0-9_]+)'", overlay)), sorted(hm07vb))
        self.assertEqual(set(FX25_DEVICE_CASES) & main, set(FX25_DEVICE_CASES))
        # F-X-25 名单与套件里声明的 it() 一致（防止改名后这里成了空要求）。
        root = Path(__file__).resolve().parents[3]
        suite = (root / 'entry/src/ohosTest/ets/test/AuthChangeDevice.test.ets').read_text()
        self.assertEqual(sorted(re.findall(r"\bit\('(E\d\d_[A-Za-z0-9_]+)'", suite)), sorted(FX25_DEVICE_CASES))
        facilities = (root / 'tools/ci/ds02/check-ui-facilities.cjs').read_text()
        for name in FX25_DEVICE_CASES:
            self.assertIn("'" + name + "'", facilities)

        def report(case_names, failed=''):
            events = []
            for name in case_names:
                events += ['OHOS_REPORT_STATUS: test=' + name, 'OHOS_REPORT_STATUS_CODE: 1',
                           'OHOS_REPORT_STATUS: test=' + name,
                           'OHOS_REPORT_STATUS_CODE: ' + ('-2' if name == failed else '0')]
            events += [f'Tests run: {len(case_names)}, Failure: 0, Error: 0, Pass: {len(case_names)}',
                       'OHOS_REPORT_CODE: 0', 'TestFinished-ResultCode: 0']
            return '\n'.join(events)

        self.assertEqual(validate(report(sorted(main)), 'main'), 173)
        self.assertEqual(validate(report(sorted(main) + ['future_extra_test']), 'main'), 173)
        self.assertEqual(validate(report(sorted(hm07va)), 'hm07va'), 17)
        self.assertEqual(validate(report(sorted(hm07vb)), 'hm07vb'), 11)
        self.assertEqual(validate(report(sorted(hm05r)), 'hm05r'), 11)
        bad = {
            # 原 entry 步：任一条缺跑（含新列入的 F-X-25 6 条）都红；混进 hm07va 用例（过滤失效）也红。
            **{'main-missing-' + name: (report(sorted(main - {name})), 'main') for name in sorted(main)},
            'main-with-hm07va-case': (report(sorted(main) + sorted(hm07va)[:1]), 'main'),
            'main-failed': (report(sorted(main), failed=sorted(main)[0]), 'main'),
            # 单独步：17 条缺一条、多跑别的套件、有失败都红。
            **{'hm07va-missing-' + name: (report(sorted(hm07va - {name})), 'hm07va') for name in sorted(hm07va)},
            'hm07va-with-ds02-case': (report(sorted(hm07va) + sorted(main)[:1]), 'hm07va'),
            'hm07va-with-future-case': (report(sorted(hm07va) + ['future_extra_test']), 'hm07va'),
            'hm07va-failed': (report(sorted(hm07va), failed=sorted(hm07va)[0]), 'hm07va'),
            'hm07va-only-summary': ('Tests run: 17, Failure: 0, Error: 0, Pass: 17', 'hm07va'),
            'main-report-checked-as-hm07va': (report(sorted(main)), 'hm07va'),
            'hm07va-report-checked-as-main': (report(sorted(hm07va)), 'main'),
            # HM-07v-b 第三步：11 条缺一条、多跑别的套件、有失败都红；主步混进 b 段用例也红。
            'main-with-hm07vb-case': (report(sorted(main) + sorted(hm07vb)[:1]), 'main'),
            **{'hm07vb-missing-' + name: (report(sorted(hm07vb - {name})), 'hm07vb') for name in sorted(hm07vb)},
            'hm07vb-with-hm07va-case': (report(sorted(hm07vb) + sorted(hm07va)[:1]), 'hm07vb'),
            'hm07vb-with-ds02-case': (report(sorted(hm07vb) + sorted(main)[:1]), 'hm07vb'),
            'hm07vb-with-future-case': (report(sorted(hm07vb) + ['future_extra_test']), 'hm07vb'),
            'hm07vb-failed': (report(sorted(hm07vb), failed=sorted(hm07vb)[0]), 'hm07vb'),
            'hm07vb-only-summary': ('Tests run: 11, Failure: 0, Error: 0, Pass: 11', 'hm07vb'),
            'hm07va-report-checked-as-hm07vb': (report(sorted(hm07va)), 'hm07vb'),
            'hm07vb-report-checked-as-hm07va': (report(sorted(hm07vb)), 'hm07va'),
            'hm07vb-report-checked-as-main': (report(sorted(hm07vb)), 'main'),
            # HM-05r 第四步：9 条缺一条、多跑别的套件、有失败都红；主步混进 hm05r 用例也红。
            'main-with-hm05r-case': (report(sorted(main) + sorted(hm05r)[:1]), 'main'),
            **{'hm05r-missing-' + name: (report(sorted(hm05r - {name})), 'hm05r') for name in sorted(hm05r)},
            'hm05r-with-hm07vb-case': (report(sorted(hm05r) + sorted(hm07vb)[:1]), 'hm05r'),
            'hm05r-with-ds02-case': (report(sorted(hm05r) + sorted(main)[:1]), 'hm05r'),
            'hm05r-with-future-case': (report(sorted(hm05r) + ['future_extra_test']), 'hm05r'),
            'hm05r-failed': (report(sorted(hm05r), failed=sorted(hm05r)[0]), 'hm05r'),
            'hm05r-only-summary': ('Tests run: 9, Failure: 0, Error: 0, Pass: 9', 'hm05r'),
            'hm05r-report-checked-as-main': (report(sorted(hm05r)), 'main'),
            'hm05r-report-checked-as-hm07vb': (report(sorted(hm05r)), 'hm07vb'),
            'hm07vb-report-checked-as-hm05r': (report(sorted(hm07vb)), 'hm05r'),
        }
        for reason, (text, chosen) in bad.items():
            with self.subTest(reason=reason), self.assertRaises(ValueError):
                validate(text, chosen)
        with self.assertRaises(ValueError):
            expected_names('unknown')
        print('REFERENCE_ONLY split device reports rejected: %d' % len(bad))

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
