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
# APP-12v-harmony 第五步（「我的」Tab 视觉）失败同样必须让 verify 失败。
if [ "$PROBE" = me12v-step-fails ] && [ "${COULI_HM_DEVICE_SET:-}" = me12v ]; then exit 1; fi
# APP-12w-a-harmony 第六步（设置一族视觉）失败同样必须让 verify 失败。
if [ "$PROBE" = me12wa-step-fails ] && [ "${COULI_HM_DEVICE_SET:-}" = me12wa ]; then exit 1; fi
# APP-12w-b-harmony 第七步（隐私中心 / 关于 / 客服半屏视觉）失败同样必须让 verify 失败。
if [ "$PROBE" = me12wb-step-fails ] && [ "${COULI_HM_DEVICE_SET:-}" = me12wb ]; then exit 1; fi
# APP-12w-c-harmony 第八步（账号状态 / 申诉视觉）失败同样必须让 verify 失败。
if [ "$PROBE" = me12wc-step-fails ] && [ "${COULI_HM_DEVICE_SET:-}" = me12wc ]; then exit 1; fi
# FU-HM-TAB-BAR 第九步（系统底栏）失败同样必须让 verify 失败。
if [ "$PROBE" = tabbar-step-fails ] && [ "${COULI_HM_DEVICE_SET:-}" = tabbar ]; then exit 1; fi
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
                          'hm05r-step-fails', 'me12v-step-fails', 'me12wa-step-fails', 'me12wb-step-fails', 'me12wc-step-fails', 'tabbar-step-fails']:
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
                    # HM-05r 测试 v1 加第四步 hm05r，主步再排除 Hm05rConsentUi；APP-12v-harmony 测试 v1 加第五步 me12v，主步再排除 Me12vUi；
                    # APP-12w-a-harmony 测试 v1 加第六步 me12wa，主步再排除 Me12waUi；APP-12w-b-harmony 测试 v1 加第七步 me12wb，主步再排除 Me12wbUi；
                    # APP-12w-c-harmony 测试 v1 加第八步 me12wc，主步再排除 Me12wcUi；FU-HM-TAB-BAR 测试 v1 加第九步 tabbar，主步再排除 TabBarShellUi）。
                    self.assertEqual((folder / 'device-receipts').read_text().splitlines(),
                                     ['core_test|||||all|device-test',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|'
                                      'notClass=HmA11yUi,LoginPhoneUi,Hm07vHomeUi,Hm07vOverlayUi,Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi|main|device-test',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=Hm07vHomeUi|hm07va|'
                                      'device-test-entry-hm07va',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=Hm07vOverlayUi|hm07vb|'
                                      'device-test-entry-hm07vb',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=Hm05rConsentUi|hm05r|'
                                      'device-test-entry-hm05r',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=Me12vUi|me12v|'
                                      'device-test-entry-me12v',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=Me12waUi|me12wa|'
                                      'device-test-entry-me12wa',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=Me12wbUi|me12wb|'
                                      'device-test-entry-me12wb',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=Me12wcUi|me12wc|'
                                      'device-test-entry-me12wc',
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=TabBarShellUi|tabbar|'
                                      'device-test-entry-tabbar',
                                      # FU-HM-LOGIN-PHONE-LAYOUT 测试 v1（#24 只加）：第十步 loginphone，主步再排除 LoginPhoneUi（放在排除名单最前）。
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=LoginPhoneUi|loginphone|'
                                      'device-test-entry-loginphone',
                                      # FU-HM-A11Y-COMMON 测试 v1（#24 只加）：第十一步 a11y，主步再排除 HmA11yUi（放在排除名单最前）。
                                      'entry_test|' + tmp + '/Staging.hap|600000|1800|class=HmA11yUi|a11y|'
                                      'device-test-entry-a11y'])
                if probe == 'hm07va-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-hm07va', result.stdout)
                if probe == 'hm07vb-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-hm07vb', result.stdout)
                if probe == 'hm05r-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-hm05r', result.stdout)
                if probe == 'me12v-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-me12v', result.stdout)
                if probe == 'me12wa-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-me12wa', result.stdout)
                if probe == 'me12wb-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-me12wb', result.stdout)
                if probe == 'me12wc-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-me12wc', result.stdout)
                if probe == 'tabbar-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-tabbar', result.stdout)
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
        # 改为默认开启 / 关闭态 / 升级迁移四种旧状态 / 撤回与重新同意，共 11 条：只增不减，合集 210 → 212）
        # + APP-12v-harmony 14 条（tools/ci/me12v/fixtures/device-cases.txt，「我的」Tab 视觉；只增不减，合集 212 → 226）
        # + APP-12w-a-harmony 15 条（tools/ci/me12wa/fixtures/device-cases.txt，设置一族视觉；只增不减，合集 226 → 241）
        # + APP-12w-b-harmony 17 条（tools/ci/me12wb/fixtures/device-cases.txt，隐私中心 / 关于 / 客服半屏视觉；只增不减，合集 241 → 258）
        # + APP-12w-c-harmony 21 条（tools/ci/me12wc/fixtures/device-cases.txt，账号状态 / 申诉视觉；测试 v5 加键盘避让 1 条，只增不减，合集 258 → 279）
        # + FU-HM-TAB-BAR 7 条（tools/ci/tabbar/device-cases.txt，系统底栏；只增不减，合集 279 → 286）。
        # FU-HM-FEEL-KIT（#24）：目录加 FeelLab，按 inventory 派生 render_all_declared_states_FeelLab_light / _dark 2 条，DS-02 158 → 160；只增不减，合集 286 → 288、main 173 → 175。
        # HM-L2-CARD（#24 只加）：目录加 CouliCard，按 inventory 派生 render_all_declared_states_CouliCard_light / _dark 2 条（DS-02 160 → 162）
        # + Ds02L2Ui 8 条（tools/ci/l2card/device-cases.txt，主 entry 步里跑）；只增不减，合集 288 → 298、main 175 → 185。
        # HM-L2-SKELETON（#24 只加）：Ds02L2Ui 另加 L2SKEL 段 6 条（tools/ci/l2skeleton/device-cases.txt）；Skeleton 加 host × gated 不加 render_all 条数；
        # 只增不减，合集 298 → 304、main 185 → 191、l2 8 → 14。
        # HM-L2-BUTTON（#24，D10-1177 ⑩）：L2 共用套件 Ds02L2Ui 在 entry List 登记、随主步跑，+7 条 l2button_；只增不减，合集 304 → 311、main 191 → 198。
        # HM-L2-PRICE-TAG（#24，D10-1177 ⑩）：同一套件 Ds02L2Ui 的第二段随主步跑，+5 条 l2price_（inventory 新行 RebateTag block/normal 不新增名字）；只增不减，合集 311 → 316、main 198 → 203。
        # HM-L2 批 1 集成（FREEZE，D10-1177 ⑨）：四单按上面顺序叠加，合集 = 288 + CouliCard 渲染 2 + Ds02L2Ui 26 = 316。
        # HM-L2 批 1 集成 2（FREEZE，D10-1177 ⑨）：STATE 段（Ds02L2UiState 7 条）叠在上面五单之后，合集 = 288 + CouliCard 渲染 2 + Ds02L2Ui 33 = 323。
        # HM-L2-PRODUCT-CELL（#24 只加）：cell 段 9 条（tools/ci/l2cell/device-cases.txt）叠在 STATE 段之后，目录不增行；合集 323 → 332。
        # FU-HM-LOGIN-PHONE-LAYOUT（#24 只加）：单独步 loginphone 6 条（tools/ci/loginphone/device-cases.txt）进合集；332 → 338。
        # FU-HM-A11Y-COMMON（#24 只加）：单独步 a11y 5 条（tools/ci/a11ycommon/device-cases.txt）进合集；338 → 343。
        self.assertEqual(len(names), 343)
        self.assertEqual(len([name for name in names if name.startswith('l2cell_')]), 9)
        self.assertEqual(len([name for name in names if name.startswith('l2card_')]), 8)
        self.assertEqual(len([name for name in names if name.startswith('l2skel_')]), 6)
        self.assertIn('render_all_declared_states_CouliCard_light', names)
        self.assertIn('render_all_declared_states_CouliCard_dark', names)
        self.assertEqual(len([name for name in names if name.startswith('l2button_')]), 7)
        self.assertEqual(len([name for name in names if name.startswith('l2price_')]), 5)
        # HM-L2-STATE（#24 只加）：Ds02L2UiState 7 条（tools/ci/l2state/device-cases.txt；README ⑩ 在主 entry 步跑）；inventory 加 ErrorState trace6/retrying 一行不新增名字
        # （render_all_declared_states_ErrorState_light / _dark 不变）。只增不减，合集 288 → 295、main 175 → 182。
        self.assertEqual(len([name for name in names if name.startswith('l2state_')]), 7)
        self.assertEqual(len([name for name in names if name.startswith('tabbar_')]), 7)
        self.assertEqual(len([name for name in names if name.startswith('me12wc_')]), 21)
        self.assertEqual(len([name for name in names if name.startswith('me12wb_')]), 17)
        self.assertEqual(len([name for name in names if name.startswith('me12wa_')]), 15)
        self.assertEqual(len([name for name in names if name.startswith('me12v_')]), 14)
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

        self.assertEqual(validate(report(names)), 343)
        self.assertEqual(validate(report(names + ['future_extra_test'])), 343)
        for missing in [name for name in names if name.startswith('fx05a_') or name.startswith('hm07va_')
                        or name.startswith('hm07vb_') or name.startswith('hm05r_') or name.startswith('me12v_')
                        or name.startswith('me12wa_') or name.startswith('me12wb_') or name.startswith('me12wc_') or name.startswith('tabbar_')
                        or name.startswith('l2card_') or name.startswith('render_all_declared_states_CouliCard_')
                        or name.startswith('l2skel_')
                        or name.startswith('l2button_') or name.startswith('l2price_')
                        or name.startswith('l2state_')
                        or name.startswith('l2cell_')
                        or name in FX25_DEVICE_CASES]:
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
        me12v = expected_names('me12v')
        me12wa = expected_names('me12wa')
        me12wb = expected_names('me12wb')
        me12wc = expected_names('me12wc')
        tabbar = expected_names('tabbar')
        loginphone = expected_names('loginphone')
        a11y = expected_names('a11y')
        l2 = expected_names('l2')
        self.assertEqual(len(main), 219)
        self.assertEqual(len(l2), 42)
        # HM-L2-STATE（集成 2 换定位）：class=Ds02L2UiState 不复存在，l2state 7 条从 l2 里按前缀取（原 expected_names('l2state')）。
        l2state = {name for name in l2 if name.startswith('l2state_')}
        self.assertEqual(len(l2state), 7)
        # HM-L2-BUTTON：Ds02L2Ui 随主步跑（不新增设备步），7 条 l2button_ 只在 main，名单与套件 it() 一致（带 + mode 的按 light / dark 展开）。
        # HM-L2 批 1 集成（§收尾，换定位）：用例名原样挪进 L2BUTTON_DEVICE_CASES，按常量下标注册（同 L2SKEL），下标 0..n-1 各恰好一次。
        l2button = {name for name in main if name.startswith('l2button_')}
        self.assertEqual(len(l2button), 7)
        l2_suite = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets').read_text()
        l2_declared = re.findall(r"'(l2button_\d\d_[a-z0-9_]+)'", l2_suite.split('L2BUTTON_DEVICE_CASES: string[] = [')[1].split('];')[0])
        self.assertEqual(sorted(int(i) for i in re.findall(r"\bit\(L2BUTTON_DEVICE_CASES\[(\d+)\]", l2_suite)), list(range(len(l2_declared))))
        self.assertEqual(sorted(n + m if n.endswith('_') else n for n in l2_declared
                                for m in (['light', 'dark'] if n.endswith('_') else [''])), sorted(l2button))
        # HM-L2-PRICE-TAG：同一套件第二段，5 条 l2price_ 只在 main，名单与套件 it('l2price_…') 一致（带 + mode 的按 light / dark 展开）。
        # HM-L2 批 1 集成（§收尾，换定位）：用例名原样挪进 L2PRICE_DEVICE_CASES，按常量下标注册，下标 0..n-1 各恰好一次。
        l2price = {name for name in main if name.startswith('l2price_')}
        self.assertEqual(len(l2price), 5)
        l2price_declared = re.findall(r"'(l2price_\d\d_[a-z0-9_]+)'", l2_suite.split('L2PRICE_DEVICE_CASES: string[] = [')[1].split('];')[0])
        self.assertEqual(sorted(int(i) for i in re.findall(r"\bit\(L2PRICE_DEVICE_CASES\[(\d+)\]", l2_suite)), list(range(len(l2price_declared))))
        self.assertEqual(sorted(n + m if n.endswith('_') else n for n in l2price_declared
                                for m in (['light', 'dark'] if n.endswith('_') else [''])), sorted(l2price))
        self.assertEqual(len(me12wc), 21)
        self.assertEqual(len(tabbar), 7)
        self.assertEqual(len(me12wb), 17)
        self.assertEqual(len(me12v), 14)
        self.assertEqual(len(me12wa), 15)
        self.assertEqual(len(hm07va), 17)
        self.assertEqual(len(hm07vb), 11)
        self.assertEqual(len(hm05r), 11)
        self.assertEqual(len(loginphone), 6)
        self.assertEqual(len(a11y), 5)
        self.assertEqual(main | hm07va | hm07vb | hm05r | me12v | me12wa | me12wb | me12wc | tabbar | loginphone | a11y, every)
        self.assertEqual(loginphone & (main | hm07va | hm07vb | hm05r | me12v | me12wa | me12wb | me12wc | tabbar), set())
        # FU-HM-A11Y-COMMON（#24 只加）：a11y 与其余各步不相交。
        self.assertEqual(a11y & (main | hm07va | hm07vb | hm05r | me12v | me12wa | me12wb | me12wc | tabbar | loginphone), set())
        # HM-L2-CARD（#24 只加）：l2 是主步的子集（README ⑩ 不新增设备步），与 8 个单独步不相交，名单与套件导出常量一致。
        self.assertEqual(l2 - main, set())
        self.assertEqual((hm07va | hm07vb | hm05r | me12v | me12wa | me12wb | me12wc | tabbar) & l2, set())
        self.assertTrue(all(name.startswith('l2card_') or name.startswith('l2skel_') or name.startswith('l2button_') or name.startswith('l2price_')
                            or name.startswith('l2state_') or name.startswith('l2cell_') for name in l2))
        l2_suite = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets').read_text()
        l2_const = l2_suite.split('L2CARD_DEVICE_CASES')[1].split('];')[0]
        l2card = {name for name in l2 if name.startswith('l2card_')}
        self.assertEqual(len(l2card), 8)
        self.assertEqual(sorted(re.findall(r"'(l2card_\d\d_[a-z0-9_]+)'", l2_const)), sorted(l2card))
        self.assertEqual(sorted(re.findall(r"\bit\('(l2card_\d\d_[a-z0-9_]+)'", l2_suite)), sorted(l2card))
        # HM-L2-SKELETON（#24 只加）：L2SKEL 段名单 = 套件导出常量；it 按常量下标注册，下标 0..5 各恰好一次（另由 check_l2_skeleton.py K8-cases 守）。
        l2skel = {name for name in l2 if name.startswith('l2skel_')}
        self.assertEqual(len(l2skel), 6)
        skel_const = l2_suite.split('L2SKEL_DEVICE_CASES: string[] = [')[1].split('];')[0]
        self.assertEqual(sorted(re.findall(r"'(l2skel_\d\d_[a-z0-9_]+)'", skel_const)), sorted(l2skel))
        self.assertEqual(sorted(int(i) for i in re.findall(r"\bit\(L2SKEL_DEVICE_CASES\[(\d+)\]", l2_suite)), list(range(len(l2skel))))
        # HM-L2 批 1 集成（FREEZE）：子集跑 class=Ds02L2Ui 跑唯一 describe 里的全部段，l2 = 四段按前缀分的并集（各段名单各自按本段前缀核对）。
        # HM-L2 批 1 集成 2：STATE 段同在唯一 describe 里，l2 = 五段按前缀分的并集。
        # HM-L2-PRODUCT-CELL（#24 只加）：cell 段同在唯一 describe 里，l2 = 六段按前缀分的并集；名单 = 套件导出常量，it 按常量下标 0..n-1 各一次。
        l2cell = {name for name in l2 if name.startswith('l2cell_')}
        self.assertEqual(len(l2cell), 9)
        self.assertEqual(l2cell - main, set())
        self.assertEqual((hm07va | hm07vb | hm05r | me12v | me12wa | me12wb | me12wc | tabbar) & l2cell, set())
        cell_const = l2_suite.split('L2CELL_DEVICE_CASES: string[] = [')[1].split('];')[0]
        self.assertEqual(sorted(re.findall(r"'(l2cell_\d\d_[a-z0-9_]+)'", cell_const)), sorted(l2cell))
        self.assertEqual(sorted(int(i) for i in re.findall(r"\bit\(L2CELL_DEVICE_CASES\[(\d+)\]", l2_suite)), list(range(len(l2cell))))
        self.assertEqual(l2, l2card | l2skel | l2button | l2price | l2state | l2cell)
        # FU-HM-TAB-BAR 第九步：与其余各步两两不相交，名单与套件导出常量一致。
        self.assertEqual((main | hm07va | hm07vb | hm05r | me12v | me12wa | me12wb | me12wc) & tabbar, set())
        self.assertTrue(all(name.startswith('tabbar_') for name in tabbar))
        self.assertFalse(any(name.startswith('tabbar_') for name in main))
        tabbar_suite = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/TabBarShellUi.test.ets').read_text()
        self.assertEqual(sorted(re.findall(r"'(tabbar_\d\d_[a-z0-9_]+)'", tabbar_suite.split('];')[0])), sorted(tabbar))
        # HM-L2-STATE（README ⑩ 不新增设备步）：Ds02L2UiState 7 条属主步必跑（main 的子集），与各单独步不相交；名单与套件导出常量一致。
        self.assertEqual(l2state - main, set())
        self.assertEqual((hm07va | hm07vb | hm05r | me12v | me12wa | me12wb | me12wc | tabbar) & l2state, set())
        self.assertTrue(all(name.startswith('l2state_') for name in l2state))
        l2state_suite = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets').read_text()
        self.assertEqual(sorted(re.findall(r"'(l2state_[a-z0-9_]+)'", l2state_suite.split('L2STATE_DEVICE_CASES: string[] = [', 1)[1].split('];')[0])),
                         sorted(l2state))
        # APP-12w-c-harmony 第八步：与其余各步两两不相交，名单与套件导出常量一致。
        self.assertEqual((main | hm07va | hm07vb | hm05r | me12v | me12wa | me12wb) & me12wc, set())
        self.assertTrue(all(name.startswith('me12wc_') for name in me12wc))
        self.assertFalse(any(name.startswith('me12wc_') for name in main))
        wc_suite = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Me12wcUi.test.ets').read_text()
        self.assertEqual(sorted(re.findall(r"'(me12wc_\d\d_[a-z0-9_]+)'", wc_suite)), sorted(me12wc))
        # APP-12w-b-harmony 第七步：与其余各步两两不相交，名单与套件导出常量一致。
        self.assertEqual((main | hm07va | hm07vb | hm05r | me12v | me12wa) & me12wb, set())
        self.assertTrue(all(name.startswith('me12wb_') for name in me12wb))
        self.assertFalse(any(name.startswith('me12wb_') for name in main))
        wb_suite = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Me12wbUi.test.ets').read_text()
        self.assertEqual(sorted(re.findall(r"'(me12wb_\d\d_[a-z0-9_]+)'", wb_suite)), sorted(me12wb))
        self.assertEqual((main | hm07va | hm07vb | hm05r) & me12v, set())
        # APP-12w-a-harmony 第六步：与其余各步两两不相交，名单与套件导出常量一致。
        self.assertEqual((main | hm07va | hm07vb | hm05r | me12v) & me12wa, set())
        self.assertTrue(all(name.startswith('me12wa_') for name in me12wa))
        self.assertFalse(any(name.startswith('me12wa_') for name in main))
        wa_suite = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Me12waUi.test.ets').read_text()
        self.assertEqual(sorted(re.findall(r"'(me12wa_\d\d_[a-z0-9_]+)'", wa_suite)), sorted(me12wa))
        self.assertTrue(all(name.startswith('me12v_') for name in me12v))
        self.assertFalse(any(name.startswith('me12v_') for name in main))
        me_suite = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Me12vUi.test.ets').read_text()
        self.assertEqual(sorted(re.findall(r"'(me12v_\d\d_[a-z0-9_]+)'", me_suite)), sorted(me12v))
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

        self.assertEqual(validate(report(sorted(main)), 'main'), 219)
        self.assertEqual(validate(report(sorted(main) + ['future_extra_test']), 'main'), 219)
        self.assertEqual(validate(report(sorted(hm07va)), 'hm07va'), 17)
        self.assertEqual(validate(report(sorted(hm07vb)), 'hm07vb'), 11)
        self.assertEqual(validate(report(sorted(hm05r)), 'hm05r'), 11)
        self.assertEqual(validate(report(sorted(me12v)), 'me12v'), 14)
        self.assertEqual(validate(report(sorted(me12wa)), 'me12wa'), 15)
        self.assertEqual(validate(report(sorted(me12wb)), 'me12wb'), 17)
        self.assertEqual(validate(report(sorted(me12wc)), 'me12wc'), 21)
        self.assertEqual(validate(report(sorted(tabbar)), 'tabbar'), 7)
        self.assertEqual(validate(report(sorted(l2)), 'l2'), 42)
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
            # APP-12v-harmony 第五步：14 条缺一条、多跑别的套件、有失败都红；主步混进 me12v 用例也红。
            'main-with-me12v-case': (report(sorted(main) + sorted(me12v)[:1]), 'main'),
            **{'me12v-missing-' + name: (report(sorted(me12v - {name})), 'me12v') for name in sorted(me12v)},
            'me12v-with-hm05r-case': (report(sorted(me12v) + sorted(hm05r)[:1]), 'me12v'),
            'me12v-with-ds02-case': (report(sorted(me12v) + sorted(main)[:1]), 'me12v'),
            'me12v-with-future-case': (report(sorted(me12v) + ['future_extra_test']), 'me12v'),
            'me12v-failed': (report(sorted(me12v), failed=sorted(me12v)[0]), 'me12v'),
            'me12v-only-summary': ('Tests run: 14, Failure: 0, Error: 0, Pass: 14', 'me12v'),
            'me12v-report-checked-as-main': (report(sorted(me12v)), 'main'),
            'me12v-report-checked-as-hm05r': (report(sorted(me12v)), 'hm05r'),
            'hm05r-report-checked-as-me12v': (report(sorted(hm05r)), 'me12v'),
            # APP-12w-a-harmony 第六步：15 条缺一条、多跑别的套件、有失败都红；主步混进 me12wa 用例也红。
            'main-with-me12wa-case': (report(sorted(main) + sorted(me12wa)[:1]), 'main'),
            **{'me12wa-missing-' + name: (report(sorted(me12wa - {name})), 'me12wa') for name in sorted(me12wa)},
            'me12wa-with-me12v-case': (report(sorted(me12wa) + sorted(me12v)[:1]), 'me12wa'),
            'me12wa-with-ds02-case': (report(sorted(me12wa) + sorted(main)[:1]), 'me12wa'),
            'me12wa-with-future-case': (report(sorted(me12wa) + ['future_extra_test']), 'me12wa'),
            'me12wa-failed': (report(sorted(me12wa), failed=sorted(me12wa)[0]), 'me12wa'),
            'me12wa-only-summary': ('Tests run: 15, Failure: 0, Error: 0, Pass: 15', 'me12wa'),
            'me12wa-report-checked-as-main': (report(sorted(me12wa)), 'main'),
            'me12wa-report-checked-as-me12v': (report(sorted(me12wa)), 'me12v'),
            'me12v-report-checked-as-me12wa': (report(sorted(me12v)), 'me12wa'),
            # APP-12w-b-harmony 第七步：17 条缺一条、多跑别的套件、有失败都红；主步混进 me12wb 用例也红。
            'main-with-me12wb-case': (report(sorted(main) + sorted(me12wb)[:1]), 'main'),
            **{'me12wb-missing-' + name: (report(sorted(me12wb - {name})), 'me12wb') for name in sorted(me12wb)},
            'me12wb-with-me12wa-case': (report(sorted(me12wb) + sorted(me12wa)[:1]), 'me12wb'),
            'me12wb-with-ds02-case': (report(sorted(me12wb) + sorted(main)[:1]), 'me12wb'),
            'me12wb-with-future-case': (report(sorted(me12wb) + ['future_extra_test']), 'me12wb'),
            'me12wb-failed': (report(sorted(me12wb), failed=sorted(me12wb)[0]), 'me12wb'),
            'me12wb-only-summary': ('Tests run: 17, Failure: 0, Error: 0, Pass: 17', 'me12wb'),
            'me12wb-report-checked-as-main': (report(sorted(me12wb)), 'main'),
            'me12wb-report-checked-as-me12wa': (report(sorted(me12wb)), 'me12wa'),
            'me12wa-report-checked-as-me12wb': (report(sorted(me12wa)), 'me12wb'),
            # APP-12w-c-harmony 第八步：21 条缺一条、多跑别的套件、有失败都红；主步混进 me12wc 用例也红。
            'main-with-me12wc-case': (report(sorted(main) + sorted(me12wc)[:1]), 'main'),
            **{'me12wc-missing-' + name: (report(sorted(me12wc - {name})), 'me12wc') for name in sorted(me12wc)},
            'me12wc-with-me12wb-case': (report(sorted(me12wc) + sorted(me12wb)[:1]), 'me12wc'),
            'me12wc-with-ds02-case': (report(sorted(me12wc) + sorted(main)[:1]), 'me12wc'),
            'me12wc-with-future-case': (report(sorted(me12wc) + ['future_extra_test']), 'me12wc'),
            'me12wc-failed': (report(sorted(me12wc), failed=sorted(me12wc)[0]), 'me12wc'),
            'me12wc-only-summary': ('Tests run: 21, Failure: 0, Error: 0, Pass: 21', 'me12wc'),
            'me12wc-report-checked-as-main': (report(sorted(me12wc)), 'main'),
            'me12wc-report-checked-as-me12wb': (report(sorted(me12wc)), 'me12wb'),
            'me12wb-report-checked-as-me12wc': (report(sorted(me12wb)), 'me12wc'),
            # FU-HM-TAB-BAR 第九步：7 条缺一条、多跑别的套件、有失败都红；主步混进 tabbar 用例也红。
            'main-with-tabbar-case': (report(sorted(main) + sorted(tabbar)[:1]), 'main'),
            **{'tabbar-missing-' + name: (report(sorted(tabbar - {name})), 'tabbar') for name in sorted(tabbar)},
            'tabbar-with-ds02-case': (report(sorted(tabbar) + sorted(main)[:1]), 'tabbar'),
            'tabbar-with-future-case': (report(sorted(tabbar) + ['future_extra_test']), 'tabbar'),
            'tabbar-failed': (report(sorted(tabbar), failed=sorted(tabbar)[0]), 'tabbar'),
            'tabbar-only-summary': ('Tests run: 7, Failure: 0, Error: 0, Pass: 7', 'tabbar'),
            'tabbar-report-checked-as-main': (report(sorted(tabbar)), 'main'),
            'me12wc-report-checked-as-tabbar': (report(sorted(me12wc)), 'tabbar'),
            # HM-L2-CARD（#24 只加）：l2 子集跑 8 条缺一条、混进别的套件、有失败、只有汇总都红；主步缺任一条 l2card_ 已由上方 main-missing-* 覆盖。
            **{'l2-missing-' + name: (report(sorted(l2 - {name})), 'l2') for name in sorted(l2)},
            'l2-with-ds02-case': (report(sorted(l2) + sorted(main - l2)[:1]), 'l2'),
            'l2-with-tabbar-case': (report(sorted(l2) + sorted(tabbar)[:1]), 'l2'),
            'l2-with-future-case': (report(sorted(l2) + ['future_extra_test']), 'l2'),
            'l2-failed': (report(sorted(l2), failed=sorted(l2)[0]), 'l2'),
            'l2-only-summary': ('Tests run: 42, Failure: 0, Error: 0, Pass: 42', 'l2'),
            'l2-report-checked-as-main': (report(sorted(l2)), 'main'),
            'tabbar-report-checked-as-l2': (report(sorted(tabbar)), 'l2'),
            # HM-L2-STATE 子集（原 class=Ds02L2UiState，--set l2state；集成 2 并入 l2，只换集合值）：l2 里缺任一条 l2state_、多跑别的套件、
            # 某条 l2state_ 失败都红；STATE 那 7 条单独的报告当主步核对也红（主步缺其余用例）。
            **{'l2state-missing-' + name: (report(sorted(l2 - {name})), 'l2') for name in sorted(l2state)},
            'l2state-with-ds02-case': (report(sorted(l2) + sorted(main - l2)[:1]), 'l2'),
            'l2state-with-tabbar-case': (report(sorted(l2) + sorted(tabbar)[:1]), 'l2'),
            'l2state-with-future-case': (report(sorted(l2) + ['future_extra_test']), 'l2'),
            'l2state-failed': (report(sorted(l2), failed=sorted(l2state)[0]), 'l2'),
            'l2state-only-summary': ('Tests run: 42, Failure: 0, Error: 0, Pass: 42', 'l2'),
            'l2state-report-checked-as-main': (report(sorted(l2state)), 'main'),
            'l2state-report-checked-as-l2': (report(sorted(l2state)), 'l2'),
            'tabbar-report-checked-as-l2-state': (report(sorted(tabbar)), 'l2'),
            # HM-L2-PRODUCT-CELL（#24 只加）：l2 里缺任一条 l2cell_、某条 l2cell_ 失败、cell 9 条单独当 main / l2 核对都红。
            **{'l2cell-missing-' + name: (report(sorted(l2 - {name})), 'l2') for name in sorted(l2cell)},
            'l2cell-failed': (report(sorted(l2), failed=sorted(l2cell)[0]), 'l2'),
            'l2cell-report-checked-as-main': (report(sorted(l2cell)), 'main'),
            'l2cell-report-checked-as-l2': (report(sorted(l2cell)), 'l2'),
        }
        for reason, (text, chosen) in bad.items():
            with self.subTest(reason=reason), self.assertRaises(ValueError):
                validate(text, chosen)
        with self.assertRaises(ValueError):
            expected_names('unknown')
        print('REFERENCE_ONLY split device reports rejected: %d' % len(bad))

    def test_l2_segment_boundary_keeps_original_segment_hooks(self):
        """HM-L2 批 1 集成（#24 只加，integ1-recheck-harmony S2）：BUTTON / PRICE-TAG 原 describe 的 beforeAll / afterAll 挪进 Ds02L2Ui
        文件末「段边界」后，原钩子计数（check-ui-facilities beforeAll == 4）看不到它们了；这里把段边界钉住：
        ① 模块级 it 包装在用例体之前 await l2EnterSegment(name)，且是唯一向 hypium 注册的入口；
        ② CARD / BUTTON / PRICE-TAG 三段的段前准备、段后复位 = 原 beforeAll / afterAll 原文（dfe55d2 / 562087f，空白归一后逐字比）；
        ③ l2EnterSegment 依次复位上一段、准备本段、drain，准备失败本段每条都抛；l2FinishSegments 复位最后一段；
        ④ l2SegmentOf 的前缀与 L2BUTTON_DEVICE_CASES / L2PRICE_DEVICE_CASES 一致，CARD / SKELETON 名都落 card 段。
        集成 2（integ2-harmony.md，只加 STATE 分支）：原 Ds02L2UiState describe 的 beforeAll / afterAll 原文（cfa4de9）挪进
        L2StateSegment.l2StateSetup / l2StateLeave，段边界在 PRICE-TAG 之后的 state 段调用；L2STATE_DEVICE_CASES 全落 state 段；
        STATE 段函数在 PRICE-TAG 段之后注册。
        HM-L2-PRODUCT-CELL（#24 只加 cell 分支）：段前准备 = L2CellRig.enterCatalog()、段后复位 = drain + L2CellRig.leaveCatalog()（同 BUTTON / PRICE-TAG
        段后复位口径）；L2CELL_DEVICE_CASES 全落 cell 段；cell 段函数在 STATE 段之后注册、恰一次。"""
        suite = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets').read_text()

        def flat(text):
            return re.sub(r'\s+', ' ', re.sub(r'//[^\n]*', '', text)).strip()

        def block(head):
            # head 在全文件恰好一处；取其后第一个 { 起的配对块体（这几段里没有含括号的字符串）。
            self.assertEqual(suite.count(head), 1, head)
            start = suite.index('{', suite.index(head) + len(head))
            depth = 0
            for k in range(start, len(suite)):
                depth += {'{': 1, '}': -1}.get(suite[k], 0)
                if depth == 0:
                    return flat(suite[start + 1:k])
            self.fail('unbalanced block: ' + head)

        # 原钩子原文：CARD 取 dfe55d2 的 Ds02L2Ui beforeAll / afterAll；BUTTON / PRICE-TAG 取 562087f 各自 describe 的 beforeAll / afterAll。
        card_before = ("await runUiTask(driver, async (): Promise<void> => { await openCard(); await click('catalog-theme-light'); "
                       "await setFont('100'); });")
        card_after = ("await drainUiTasks(driver); await runUiTask(driver, async (): Promise<void> => { const theme: Component = "
                      "await driver.findComponent(ON.id('catalog-theme-light')); if (theme !== null && theme !== undefined) { "
                      "await click('catalog-theme-light'); await setFont('100'); } });")
        rig_before = "await runUiTask(driver, async (): Promise<void> => { await %s.enterCatalog(); });"
        rig_after = ("await drainUiTasks(driver); await runUiTask(driver, async (): Promise<void> => { await %s.index(); "
                     "await %s.click('catalog-theme-light'); await %s.setFont('100'); });")
        button_before, price_before = rig_before % 'L2ButtonRig', rig_before % 'L2PriceRig'
        button_after, price_after = rig_after % (('L2ButtonRig',) * 3), rig_after % (('L2PriceRig',) * 3)
        # 集成 2：STATE 取 cfa4de9 的 Ds02L2UiState beforeAll / afterAll（助手在 namespace L2StateSegment 里，原文一字不改）。
        state_before = ("await runUiTask(driver, async (): Promise<void> => { await open('ErrorState'); await setFont('100'); "
                        "await theme('light'); });")
        state_after = ("await drainUiTasks(driver); await runUiTask(driver, async (): Promise<void> => { await open('ErrorState'); "
                       "await liveError(false); await setFont('100'); await theme('light'); });")
        state_setup_call, state_leave_call = 'await L2StateSegment.l2StateSetup();', 'await L2StateSegment.l2StateLeave();'
        # HM-L2-PRODUCT-CELL：cell 段前准备 / 段后复位（本单新写，不是挪来的旧钩子）；进出口径同 BUTTON / PRICE-TAG。
        cell_before = "await runUiTask(driver, async (): Promise<void> => { await L2CellRig.enterCatalog(); });"
        cell_after = "await drainUiTasks(driver); await runUiTask(driver, async (): Promise<void> => { await L2CellRig.leaveCatalog(); });"

        # ① it 包装：先过段边界再跑用例体；hypium 的 it 只在包装里调用一次（没有绕过包装的注册）。
        self.assertIn('import { describe, it as hypiumIt,', suite)
        self.assertEqual(len(re.findall(r'\bhypiumIt\(', suite)), 1)
        self.assertEqual(len(re.findall(r'^function it\(', suite, re.M)), 1)
        self.assertEqual(block('function it(name: string, flags: number, body: () => Promise<void>): void'),
                         'hypiumIt(name, flags, async (): Promise<void> => { await l2EnterSegment(name); await runUiTask(driver, body); });')
        # ② CARD 段前准备仍是唯一 describe 的 beforeAll；describe afterAll 只复位最后一段。
        self.assertEqual(len(re.findall(r'\bbeforeAll\(', suite)), 1)
        self.assertEqual(len(re.findall(r'\bafterAll\(', suite)), 1)
        self.assertEqual(block('    beforeAll(async (): Promise<void> =>'), card_before)
        self.assertEqual(block('    afterAll(async (): Promise<void> =>'), 'await l2FinishSegments();')
        self.assertEqual(block('async function l2SetupSegment(segment: string): Promise<void>'),
                         "if (segment === 'button') { %s } else if (segment === 'price') { %s } else if (segment === 'state') { %s }"
                         " else if (segment === 'cell') { %s }"
                         % (button_before, price_before, state_setup_call, cell_before))
        self.assertEqual(block('async function l2LeaveSegment(segment: string): Promise<void>'),
                         "if (segment === 'card') { %s } else if (segment === 'button') { %s } else if (segment === 'price') { %s }"
                         " else if (segment === 'state') { %s } else if (segment === 'cell') { %s }"
                         % (card_after, button_after, price_after, state_leave_call, cell_after))
        self.assertEqual(block('export async function l2StateSetup(): Promise<void>'), state_before)
        self.assertEqual(block('export async function l2StateLeave(): Promise<void>'), state_after)
        # ③ 段切换：上一段复位 → 本段准备 → drain；准备失败的错误本段每条都抛；describe afterAll 复位最后一段。
        enter = block('async function l2EnterSegment(name: string): Promise<void>')
        steps = ['const next: string = l2SegmentOf(name);', 'if (next !== l2Segment) {', 'const previous: string = l2Segment;',
                 'l2Segment = next;', 'l2SegmentSetupError = null;', 'await l2LeaveSegment(previous);', 'await l2SetupSegment(next);',
                 'await drainUiTasks(driver);', 'l2SegmentSetupError = e as Error;',
                 '} if (l2SegmentSetupError !== null) { throw l2SegmentSetupError; }']
        at = [enter.find(step) for step in steps]
        self.assertTrue(all(i >= 0 for i in at) and at == sorted(at), dict(zip(steps, at)))
        self.assertTrue(enter.endswith('if (l2SegmentSetupError !== null) { throw l2SegmentSetupError; }'), enter[-120:])
        self.assertIn('await l2LeaveSegment(l2Segment);', block('async function l2FinishSegments(): Promise<void>'))
        # ④ 前缀：l2SegmentOf 只认 l2button_ / l2price_，其余归 card；与各段导出常量逐条一致，段次序 card → button → price。
        seg_of = block('function l2SegmentOf(name: string): string')
        rules = re.findall(r"if \(name\.startsWith\('([a-z0-9_]+)'\)\) \{ return '([a-z]+)'; \}", seg_of)
        self.assertEqual(seg_of, ' '.join("if (name.startsWith('%s')) { return '%s'; }" % rule for rule in rules) + " return 'card';")
        self.assertEqual(rules, [('l2button_', 'button'), ('l2price_', 'price'), ('l2state_', 'state'), ('l2cell_', 'cell')])
        self.assertIn("const L2_SEGMENTS: string[] = ['card', 'button', 'price', 'state', 'cell'];", suite)
        self.assertIn('class L2CellRig {', suite)
        self.assertIn('  static async enterCatalog(): Promise<void> {', suite.split('class L2CellRig {')[1])
        self.assertIn('  static async leaveCatalog(): Promise<void> {', suite.split('class L2CellRig {')[1])

        def segment_of(name):
            return next((segment for prefix, segment in rules if name.startswith(prefix)), 'card')

        def names(const):
            return re.findall(r"'(l2[a-z]+_\d\d_[a-z0-9_]+)'", suite.split(const + ': string[] = [')[1].split('];')[0])

        for const, segment in (('L2CARD_DEVICE_CASES', 'card'), ('L2SKEL_DEVICE_CASES', 'card'),
                               ('L2BUTTON_DEVICE_CASES', 'button'), ('L2PRICE_DEVICE_CASES', 'price')):
            declared = names(const)
            self.assertTrue(declared, const)
            for name in declared:
                for mode in (['light', 'dark'] if name.endswith('_') else ['']):
                    self.assertEqual(segment_of(name + mode), segment, (const, name + mode))
        calls = [suite.index('\n    %s();\n' % fn) for fn in ('l2SkeletonDeviceCases', 'ds02L2UiButtonCases', 'ds02L2UiPriceTagCases')]
        self.assertEqual(calls, sorted(calls))
        # 集成 2：STATE 名单全落 state 段；STATE 段函数恰调用一次、排在 PRICE-TAG 之后。
        state_declared = re.findall(r"'(l2state_[a-z0-9_]+)'", suite.split('L2STATE_DEVICE_CASES: string[] = [')[1].split('];')[0])
        self.assertEqual(len(state_declared), 7)
        for name in state_declared:
            self.assertEqual(segment_of(name), 'state', name)
        self.assertEqual(suite.count('L2StateSegment.ds02L2UiStateCases();'), 1)
        self.assertGreater(suite.index('\n    L2StateSegment.ds02L2UiStateCases();\n'), calls[-1])
        # HM-L2-PRODUCT-CELL：cell 名单全落 cell 段；cell 段函数恰调用一次、排在 STATE 之后。
        cell_declared = names('L2CELL_DEVICE_CASES')
        self.assertEqual(len(cell_declared), 9)
        for name in cell_declared:
            self.assertEqual(segment_of(name), 'cell', name)
        self.assertEqual(len(re.findall(r'\bds02L2UiCellCases\(\);', suite)), 1)
        self.assertGreater(suite.index('\n    ds02L2UiCellCases();\n'), suite.index('\n    L2StateSegment.ds02L2UiStateCases();\n'))

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
