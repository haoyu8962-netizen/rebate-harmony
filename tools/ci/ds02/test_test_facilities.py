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
from check_device_result import expected_names, validate, FX25_DEVICE_CASES, LOCKHM_SEG3_FAKE_CASES


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
# HM-BATCH1-DEVFIX（D10-1279 ③）第十一步（Ds02L2Ui 单列 entry-l2）失败同样必须让 verify 失败。
if [ "$PROBE" = l2-step-fails ] && [ "${COULI_HM_DEVICE_SET:-}" = l2 ]; then exit 1; fi
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
                          'hm05r-step-fails', 'me12v-step-fails', 'me12wa-step-fails', 'me12wb-step-fails', 'me12wc-step-fails', 'tabbar-step-fails',
                          'l2-step-fails']:
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
                                      # HM-BATCH1-DEVFIX（D10-1279 ③，#24 换定位）：主步再排除 Ds02L2Ui（放在排除名单最前）。
                                      # HM-BATCH1-FREEZE 集成 1（#24 换定位）：FU-HM-A11Y-COMMON 主步再排除 HmA11yUi，叠加后放在排除名单最前。
                                      'notClass=HmA11yUi,Ds02L2Ui,LoginPhoneUi,Hm07vHomeUi,Hm07vOverlayUi,Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi|main|device-test',
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
                                      # HM-BATCH1-DEVFIX（D10-1279 ③，#24 只加）：第十一步 entry-l2，Ds02L2Ui 42 条，整步 4200 秒（实测加余量；D10-1286 ③ 由 3600 换值）。
                                      'entry_test|' + tmp + '/Staging.hap|600000|4200|class=Ds02L2Ui|l2|'
                                      'device-test-entry-l2',
                                      # FU-HM-A11Y-COMMON 测试 v1（#24 只加）：第十一步 a11y，主步再排除 HmA11yUi（放在排除名单最前）。
                                      # HM-BATCH1-FREEZE 集成 1：叠加后 entry-a11y 为第十二步，排在 entry-l2 之后。
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
                if probe == 'l2-step-fails':
                    self.assertIn('EXPECTED_FAILURE device-test entry-l2', result.stdout)
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
        # FU-HM-A11Y-FUNDS（#24 只加）：a11y 步 FUNDS 段 5 条（tools/ci/a11yfunds/device-cases.txt）进合集；343 → 348。
        # HM-BATCH1-FREEZE 集成 2（#24 只加）：a11y 步 AGENT 段 5 条（tools/ci/a11yagent/device-cases.txt）进合集；348 → 353。
        # HM-BATCH1-FREEZE 集成 3（#24 只加）：a11y 步 HOME-SEARCH 段 5 条（tools/ci/a11yhome/device-cases.txt）进合集；353 → 358。
        # LOCK-harmony 段 3（#24 只加，D10-2135 ④ / D10-2141 ④）：主步 LockHarmonySeg3Fake 15 条进合集；358 → 373。
        # LOCK-harmony C3 修（#24 只加，D10-2181 (A)）：LockHarmonySeg3Fake 15 → 16 条；373 → 374。
        # FU-HM-PHONECHANGE-B120B（#24 只加，D10-2286）：LockHarmonySeg3Fake 16 → 17 条（+ pcb_9）；374 → 375。
        self.assertEqual(len(names), 375)
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

        self.assertEqual(validate(report(names)), 375)  # HM-BATCH1-FREEZE 集成 2：348 → 353；集成 3：353 → 358；LOCK-harmony 段 3：358 → 373；C3 修：373 → 374；PHONECHANGE-B120B：374 → 375（同上）
        self.assertEqual(validate(report(names + ['future_extra_test'])), 375)
        for missing in [name for name in names if name.startswith('fx05a_') or name.startswith('hm07va_')
                        or name.startswith('hm07vb_') or name.startswith('hm05r_') or name.startswith('me12v_')
                        or name.startswith('me12wa_') or name.startswith('me12wb_') or name.startswith('me12wc_') or name.startswith('tabbar_')
                        or name.startswith('l2card_') or name.startswith('render_all_declared_states_CouliCard_')
                        or name.startswith('l2skel_')
                        or name.startswith('l2button_') or name.startswith('l2price_')
                        or name.startswith('l2state_')
                        or name.startswith('l2cell_')
                        or name in FX25_DEVICE_CASES or name in LOCKHM_SEG3_FAKE_CASES]:
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
        # HM-BATCH1-DEVFIX（D10-1279 ③，#24 换值）：Ds02L2Ui 42 条摘出主步、单列 entry-l2，main 219 → 177。
        # LOCK-harmony 段 3（#24 只加，D10-2141 ④）：LockHarmonySeg3Fake 15 条随主步跑，main 177 → 192。
        # LOCK-harmony C3 修（#24 只加，D10-2181 (A)）：LockHarmonySeg3Fake 15 → 16 条，main 192 → 193。
        # FU-HM-PHONECHANGE-B120B（#24 只加，D10-2286）：LockHarmonySeg3Fake 16 → 17 条（+ pcb_9），main 193 → 194。
        self.assertEqual(len(main), 194)
        self.assertEqual(len(l2), 42)
        # HM-L2-STATE（集成 2 换定位）：class=Ds02L2UiState 不复存在，l2state 7 条从 l2 里按前缀取（原 expected_names('l2state')）。
        l2state = {name for name in l2 if name.startswith('l2state_')}
        self.assertEqual(len(l2state), 7)
        # HM-L2-BUTTON：Ds02L2Ui 随主步跑（不新增设备步），7 条 l2button_ 只在 main，名单与套件 it() 一致（带 + mode 的按 light / dark 展开）。
        # HM-L2 批 1 集成（§收尾，换定位）：用例名原样挪进 L2BUTTON_DEVICE_CASES，按常量下标注册（同 L2SKEL），下标 0..n-1 各恰好一次。
        # HM-BATCH1-DEVFIX（D10-1279 ③，#24 换定位）：Ds02L2Ui 单列 entry-l2 后 l2button_ 只在 l2（不再在 main），从 l2 里取。
        l2button = {name for name in l2 if name.startswith('l2button_')}
        self.assertEqual(len(l2button), 7)
        l2_suite = (Path(__file__).resolve().parents[3] / 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets').read_text()
        l2_declared = re.findall(r"'(l2button_\d\d_[a-z0-9_]+)'", l2_suite.split('L2BUTTON_DEVICE_CASES: string[] = [')[1].split('];')[0])
        self.assertEqual(sorted(int(i) for i in re.findall(r"\bit\(L2BUTTON_DEVICE_CASES\[(\d+)\]", l2_suite)), list(range(len(l2_declared))))
        self.assertEqual(sorted(n + m if n.endswith('_') else n for n in l2_declared
                                for m in (['light', 'dark'] if n.endswith('_') else [''])), sorted(l2button))
        # HM-L2-PRICE-TAG：同一套件第二段，5 条 l2price_ 只在 main，名单与套件 it('l2price_…') 一致（带 + mode 的按 light / dark 展开）。
        # HM-L2 批 1 集成（§收尾，换定位）：用例名原样挪进 L2PRICE_DEVICE_CASES，按常量下标注册，下标 0..n-1 各恰好一次。
        l2price = {name for name in l2 if name.startswith('l2price_')}  # HM-BATCH1-DEVFIX：同上，换定位到 l2
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
        # FU-HM-A11Y-FUNDS（#24 只加）：COMMON 5 + FUNDS 5。
        # HM-BATCH1-FREEZE 集成 2（#24 换值）：+ AGENT 5，10 → 15。
        # HM-BATCH1-FREEZE 集成 3（#24 换值）：+ HOME-SEARCH 5，15 → 20。
        self.assertEqual(len(a11y), 20)
        # HM-BATCH1-DEVFIX（D10-1279 ③，#24 只加一项）：各步并集再并 l2（单列 entry-l2）才等于合集。
        # HM-BATCH1-FREEZE 集成 1（#24 只加一项）：并集再并 a11y（单列 entry-a11y）。
        self.assertEqual(main | hm07va | hm07vb | hm05r | me12v | me12wa | me12wb | me12wc | tabbar | loginphone | l2 | a11y, every)
        self.assertEqual(loginphone & (main | hm07va | hm07vb | hm05r | me12v | me12wa | me12wb | me12wc | tabbar | l2), set())
        # FU-HM-A11Y-COMMON（#24 只加）：a11y 与其余各步不相交。HM-BATCH1-FREEZE 集成 1（只加一项）：也与 l2 不相交。
        self.assertEqual(a11y & (main | hm07va | hm07vb | hm05r | me12v | me12wa | me12wb | me12wc | tabbar | loginphone | l2), set())
        # HM-L2-CARD（#24 只加）：l2 是主步的子集（README ⑩ 不新增设备步），与 8 个单独步不相交，名单与套件导出常量一致。
        # HM-BATCH1-DEVFIX（D10-1279 ③，#24 换值）：Ds02L2Ui 单列 entry-l2 后 l2 与主步不相交（原「l2 是主步的子集」随 ⑩ 作废）。
        self.assertEqual(l2 & main, set())
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
        self.assertEqual(l2cell & main, set())  # HM-BATCH1-DEVFIX：同上，子集 → 不相交
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
        self.assertEqual(l2state & main, set())  # HM-BATCH1-DEVFIX：同上，子集 → 不相交
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
        # LOCK-harmony 段 3（#24 只加，D10-2141 ④；照 F-X-25 写法）：名单 ⊆ main、与套件 it() 一致、每条都在 check-ui-facilities.cjs 的 FOREIGN_SUITES 里。
        self.assertEqual(set(LOCKHM_SEG3_FAKE_CASES) & main, set(LOCKHM_SEG3_FAKE_CASES))
        seg3 = (root / 'entry/src/ohosTest/ets/test/LockHarmonySeg3Fake.test.ets').read_text()
        # FU-HM-PHONECHANGE-B120B（D10-2286）：套件里另有 pcb_ 前缀的 1 条（pcb_9），取名正则只多认 pcb_ 这一个前缀。
        self.assertEqual(sorted(re.findall(r"\bit\('((?:s3f|pcb)_\d+_[a-z0-9_]+)'", seg3)), sorted(LOCKHM_SEG3_FAKE_CASES))
        for name in LOCKHM_SEG3_FAKE_CASES:
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

        self.assertEqual(validate(report(sorted(main)), 'main'), 194)  # HM-BATCH1-DEVFIX：219 → 177（换值）；LOCK-harmony 段 3：177 → 192；C3 修：192 → 193；PHONECHANGE-B120B：193 → 194
        self.assertEqual(validate(report(sorted(main) + ['future_extra_test']), 'main'), 194)
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
            # HM-BATCH1-DEVFIX（D10-1279 ③，#24 只加）：主步混进任一段的任一条 Ds02L2Ui 用例都红（notClass 失效）；主步 + l2 合报当 main 也红。
            **{'main-with-l2-case-' + name: (report(sorted(main) + [name]), 'main') for name in sorted(l2)},
            'main-plus-l2-checked-as-main': (report(sorted(main | l2)), 'main'),
            'main-plus-l2-checked-as-l2': (report(sorted(main | l2)), 'l2'),
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
        段后复位口径）；L2CELL_DEVICE_CASES 全落 cell 段；cell 段函数在 STATE 段之后注册、恰一次。
        HM-BATCH1-DEVFIX（#24 只加，编排 D10-1279 ①）：⑤ 每段结束必须回到目录索引——段切换在「复位上一段」之后、「准备本段」之前无条件
        await l2ReturnToIndex(previous)，describe afterAll 在复位最后一段之后 await l2ReturnToIndex(l2Segment)；l2ReturnToIndex 与段无关
        （无分支）、走 L2ButtonRig.index（已在索引才提前返回，否则 pressBack 后再认 catalog-index，回不去以 node('catalog-index') 断言红）；
        回索引失败不吞：记进 l2SegmentLeaveError，留到 afterAll 抛（同段后复位口径）。②里各段段后复位原文不动（只加步骤，不改原文）。"""
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
                 'l2Segment = next;', 'l2SegmentSetupError = null;', 'await l2LeaveSegment(previous);',
                 # HM-BATCH1-DEVFIX（D10-1279 ①，只加一步）：复位上一段之后、准备本段之前回目录索引。
                 'await l2ReturnToIndex(previous);', 'await l2SetupSegment(next);',
                 'await drainUiTasks(driver);', 'l2SegmentSetupError = e as Error;',
                 '} if (l2SegmentSetupError !== null) { throw l2SegmentSetupError; }']
        at = [enter.find(step) for step in steps]
        self.assertTrue(all(i >= 0 for i in at) and at == sorted(at), dict(zip(steps, at)))
        self.assertTrue(enter.endswith('if (l2SegmentSetupError !== null) { throw l2SegmentSetupError; }'), enter[-120:])
        self.assertIn('await l2LeaveSegment(l2Segment);', block('async function l2FinishSegments(): Promise<void>'))
        # ⑤ HM-BATCH1-DEVFIX（D10-1279 ①，只加）：每段结束必须回到目录索引。
        self.assertEqual(block('async function l2ReturnToIndex(segment: string): Promise<void>'),
                         "await runUiTask(driver, async (): Promise<void> => { await L2ButtonRig.index(); }); "
                         "trace('L2_SEGMENT_AT_INDEX ' + segment);")
        self.assertEqual(len(re.findall(r'\bl2ReturnToIndex\(', suite)), 3, '定义 1 + 段切换 1 + afterAll 1')
        self.assertIn('try { await l2LeaveSegment(previous); } catch (e) { trace(\'L2_SEGMENT_LEAVE_FAILED \' + previous + \' \' + String(e)); '
                      'if (l2SegmentLeaveError === null) { l2SegmentLeaveError = e as Error; } } '
                      'try { await l2ReturnToIndex(previous); } catch (e) { trace(\'L2_SEGMENT_INDEX_FAILED \' + previous + \' \' + String(e)); '
                      'if (l2SegmentLeaveError === null) { l2SegmentLeaveError = e as Error; } } '
                      'try { await l2SetupSegment(next);', enter)
        finish = block('async function l2FinishSegments(): Promise<void>')
        self.assertEqual(finish, 'const earlier: Error | null = l2SegmentLeaveError; await l2LeaveSegment(l2Segment); '
                                 'await l2ReturnToIndex(l2Segment); if (earlier !== null) { throw earlier; }')
        self.assertEqual(block('    afterAll(async (): Promise<void> =>'), 'await l2FinishSegments();')
        # L2ButtonRig.index：已在索引才提前返回；否则 pressBack 后等 catalog-index；5 轮都回不去以 node('catalog-index') 断言红。
        button_rig = suite.split('class L2ButtonRig {', 1)[1].split('\nclass ', 1)[0]
        index_head = '  static async index(): Promise<void> {'
        self.assertEqual(button_rig.count(index_head), 1)
        index_body = button_rig.split(index_head, 1)[1].split('\n  }\n', 1)[0]
        self.assertEqual(flat(index_body),
                         "for (let attempt: number = 0; attempt < 5; attempt++) { const found: Component = await driver.findComponent(ON.id('catalog-index')); "
                         "if (found !== null && found !== undefined) { return; } await driver.pressBack(); await L2ButtonRig.idle(); "
                         "const back: Component = await driver.waitForComponent(ON.id('catalog-index'), 3000); "
                         "if (back !== null && back !== undefined) { return; } } await L2ButtonRig.node('catalog-index');")
        # 每段都过 l2ReturnToIndex：非末段在段切换里（l2EnterSegment 对 L2_SEGMENTS 里任一相邻切换都走同一路径，无按段分支），
        # 末段在 afterAll；l2EnterSegment 里 l2ReturnToIndex 不在任何 if (segment === …) 分支内。
        self.assertNotIn("=== '", enter.split('await l2ReturnToIndex(previous);')[0].split('if (next !== l2Segment) {', 1)[1])
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

    def test_ds02_l2ui_each_case_runs_in_exactly_one_device_step(self):
        """HM-BATCH1-DEVFIX（#24 只加，编排 D10-1279 ③）：Ds02L2Ui 单列设备步 entry-l2，照 entry-tabbar 先例。钉住：
        ① verify.sh 实际分派的 entry 设备步里，恰有一步会跑 Ds02L2Ui 套件（class= 含它，或 notClass= / 无过滤而不排除它），
           就是 entry-l2 class=Ds02L2Ui l2，整步 4200 秒（D10-1286 ③ 由 3600 换值）、单例 600000 ms，排在设备步汇总之前（必跑、不可跳过：分派行无条件、无跳过开关）；
           主步 notClass 排除 Ds02L2Ui，主步 COULI_HM_TEST_TOTAL_TIMEOUT 仍 1800；
        ② 套件里六段导出常量声明的每条用例（带 mode 的按 light / dark 展开）恰落在一个设备步的必跑名单里、且就是跑它的 entry-l2 那步；
           不许两边都不在（l2 名单 == 套件全部用例），不许两边都在（main 不含任一条）；
        ③ device-test.sh 对 --set l2 的门槛 4200 秒（D10-1286 ③ 换值），其余步原 1800 秒门槛行仍在。"""
        root = Path(__file__).resolve().parents[3]
        verify = (root / 'tools/ci/verify.sh').read_text()
        lines = verify.splitlines()
        steps = []
        for i, line in enumerate(lines):
            if line.strip().startswith('run_device_tests entry '):
                parts = line.split()
                timeouts = dict(re.findall(r'(COULI_HM_TEST_(?:TOTAL|CASE)_TIMEOUT)=(\d+)', lines[i - 1]))
                self.assertTrue(lines[i - 1].rstrip().endswith('\\'), lines[i - 1])
                self.assertFalse(line.startswith(' ' * 5) or lines[i - 1].startswith(' '), '分派行不得包在条件 / 循环里：' + line)
                steps.append((parts[-3], parts[-2], parts[-1], timeouts, i))

        def runs_suite(flt, suite):
            if not flt:
                return True
            kind, names = flt.split('=', 1)
            return (suite in names.split(',')) == (kind == 'class')

        runners = [step for step in steps if runs_suite(step[1], 'Ds02L2Ui')]
        self.assertEqual([(label, flt, dset) for label, flt, dset, _, _ in runners], [('entry-l2', 'class=Ds02L2Ui', 'l2')])
        self.assertEqual(runners[0][3], {'COULI_HM_TEST_TOTAL_TIMEOUT': '4200', 'COULI_HM_TEST_CASE_TIMEOUT': '600000'})
        self.assertLess(runners[0][4], verify.index('if [ -n "${DEVICE_FAILED:-}" ]; then'))
        main = [step for step in steps if step[0] == 'entry']
        self.assertEqual(len(main), 1)
        self.assertEqual((main[0][2], main[0][3]['COULI_HM_TEST_TOTAL_TIMEOUT']), ('main', '1800'))
        self.assertTrue(main[0][1].startswith('notClass=') and 'Ds02L2Ui' in main[0][1].split('=', 1)[1].split(','))
        self.assertEqual(len({step[0] for step in steps}), len(steps), '步骤名不重复')

        suite = (root / 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets').read_text()
        self.assertEqual(len(re.findall(r"\bdescribe\('Ds02L2Ui',", suite)), 1)
        declared = set()
        for const in ('L2CARD_DEVICE_CASES', 'L2SKEL_DEVICE_CASES', 'L2BUTTON_DEVICE_CASES', 'L2PRICE_DEVICE_CASES',
                      'L2STATE_DEVICE_CASES', 'L2CELL_DEVICE_CASES'):
            names = re.findall(r"'(l2[a-z]+_[a-z0-9_]+)'", suite.split('export const %s: string[] = [' % const, 1)[1].split('];')[0])
            self.assertTrue(names, const)
            for name in names:
                declared.update(name + mode for mode in (['light', 'dark'] if name.endswith('_') else ['']))
        self.assertEqual(len(declared), 42)
        lists = {dset: expected_names(dset) for _, _, dset, _, _ in steps}
        self.assertEqual(lists['l2'], declared, '不许有用例两边都不在：l2 名单必须等于套件全部用例')
        for name in sorted(declared):
            homes = [label for label, _, dset, _, _ in steps if name in lists[dset]]
            self.assertEqual(homes, ['entry-l2'], name)
        # 合集里每一条都恰在一个分派步的名单里（各步两两不相交、并集 = all）。
        every = expected_names('all')
        for name in sorted(every):
            self.assertEqual(sum(name in names for names in lists.values()), 1, name)
        self.assertEqual(set().union(*lists.values()), every)
        device = (root / 'tools/ci/device-test.sh').read_text()
        gate = device.split('if [ "$MODULE" = entry_test ]; then\n    # 1800 秒门槛', 1)[1].split('\nfi\n', 1)[0]
        self.assertIn('    if [ "$DEVICE_SET" = l2 ]; then\n        [ "$elapsed_seconds" -le 4200 ] || die', gate)
        self.assertIn('    [ "$DEVICE_SET" = l2 ] || [ "$elapsed_seconds" -le 1800 ] || die', gate)
        self.assertEqual(gate.count('-le '), 2)

    def test_l2_state_live_sample_unmount_placeholder_id_not_a_tested_id(self):
        """HM-BATCH1-DEVFIX（#24 只加，编排 D10-1279 ②）：STATE 目录活样例卸载时不再用 .id('')（设备上不清旧 id，30–33 判不了「真消失」，
        HM-L2-BATCH1/device-subset/result.md §1.5 / §4.3），改用非空占位 id；占位 id 不得和任何被测 id 重名。约定（实现者照抄）：
          EmptyState：.id(this.liveEmpty ? 'catalog-live/EmptyState' : 'catalog-live-off/EmptyState')
          ErrorState：.id(this.liveError ? 'catalog-live/ErrorState' : 'catalog-live-off/ErrorState')
        钉住：① 两处三元式恰各一处、占位字面量逐字等于约定（非空、两者不同、都不以被测前缀 catalog-live/ 开头）；liveStates 里不再有空 id；
        ② 占位 id 不等于任何测试源码（entry / common / features 的 src/ohosTest、src/test 下全部 .ets）里的任一字符串字面量，
           且占位前缀 catalog-live-off/ 不出现在任何测试源码里（拼接出来的被测 id 也撞不上）；
        ③ 占位 id 在应用 / staging 源码里只出现这一处（不与其它节点 id 重名）。
        产品文件未改前本条先红（CatalogDetail.ets 两行由 STATE 实现者改，只改 staging 目录样例，不进正式包）。"""
        root = Path(__file__).resolve().parents[3]
        detail = (root / 'entry/src/staging/ets/catalog/CatalogDetail.ets').read_text()
        convention = {'EmptyState': ('liveEmpty', 'catalog-live-off/EmptyState'),
                      'ErrorState': ('liveError', 'catalog-live-off/ErrorState')}
        self.assertIn('  liveStates() {', detail)
        live = detail.split('  liveStates() {', 1)[1].split('\n  @Builder', 1)[0]
        placeholders = {}
        for component, (flag, expected) in convention.items():
            found = re.findall(r"\.id\(\s*this\.%s\s*\?\s*'catalog-live/%s'\s*:\s*'([^'\\]*)'\s*\)" % (flag, component), live)
            self.assertEqual(len(found), 1, '%s 活样例外层容器的 id 三元式应恰一处：%r' % (component, found))
            self.assertEqual(found[0], expected, '%s 卸载占位 id 应为约定的 %s，实际 %r' % (component, expected, found[0]))
            placeholders[component] = found[0]
        self.assertEqual(len(set(placeholders.values())), 2)
        for value in placeholders.values():
            self.assertTrue(value.strip() and not value.startswith('catalog-live/'), value)
        self.assertIsNone(re.search(r"\.id\([^)]*''", live), 'liveStates 里仍有空 id')
        tests = [f for top in ('entry', 'common', 'features') for f in sorted((root / top).rglob('*.ets'))
                 if ('/src/ohosTest/' in f.as_posix() or '/src/test/' in f.as_posix())
                 and not any(part in ('oh_modules', 'build', '.hvigor', 'node_modules') for part in f.parts)]
        self.assertTrue(any(f.name == 'Ds02L2Ui.test.ets' for f in tests))
        tested_ids = set()
        for f in tests:
            text = f.read_text()
            tested_ids.update(re.findall(r"'([^'\\\n]*)'", text))
            tested_ids.update(re.findall(r'"([^"\\\n]*)"', text))
            self.assertFalse('catalog-live-off/' in text, f.relative_to(root).as_posix() + ' 引用了占位前缀 catalog-live-off/')
        self.assertIn('catalog-live/EmptyState', tested_ids)
        self.assertIn('catalog-live/ErrorState', tested_ids)
        for value in placeholders.values():
            self.assertNotIn(value, tested_ids)
        app = [f for top in ('entry', 'common', 'features') for f in sorted((root / top).rglob('*.ets'))
               if '/src/ohosTest/' not in f.as_posix() and '/src/test/' not in f.as_posix()
               and not any(part in ('oh_modules', 'build', '.hvigor', 'node_modules') for part in f.parts)]
        for value in placeholders.values():
            self.assertEqual(sum(f.read_text().count("'" + value + "'") + f.read_text().count('"' + value + '"') for f in app), 1, value)

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


# FU-HM-A11Y-FUNDS（#24 只加，补复核 S1 / S3-1）：verify.sh 登记自检。a11ycommon / a11yfunds 宿主步与 wallet 本机单测
# 被摘掉（整步、某一行）、脱离 fail_fast 链、挪进条件块或函数、挪到 --fast 早退之后，都要红。放在 ds02 步里跑，
# 不靠被守的步自己守自己（摘整步时被守的守卫也一起没了）。
A11Y_HOST_STEPS = [
    ('FU-HM-A11Y-COMMON 宿主检查', [
        'python3 "$ROOT/tools/ci/a11ycommon/check_a11y_common.py" --self-test',
        'python3 "$ROOT/tools/ci/a11ycommon/check_a11y_common.py"',
        'node "$ROOT/tools/ci/a11ycommon/run-logic.cjs" --self-test',
        'node "$ROOT/tools/ci/a11ycommon/run-logic.cjs"',
        'node "$ROOT/tools/ci/a11ycommon/check-arkts.cjs"',
    ]),
    ('FU-HM-A11Y-FUNDS 宿主检查', [
        'python3 "$ROOT/tools/ci/a11yfunds/check_a11y_funds.py" --self-test',
        'python3 "$ROOT/tools/ci/a11yfunds/check_a11y_funds.py"',
        'node "$ROOT/tools/ci/a11yfunds/run-logic.cjs" --self-test',
        'node "$ROOT/tools/ci/a11yfunds/run-logic.cjs"',
        'node "$ROOT/tools/ci/a11yfunds/check-arkts.cjs"',
    ]),
    # HM-BATCH1-FREEZE 集成 2（#24 只加）：AGENT 宿主步并入同一登记自检（排在 FUNDS 之后；命令顺序同 verify.sh）。
    ('FU-HM-A11Y-AGENT 宿主检查', [
        'python3 "$ROOT/tools/ci/a11yagent/check_a11y_agent.py" --self-test',
        'python3 "$ROOT/tools/ci/a11yagent/check_a11y_agent.py"',
        'node "$ROOT/tools/ci/a11yagent/run-logic.cjs" --self-test',
        'node "$ROOT/tools/ci/a11yagent/run-logic.cjs"',
        'node "$ROOT/tools/ci/a11yagent/run-tap.cjs" --self-test',
        'node "$ROOT/tools/ci/a11yagent/run-tap.cjs"',
        'node "$ROOT/tools/ci/a11yagent/check-arkts.cjs"',
        'node "$ROOT/tools/ci/a11yagent/check-arkts.cjs" --fixtures',
    ]),
    # HM-BATCH1-FREEZE 集成 3（#24 只加）：HOME-SEARCH 宿主步并入同一登记自检（排在 AGENT 之后；命令 = a11yhome 守卫 AH6 的 HOST_CMDS，
    # 两处逐字一致由 VerifyA11yHomeMerged 钉住）。
    ('FU-HM-A11Y-HOME-SEARCH 宿主检查', [
        'python3 "$ROOT/tools/ci/a11yhome/check_a11y_home_search.py" --self-test',
        'python3 "$ROOT/tools/ci/a11yhome/check_a11y_home_search.py"',
        'node "$ROOT/tools/ci/a11yhome/run-logic.cjs" --self-test',
        'node "$ROOT/tools/ci/a11yhome/run-logic.cjs"',
        'node "$ROOT/tools/ci/a11yhome/check-arkts.cjs" --reference',
        'node "$ROOT/tools/ci/a11yhome/check-arkts.cjs" --real',
    ]),
]
WALLET_UNIT_TEST = 'run_unit_tests wallet features/wallet'
FAST_EXIT = 'if [ "$FAST" -eq 1 ]; then'


def verify_top_level(source):
    """verify.sh 的顶层命令行 [(行号, 行)]：不在函数体、if / for / while / until / case 块、heredoc 里，不是注释。
    结构对不上（块没闭合、多余闭合、heredoc 没结束）抛 ValueError（fail-closed）。"""
    lines = source.split('\n')
    out, stack, heredoc = [], [], None
    for no, line in enumerate(lines, 1):
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        if stack and stack[-1] == 'fn':
            if line == '}':
                stack.pop()
            continue
        if line[:1] in ('', ' ', '\t', '#'):
            pass
        elif re.match(r'[A-Za-z_][A-Za-z0-9_]*\(\) \{$', line):
            if stack:
                raise ValueError('第 %d 行：块里定义函数' % no)
            stack.append('fn')
            continue
        else:
            word = line.split()[0].rstrip(';')
            single = re.search(r'(;|\s)(fi|done|esac)\s*$', line)
            if word in ('if', 'for', 'while', 'until', 'case') and not single:
                stack.append({'if': 'fi', 'case': 'esac'}.get(word, 'done'))
            elif word in ('fi', 'done', 'esac'):
                if not stack or stack[-1] != word:
                    raise ValueError('第 %d 行：多余或错配的 %s' % (no, word))
                stack.pop()
            elif not stack:
                out.append((no, line))
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_]+)['\"]?\s*$", line)
        if m and not line.lstrip().startswith('#'):
            heredoc = m.group(1)
    if stack or heredoc is not None:
        raise ValueError('文件结束时块 / heredoc 未闭合：%s %s' % (stack, heredoc))
    return out


def a11y_host_registration_violations(source):
    try:
        top = verify_top_level(source)
    except ValueError as e:
        return ['R0 verify.sh 结构无法解析（fail-closed）：%s' % e]
    v = []
    lines = source.split('\n')
    fast = [no for no, line in enumerate(lines, 1) if line == FAST_EXIT]
    if len(fast) != 1:
        v.append('R0 verify.sh 应恰有一处 --fast 早退（%s），实际 %d 处' % (FAST_EXIT, len(fast)))
    fast_no = fast[0] if fast else 0
    exits = [no for no, line in top if re.match(r'(exit|return)\b', line)]
    for title, cmds in A11Y_HOST_STEPS:
        steps = [no for no, line in top if line == 'step "%s"' % title]
        records = [no for no, line in top if line.startswith('record "%s" PASS ' % title)]
        if len(steps) != 1 or len(records) != 1 or records[0] < steps[0]:
            v.append('R1 verify 顶层缺「%s」步（step / record PASS 各恰一行且 record 在后；实际 step %s record %s）'
                     % (title, steps, records))
            continue
        block = [(no, line) for no, line in top if steps[0] < no < records[0]]
        cursor = steps[0]
        for cmd in cmds:
            chain = re.compile(re.escape(cmd) + r' \|\| fail_fast "[^"]+" "[^"]*"$')
            hits = [no for no, line in block if line.split(' ||')[0].rstrip() == cmd]
            good = [no for no, line in block if chain.match(line) and no > cursor]
            if not hits:
                v.append('R2 「%s」步缺命令：%s' % (title, cmd))
            elif not good:
                v.append('R3 「%s」步命令不在 fail_fast 链上或顺序不对：%s' % (title, cmd))
            else:
                cursor = good[0]
        if fast_no and records[0] > fast_no:
            v.append('R4 「%s」步须在 --fast 早退（第 %d 行）之前，fast 模式也要跑' % (title, fast_no))
        if any(no < records[0] for no in exits):
            v.append('R4 「%s」步之前有顶层 exit / return：%s' % (title, [no for no in exits if no < records[0]]))
    order = [next((no for no, line in top if line == 'step "%s"' % t), 0) for t, _ in A11Y_HOST_STEPS]
    if all(order) and order != sorted(order):
        v.append('R1 FUNDS 宿主步须排在 COMMON 宿主步之后（集成 2：AGENT 宿主步再排在 FUNDS 之后；集成 3：HOME-SEARCH 再排在 AGENT 之后）')
    defs = [no for no, line in enumerate(lines, 1) if line == 'run_unit_tests() {']
    body = source.split('\nrun_unit_tests() {\n', 1)[1].split('\n}\n', 1)[0] if len(defs) == 1 else ''
    tail = [line.strip() for line in body.split('\n') if line.strip()][-1:]
    if len(defs) != 1 or body.count('fail_fast "test $label"') < 2 or not tail or not tail[0].startswith('fail_fast "test $label"'):
        v.append('R5 run_unit_tests 须恰定义一次，缺结果与未通过都走 fail_fast "test $label"（最后一句兜底）')
    wallet = [no for no, line in top if line.rstrip() == WALLET_UNIT_TEST]
    designsystem = [no for no, line in top if line.rstrip() == 'run_unit_tests designsystem common/designsystem']
    if len(wallet) != 1:
        v.append('R5 verify 顶层须恰一行 %s（实际 %d 行；注释掉、挂 || true、挪进条件块 / 函数都不算）' % (WALLET_UNIT_TEST, len(wallet)))
    elif not defs or wallet[0] < defs[0] or (fast_no and wallet[0] < fast_no) or not designsystem or wallet[0] < designsystem[0]:
        v.append('R5 %s 须在 run_unit_tests 定义、--fast 早退与 designsystem 单测之后（与其余本机单测同位）' % WALLET_UNIT_TEST)
    elif any(no < wallet[0] for no in exits):
        v.append('R5 %s 之前有顶层 exit / return' % WALLET_UNIT_TEST)
    return v


class VerifyA11yHostRegistration(unittest.TestCase):
    """FU-HM-A11Y-FUNDS（#24 只加）：补复核 S1（a11yfunds 宿主步 + wallet 单测）与 S3-1（a11ycommon 宿主步）的登记自检。"""

    def source(self):
        return (Path(__file__).resolve().parents[3] / 'tools/ci/verify.sh').read_text(encoding='utf-8')

    def test_verify_registers_a11y_host_steps_and_wallet_unit_test(self):
        self.assertEqual(a11y_host_registration_violations(self.source()), [])

    def test_registration_mutations_are_killed_and_benign_rewrites_pass(self):
        source = self.source()
        funds = 'python3 "$ROOT/tools/ci/a11yfunds/check_a11y_funds.py" ||'
        common = 'python3 "$ROOT/tools/ci/a11ycommon/check_a11y_common.py" ||'

        def line_of(prefix):
            hits = [line for line in source.split('\n') if line.startswith(prefix)]
            self.assertEqual(len(hits), 1, prefix)
            return hits[0] + '\n'

        def step_block(title):
            start = source.index('step "%s"\n' % title)
            end = source.index('\n', source.index('record "%s" PASS ' % title)) + 1
            return source[start:end]

        def drop(text):
            return lambda s: s.replace(text, '', 1)

        def sub(old, new):
            return lambda s: s.replace(old, new, 1)

        def move_after_fast(text):
            return lambda s: s.replace(text, '', 1).replace('\nrun_unit_tests generated common/generated\n',
                                                            '\n' + text + 'run_unit_tests generated common/generated\n', 1)

        wallet = WALLET_UNIT_TEST + '\n'
        mutations = [
            ('摘 a11yfunds 整步', drop(step_block('FU-HM-A11Y-FUNDS 宿主检查'))),
            ('只摘 a11yfunds 本体行', drop(line_of(funds))),
            ('摘 a11yfunds 自测行', drop(line_of('python3 "$ROOT/tools/ci/a11yfunds/check_a11y_funds.py" --self-test'))),
            ('摘 a11yfunds 逻辑行', drop(line_of('node "$ROOT/tools/ci/a11yfunds/run-logic.cjs" ||'))),
            ('摘 a11yfunds 逻辑自测行', drop(line_of('node "$ROOT/tools/ci/a11yfunds/run-logic.cjs" --self-test'))),
            ('摘 a11yfunds ArkTS 行', drop(line_of('node "$ROOT/tools/ci/a11yfunds/check-arkts.cjs"'))),
            ('a11yfunds 本体行注释掉', sub(line_of(funds), '# ' + line_of(funds))),
            ('a11yfunds 本体行改 || true', sub(line_of(funds), funds.replace(' ||', ' || true\n'))),
            ('a11yfunds 本体行 fail_fast 后挂 || true', sub(line_of(funds), line_of(funds).rstrip('\n') + ' || true\n')),
            ('a11yfunds 本体行挪进 if false', sub(line_of(funds), 'if false; then\n' + line_of(funds) + 'fi\n')),
            ('a11yfunds 本体行改 --help', sub(line_of(funds), line_of(funds).replace('.py" ||', '.py" --help ||'))),
            ('a11yfunds 整步挪到 --fast 早退之后', move_after_fast(step_block('FU-HM-A11Y-FUNDS 宿主检查'))),
            ('a11yfunds 步前插顶层 exit 0', sub('step "FU-HM-A11Y-FUNDS 宿主检查"\n', 'exit 0\nstep "FU-HM-A11Y-FUNDS 宿主检查"\n')),
            ('a11yfunds 步排到 a11ycommon 之前', lambda s: s.replace(step_block('FU-HM-A11Y-FUNDS 宿主检查'), '', 1).replace(
                step_block('FU-HM-A11Y-COMMON 宿主检查'), step_block('FU-HM-A11Y-FUNDS 宿主检查') + step_block('FU-HM-A11Y-COMMON 宿主检查'), 1)),
            ('摘 wallet 本机单测', drop(wallet)),
            ('wallet 单测注释掉', sub(wallet, '# ' + wallet)),
            ('wallet 单测挂 || true', sub(wallet, WALLET_UNIT_TEST + ' || true\n')),
            ('wallet 单测挪进 if 块', sub(wallet, 'if [ "$FAST" -eq 2 ]; then\n    ' + wallet + 'fi\n')),
            ('wallet 单测挪到 --fast 早退之前', lambda s: s.replace(wallet, '', 1).replace(FAST_EXIT, wallet + FAST_EXIT, 1)),
            ('run_unit_tests 失败不再 fail_fast', sub('    fail_fast "test $label"', '    record "test $label"')),
            ('摘 a11ycommon 整步', drop(step_block('FU-HM-A11Y-COMMON 宿主检查'))),
            ('只摘 a11ycommon 本体行', drop(line_of(common))),
            ('摘 a11ycommon ArkTS 行', drop(line_of('node "$ROOT/tools/ci/a11ycommon/check-arkts.cjs"'))),
            ('a11ycommon 本体行改 || true', sub(line_of(common), common.replace(' ||', ' || true\n'))),
            ('verify 块没闭合（fail-closed）', sub(FAST_EXIT + '\n', FAST_EXIT + '\nif true; then\n')),
        ]
        benign = [
            ('改 fail_fast 文案', sub('"a11yfunds-host" "见上方违反项"', '"a11yfunds-host" "见上方违反项（AF1–AF7）"')),
            ('步内加注释', sub('step "FU-HM-A11Y-FUNDS 宿主检查"\n', 'step "FU-HM-A11Y-FUNDS 宿主检查"\n# 注释\n')),
            ('wallet 单测前加空行', sub(wallet, '\n' + wallet)),
        ]
        for name, mutate in mutations:
            mutated = mutate(source)
            self.assertNotEqual(mutated, source, name)
            got = a11y_host_registration_violations(mutated)
            self.assertTrue(got, '变异「%s」没被登记自检杀' % name)
            print('KILLED verify 登记变异 %s ← %s' % (name, got[0]))
        for name, mutate in benign:
            mutated = mutate(source)
            self.assertNotEqual(mutated, source, name)
            self.assertEqual(a11y_host_registration_violations(mutated), [], '良性改写「%s」被误报' % name)
            print('BENIGN verify 登记 %s：0 违反' % name)



A11Y_STEP = ('entry-a11y', 'class=HmA11yUi', 'a11y')
DEVICE_SUMMARY = 'if [ -n "${DEVICE_FAILED:-}" ]; then'


def a11y_device_registration_violations(verify, device):
    """HM-BATCH1-FREEZE 集成 1（#24 只加）：FUNDS 登记自检扩到合并后的形态——entry-l2 与 entry-a11y 两个单列步并存时，
    entry-a11y 的设备步登记（照 DEVFIX 对 Ds02L2Ui 的「恰在一个设备步」钉法）：
    D1 verify 顶层分派的 entry 设备步里恰有一步会跑 HmA11yUi（class= 含它，或 notClass= / 无过滤而不排除它），就是 entry-a11y class=HmA11yUi a11y；
    D2 该步 COULI_HM_TEST_TOTAL_TIMEOUT=1800、COULI_HM_TEST_CASE_TIMEOUT=600000（照 COMMON 所定），排在设备步汇总之前，分派行无条件（不包在块里）；
    D3 主步恰一个（entry … main，1800 秒），notClass 同时排除 HmA11yUi 与 Ds02L2Ui；entry-l2 仍在（两单列步并存）；步骤名不重复；
    D4 device-test.sh 的 COULI_HM_DEVICE_SET case 认 a11y（复核 COMMON S3-b M8），且 a11y 不走 l2 的 4200 秒门槛。"""
    v = []
    try:
        top = {no for no, _ in verify_top_level(verify)}
    except ValueError as e:
        return ['D0 verify.sh 结构无法解析（fail-closed）：%s' % e]
    lines = verify.split('\n')
    steps = []
    for i, line in enumerate(lines):
        if line.strip().startswith('run_device_tests entry '):
            parts = line.split()
            prev = lines[i - 1] if i else ''
            timeouts = dict(re.findall(r'(COULI_HM_TEST_(?:TOTAL|CASE)_TIMEOUT)=(\d+)', prev))
            unconditional = prev.rstrip().endswith('\\') and i in top and line.startswith('    run_device_tests ') \
                and not line.startswith(' ' * 5)
            steps.append((parts[-3], parts[-2], parts[-1], timeouts, i + 1, unconditional))

    def runs_suite(flt, suite):
        if not flt.startswith(('class=', 'notClass=')):
            return True
        kind, names = flt.split('=', 1)
        return (suite in names.split(',')) == (kind == 'class')

    runners = [s for s in steps if runs_suite(s[1], 'HmA11yUi')]
    if [s[:3] for s in runners] != [A11Y_STEP]:
        v.append('D1 恰一步跑 HmA11yUi 且就是 entry-a11y class=HmA11yUi a11y（实际 %s）' % [s[:3] for s in runners])
    a11y = [s for s in steps if s[:3] == A11Y_STEP]
    summary = verify.find(DEVICE_SUMMARY)
    summary_no = verify[:summary].count('\n') + 1 if summary >= 0 else 0
    if len(a11y) != 1:
        v.append('D2 entry-a11y 分派行应恰一行（实际 %d）' % len(a11y))
    else:
        s = a11y[0]
        if s[3] != {'COULI_HM_TEST_TOTAL_TIMEOUT': '1800', 'COULI_HM_TEST_CASE_TIMEOUT': '600000'}:
            v.append('D2 entry-a11y 超时应为整步 1800 秒、单例 600000 ms（实际 %s）' % s[3])
        if not s[5]:
            v.append('D2 entry-a11y 分派行须无条件（顶层、上一行是超时续行）')
        if not summary_no or s[4] > summary_no:
            v.append('D2 entry-a11y 须排在设备步汇总（%s）之前' % DEVICE_SUMMARY)
    main = [s for s in steps if s[0] == 'entry']
    if len(main) != 1 or main[0][2] != 'main' or main[0][3].get('COULI_HM_TEST_TOTAL_TIMEOUT') != '1800' \
            or not main[0][1].startswith('notClass=') \
            or not {'HmA11yUi', 'Ds02L2Ui'} <= set(main[0][1].split('=', 1)[1].split(',')):
        v.append('D3 主步应恰一个（main、1800 秒），notClass 同时排除 HmA11yUi 与 Ds02L2Ui（实际 %s）' % [s[:4] for s in main])
    if [s[:3] for s in steps if s[0] == 'entry-l2'] != [('entry-l2', 'class=Ds02L2Ui', 'l2')]:
        v.append('D3 entry-l2 class=Ds02L2Ui l2 应恰一行（两单列步并存）')
    if len({s[0] for s in steps}) != len(steps):
        v.append('D3 设备步名重复')
    case = [line for line in device.split('\n') if line.startswith('case "$DEVICE_SET" in ')]
    if len(case) != 1 or 'a11y' not in case[0].split(' in ', 1)[1].split(')', 1)[0].split('|'):
        v.append('D4 device-test.sh 的 COULI_HM_DEVICE_SET case 须认 a11y')
    if '    if [ "$DEVICE_SET" = l2 ]; then\n' not in device or re.search(r'DEVICE_SET" = a11y', device):
        v.append('D4 a11y 不得另设门槛（走 1800 秒原行）')
    return v


class VerifyA11yDeviceRegistrationMerged(unittest.TestCase):
    """HM-BATCH1-FREEZE 集成 1（#24 只加）：FUNDS 登记自检（VerifyA11yHostRegistration）扩到合并后的形态——
    宿主段登记原样保留；另钉 entry-a11y 设备步登记与 a11y 名单（与 entry-l2 并存），补复核 COMMON S3-b 的 M8 / M9 / M10 三处缺口。"""

    root = Path(__file__).resolve().parents[3]

    def texts(self):
        return ((self.root / 'tools/ci/verify.sh').read_text(encoding='utf-8'),
                (self.root / 'tools/ci/device-test.sh').read_text(encoding='utf-8'))

    def test_real_verify_registers_entry_a11y_beside_entry_l2(self):
        verify, device = self.texts()
        self.assertEqual(a11y_device_registration_violations(verify, device), [])

    def test_a11y_names_are_common_plus_funds_and_land_only_in_entry_a11y(self):
        def cases(rel):
            return {line.strip() for line in (self.root / rel).read_text().splitlines() if line.strip() and not line.startswith('#')}
        common, funds = cases('tools/ci/a11ycommon/device-cases.txt'), cases('tools/ci/a11yfunds/device-cases.txt')
        self.assertEqual((len(common), len(funds), common & funds), (5, 5, set()))
        # HM-BATCH1-FREEZE 集成 2（#24 只加 / 换值）：AGENT 段 5 条并入，与 COMMON / FUNDS 都不相交；a11y = 三段并集（10 → 15）。
        agent = cases('tools/ci/a11yagent/device-cases.txt')
        self.assertEqual((len(agent), agent & (common | funds)), (5, set()))
        # HM-BATCH1-FREEZE 集成 3（#24 只加 / 换值）：HOME-SEARCH 段 5 条并入，与前三段都不相交；a11y = 四段并集（15 → 20）。
        home = cases('tools/ci/a11yhome/device-cases.txt')
        self.assertEqual((len(home), home & (common | funds | agent)), (5, set()))
        a11y = expected_names('a11y')
        self.assertEqual(a11y, common | funds | agent | home)
        for other in ('main', 'hm07va', 'hm07vb', 'hm05r', 'me12v', 'me12wa', 'me12wb', 'me12wc', 'tabbar', 'loginphone', 'l2'):
            self.assertEqual(expected_names(other) & a11y, set(), other)
        self.assertLessEqual(a11y, expected_names('all'))

        def report(case_names):
            events = []
            for name in case_names:
                events += ['OHOS_REPORT_STATUS: test=' + name, 'OHOS_REPORT_STATUS_CODE: 1',
                           'OHOS_REPORT_STATUS: test=' + name, 'OHOS_REPORT_STATUS_CODE: 0']
            events += [f'Tests run: {len(case_names)}, Failure: 0, Error: 0, Pass: {len(case_names)}',
                       'OHOS_REPORT_CODE: 0', 'TestFinished-ResultCode: 0']
            return '\n'.join(events)

        main = sorted(expected_names('main'))
        self.assertEqual(validate(report(sorted(a11y)), 'a11y'), 20)  # HM-BATCH1-FREEZE 集成 2：10 → 15；集成 3：15 → 20
        bad = {
            # M9：主步混进任一条 a11y 用例（套件过滤失效）即红。
            **{'main-with-a11y-' + name: (report(main + [name]), 'main') for name in sorted(a11y)},
            # M10：a11y 单独步多跑名单外用例（主步一条 / l2 一条 / 以后新增）即红。
            'a11y-with-main-case': (report(sorted(a11y) + main[:1]), 'a11y'),
            'a11y-with-l2-case': (report(sorted(a11y) + sorted(expected_names('l2'))[:1]), 'a11y'),
            'a11y-with-future-case': (report(sorted(a11y) + ['future_extra_test']), 'a11y'),
            **{'a11y-missing-' + name: (report(sorted(a11y - {name})), 'a11y') for name in sorted(a11y)},
        }
        for name, (text, set_name) in bad.items():
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    validate(text, set_name)

    def test_device_registration_mutations_are_killed(self):
        verify, device = self.texts()
        a11y_line = [line for line in verify.split('\n') if ' entry-a11y class=HmA11yUi a11y' in line]
        self.assertEqual(len(a11y_line), 1)
        a11y_line = a11y_line[0]
        a11y_head = 'COULI_HM_TEST_TOTAL_TIMEOUT=1800 COULI_HM_TEST_CASE_TIMEOUT=600000 \\\n' + a11y_line + '\n'
        self.assertEqual(verify.count(a11y_head), 1)
        main_line = [line for line in verify.split('\n') if ' entry notClass=' in line and 'run_device_tests' in line][0]
        case_line = [line for line in device.split('\n') if line.startswith('case "$DEVICE_SET" in ')][0]

        def v(old, new):
            self.assertEqual(verify.count(old), 1, old)
            return (verify.replace(old, new, 1), device)

        def d(old, new):
            self.assertEqual(device.count(old), 1, old)
            return (verify, device.replace(old, new, 1))

        mutations = [
            ('摘 entry-a11y 步', v(a11y_head, '')),
            ('entry-a11y 包进 if', v(a11y_head, 'if [ "${COULI_SKIP_A11Y:-0}" = 0 ]; then\n' + a11y_head + 'fi\n')),
            ('entry-a11y 整步超时 3600', v(a11y_head, a11y_head.replace('TOTAL_TIMEOUT=1800', 'TOTAL_TIMEOUT=3600'))),
            ('entry-a11y 单例超时放宽', v(a11y_head, a11y_head.replace('CASE_TIMEOUT=600000', 'CASE_TIMEOUT=900000'))),
            ('entry-a11y 挪到设备步汇总之后', (verify.replace(a11y_head, '', 1).replace(DEVICE_SUMMARY, DEVICE_SUMMARY + '\n' + a11y_head.rstrip('\n'), 1), device)),
            ('entry-a11y 改跑 main 名单', v(a11y_line, a11y_line.replace('HmA11yUi a11y', 'HmA11yUi main'))),
            ('entry-a11y 过滤改 notClass', v(a11y_line, a11y_line.replace('class=HmA11yUi', 'notClass=HmA11yUi'))),
            ('主步不排除 HmA11yUi', v(main_line, main_line.replace('HmA11yUi,', ''))),
            ('主步不排除 Ds02L2Ui', v(main_line, main_line.replace('Ds02L2Ui,', ''))),
            ('摘 entry-l2 步', v(' entry-l2 class=Ds02L2Ui l2\n', ' entry-l2b class=Ds02L2Ui l2\n')),
            ('多一个 entry-a11y 步', v(a11y_head, a11y_head + a11y_head)),
            ('device-test 不认 a11y', d(case_line, case_line.replace('a11y|', '', 1))),
            ('a11y 另设门槛', d('    if [ "$DEVICE_SET" = l2 ]; then\n', '    if [ "$DEVICE_SET" = a11y ]; then\n        :\n    fi\n    if [ "$DEVICE_SET" = l2 ]; then\n')),
            ('verify 块没闭合（fail-closed）', v(FAST_EXIT + '\n', FAST_EXIT + '\nif true; then\n')),
        ]
        for name, (mv, md) in mutations:
            got = a11y_device_registration_violations(mv, md)
            self.assertTrue(got, '变异「%s」没被设备步登记自检杀' % name)
            print('KILLED entry-a11y 登记变异 %s ← %s' % (name, got[0]))
        benign = [
            ('entry-a11y 前加注释', v(a11y_head, '# 注释\n' + a11y_head)),
            ('entry-l2 与 entry-a11y 对调', (verify.replace(a11y_head, '', 1).replace(
                'COULI_HM_TEST_TOTAL_TIMEOUT=4200', a11y_head + 'COULI_HM_TEST_TOTAL_TIMEOUT=4200', 1), device)),
            ('主步排除名单换序', v(main_line, main_line.replace('HmA11yUi,Ds02L2Ui,', 'Ds02L2Ui,HmA11yUi,'))),
        ]
        for name, (mv, md) in benign:
            self.assertNotEqual((mv, md), (verify, device), name)
            self.assertEqual(a11y_device_registration_violations(mv, md), [], '良性改写「%s」被误报' % name)
            print('BENIGN entry-a11y 登记 %s：0 违反' % name)


# HM-BATCH1-FREEZE 集成 2（#24 只加）：AGENT 段并进 HmA11yUi / entry-a11y 体系后的登记自检。
# 宿主步：AGENT 8 行已并入上面的 A11Y_HOST_STEPS（R1–R4 同口径），这里另做 AGENT 专属变异。
# 设备段：HmA11yUi 唯一 describe('HmA11yUi') 里 COMMON / FUNDS / AGENT 三个段函数各恰调一次、段函数从各自文件导入、
# 段文件不另起 describe；AGENT 名单 device-cases.txt = A11Y_AGENT_DEVICE_CASES（同序）= 段内 it(A11Y_AGENT_DEVICE_CASES[i]) 下标 0..n-1 各一次。
A11Y_SEGMENTS = [('a11yCommonCases', None), ('a11yFundsCases', './HmA11yFundsCases'), ('a11yAgentCases', './A11yAgentSeg')]
# HM-BATCH1-FREEZE 集成 3（#24 只加一项）：HOME-SEARCH 段同口径（S2 / S3）。
A11Y_SEGMENTS.append(('a11yHomeSearchCases', './A11yHomeSearchSeg'))


def a11y_segment_registration_violations(suite, agent_seg, agent_txt):
    v = []
    if suite.count("describe('HmA11yUi'") != 1:
        return ['S1 HmA11yUi.test.ets 应恰有一个 describe(\'HmA11yUi\')（实际 %d）' % suite.count("describe('HmA11yUi'")]
    head, body = suite.split("describe('HmA11yUi'", 1)
    depth, end = 0, None
    for i, ch in enumerate(body):
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                end = i
                break
    if end is None:
        return ['S1 describe(\'HmA11yUi\') 块没闭合（fail-closed）']
    inner = '\n'.join(line for line in body[:end].split('\n') if not line.strip().startswith('//'))
    outer = '\n'.join(line for line in (head + body[end:]).split('\n') if not line.strip().startswith('//'))
    for fn, src in A11Y_SEGMENTS:
        calls = re.findall(r'^\s*' + fn + r'\(\);\s*$', inner, re.M)
        if len(calls) != 1:
            v.append('S2 describe(\'HmA11yUi\') 里须恰调一次 %s()（实际 %d）' % (fn, len(calls)))
        if re.search(r'\b' + fn + r'\(\)', outer.replace('export function ' + fn + '()', '')):
            v.append('S2 %s() 不得在 describe(\'HmA11yUi\') 之外调用' % fn)
        if src and ("import { %s } from '%s';" % (fn, src)) not in suite:
            v.append('S3 HmA11yUi.test.ets 须 import { %s } from \'%s\'' % (fn, src))
    if 'describe(' in '\n'.join(line for line in agent_seg.split('\n') if not line.strip().startswith('//')):
        v.append('S3 A11yAgentSeg.ets 不得另起 describe（段函数只在 HmA11yUi 唯一 describe 里调用）')
    if not re.search(r'^export function a11yAgentCases\(\): void \{$', agent_seg, re.M):
        v.append('S3 A11yAgentSeg.ets 须导出 a11yAgentCases(): void')
    listed = [x.strip() for x in agent_txt.splitlines() if x.strip() and not x.startswith('#')]
    m = re.search(r"A11Y_AGENT_DEVICE_CASES: string\[\] = \[(.*?)\];", agent_seg, re.S)
    const = re.findall(r"'([^']+)'", m.group(1)) if m else []
    idx = sorted(int(i) for i in re.findall(r'\bit\(A11Y_AGENT_DEVICE_CASES\[(\d+)\]', agent_seg))
    literal = re.findall(r"\bit\('", agent_seg)
    if listed != const or len(set(listed)) != len(listed) or not all(x.startswith('a11y_agent_') for x in listed) or len(listed) != 5:
        v.append('S4 AGENT 名单不一致：device-cases.txt %s / 常量 %s（同序、a11y_agent_ 前缀、无重复、5 条）' % (listed, const))
    if idx != list(range(len(const))) or literal:
        v.append('S4 A11yAgentSeg.ets 的 it(A11Y_AGENT_DEVICE_CASES[i]) 下标须 0..%d 各恰一次、不另写字面量 it（实际 %s / 字面量 %d）'
                 % (len(const) - 1, idx, len(literal)))
    return v


class VerifyA11yAgentMerged(unittest.TestCase):
    """HM-BATCH1-FREEZE 集成 2（#24 只加）：AGENT 段并进 FUNDS 已建的 HmA11yUi / entry-a11y 体系与登记自检。"""

    root = Path(__file__).resolve().parents[3]

    def texts(self):
        t = self.root / 'entry/src/ohosTest/ets/test'
        return ((t / 'HmA11yUi.test.ets').read_text(encoding='utf-8'), (t / 'A11yAgentSeg.ets').read_text(encoding='utf-8'),
                (self.root / 'tools/ci/a11yagent/device-cases.txt').read_text(encoding='utf-8'))

    def test_real_segments_registered(self):
        self.assertEqual(a11y_segment_registration_violations(*self.texts()), [])
        # 设备步仍是 entry-a11y 一步（AGENT 不另开设备步），名单 15 条落在该步（集成 3：+ HOME-SEARCH 5 条，15 → 20）。
        verify = (self.root / 'tools/ci/verify.sh').read_text(encoding='utf-8')
        self.assertEqual(sum(1 for line in verify.split('\n') if 'run_device_tests ' in line and ' entry-a11y class=HmA11yUi a11y' in line), 1)
        self.assertEqual(len(expected_names('a11y')), 20)

    def test_segment_mutations_are_killed(self):
        suite, seg, txt = self.texts()
        call = '    a11yAgentCases();\n'
        imp = "import { a11yAgentCases } from './A11yAgentSeg';\n"
        self.assertEqual((suite.count(call), suite.count(imp)), (1, 1))
        first = re.search(r"  'a11y_agent_01_[a-z0-9_]+',\n", seg).group(0)
        it1 = 'it(A11Y_AGENT_DEVICE_CASES[1],'

        def s(old, new):
            self.assertEqual(suite.count(old), 1, old)
            return (suite.replace(old, new, 1), seg, txt)

        def g(old, new):
            self.assertEqual(seg.count(old), 1, old)
            return (suite, seg.replace(old, new, 1), txt)

        mutations = [
            ('摘 a11yAgentCases() 调用', s(call, '')),
            ('a11yAgentCases() 注释掉', s(call, '    // a11yAgentCases();\n')),
            ('a11yAgentCases() 调两次', s(call, call + call)),
            ('a11yAgentCases() 挪到 describe 之外', (suite.replace(call, '', 1).replace(
                'export default function hmA11yUiTest() {\n', 'export default function hmA11yUiTest() {\n  a11yAgentCases();\n', 1), seg, txt)),
            ('摘 a11yFundsCases() 调用', s('    a11yFundsCases();\n', '')),
            ('摘 a11yCommonCases() 调用', s('    a11yCommonCases();\n', '')),
            ('摘 AGENT import', s(imp, '')),
            ('段文件另起 describe', g('export function a11yAgentCases(): void {\n',
                                     "export function a11yAgentCases(): void {\n  describe('A11yAgent', () => {});\n")),
            ('名单少一条', (suite, seg, txt.replace(first.strip().strip("',") + '\n', '', 1))),
            ('常量多一条', g(first, first + "  'a11y_agent_06_extra',\n")),
            ('it 下标重复', g(it1, 'it(A11Y_AGENT_DEVICE_CASES[0],')),
            ('段内另写字面量 it', g(it1, "it('a11y_agent_extra', 0, async (): Promise<void> => {});\n  " + it1)),
            ('HmA11yUi 多一个 describe', s("describe('HmA11yUi'", "describe('HmA11yUi', () => {});\n  describe('HmA11yUi'")),
        ]
        for name, (ms, mg, mt) in mutations:
            self.assertNotEqual((ms, mg, mt), (suite, seg, txt), name)
            got = a11y_segment_registration_violations(ms, mg, mt)
            self.assertTrue(got, '变异「%s」没被段登记自检杀' % name)
            print('KILLED a11y 段登记变异 %s ← %s' % (name, got[0]))
        benign = [
            ('AGENT 段调用前加注释', s(call, '    // 注释\n' + call)),
            ('FUNDS 与 AGENT 段调用对调', (suite.replace('    a11yFundsCases();\n', '@@F@@', 1).replace(
                call, '    a11yFundsCases();\n', 1).replace('@@F@@', call, 1), seg, txt)),
        ]
        for name, (ms, mg, mt) in benign:
            self.assertNotEqual((ms, mg, mt), (suite, seg, txt), name)
            self.assertEqual(a11y_segment_registration_violations(ms, mg, mt), [], '良性改写「%s」被误报' % name)
            print('BENIGN a11y 段登记 %s：0 违反' % name)

    def test_agent_host_step_mutations_are_killed(self):
        source = (self.root / 'tools/ci/verify.sh').read_text(encoding='utf-8')
        start = source.index('step "FU-HM-A11Y-AGENT 宿主检查"\n')
        end = source.index('\n', source.index('record "FU-HM-A11Y-AGENT 宿主检查" PASS ')) + 1
        block = source[start:end]
        funds = source[source.index('step "FU-HM-A11Y-FUNDS 宿主检查"\n'):
                       source.index('\n', source.index('record "FU-HM-A11Y-FUNDS 宿主检查" PASS ')) + 1]
        body = 'python3 "$ROOT/tools/ci/a11yagent/check_a11y_agent.py" ||'
        tap = 'node "$ROOT/tools/ci/a11yagent/run-tap.cjs" ||'

        def line_of(prefix):
            hits = [line for line in source.split('\n') if line.startswith(prefix)]
            self.assertEqual(len(hits), 1, prefix)
            return hits[0] + '\n'

        def sub(old, new):
            self.assertEqual(source.count(old), 1, old)
            return source.replace(old, new, 1)

        mutations = [
            ('摘 a11yagent 整步', sub(block, '')),
            ('只摘 a11yagent 本体行', sub(line_of(body), '')),
            ('摘 a11yagent 自测行', sub(line_of('python3 "$ROOT/tools/ci/a11yagent/check_a11y_agent.py" --self-test'), '')),
            ('摘 run-tap 本体行', sub(line_of(tap), '')),
            ('摘 run-tap 自测行', sub(line_of('node "$ROOT/tools/ci/a11yagent/run-tap.cjs" --self-test'), '')),
            ('摘 ArkTS 参照件行', sub(line_of('node "$ROOT/tools/ci/a11yagent/check-arkts.cjs" --fixtures'), '')),
            ('a11yagent 本体行改 || true', sub(line_of(body), body.replace(' ||', ' || true\n'))),
            ('run-tap 本体行挪进 if false', sub(line_of(tap), 'if false; then\n' + line_of(tap) + 'fi\n')),
            ('a11yagent 整步挪到 --fast 早退之后', source.replace(block, '', 1).replace(
                '\nrun_unit_tests generated common/generated\n', '\n' + block + 'run_unit_tests generated common/generated\n', 1)),
            ('a11yagent 步排到 a11yfunds 之前', source.replace(block, '', 1).replace(funds, block + funds, 1)),
        ]
        for name, mutated in mutations:
            self.assertNotEqual(mutated, source, name)
            got = a11y_host_registration_violations(mutated)
            self.assertTrue(got, '变异「%s」没被登记自检杀' % name)
            print('KILLED a11yagent 宿主登记变异 %s ← %s' % (name, got[0]))


# HM-BATCH1-FREEZE 集成 3（#24 只加）：HOME-SEARCH 并进 FUNDS / AGENT 已建的登记自检体系（不另立一套、不删 a11yhome 的 AH6）。
# 宿主步：HOME 6 行已并入上面的 A11Y_HOST_STEPS（R1–R4 同口径）；段调用：A11Y_SEGMENTS 已加 HOME 一项（S2 / S3 同口径）。
# 这里另做：① 在 ds02 步里直接执行 a11yhome 守卫的 AH6 登记判定（verify 宿主步 / core List 登记 A11yHomeNotice / entry HmA11yUi 段），
# 摘掉 HOME 宿主步时 AH6 仍由 ds02 步执行（补 a11yhome swap §登记自检「局限」）；② AH6 的 HOST_CMDS 与 A11Y_HOST_STEPS 的 HOME 项逐字一致，
# 两处不得各改各的；③ HOME 名单 device-cases.txt = A11Y_HS_DEVICE_CASES（同序、a11y_hs_ 前缀、无重复、5 条）= 段内字面量 it('…') 各恰一次；
# ④ HOME 专属变异（宿主步 / 段调用 / 名单）全杀。
A11Y_HOME_TITLE = 'FU-HM-A11Y-HOME-SEARCH 宿主检查'


def load_a11yhome_guard():
    """按路径加载 a11yhome 守卫（不写 __pycache__）。"""
    import importlib.util
    import sys
    path = Path(__file__).resolve().parents[1] / 'a11yhome/check_a11y_home_search.py'
    old = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location('couli_a11yhome_guard_for_ds02', path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = old
    return mod


def a11y_home_segment_violations(home_seg, home_txt):
    v = []
    code = '\n'.join(line for line in re.sub(r'/\*.*?\*/', '', home_seg, flags=re.S).split('\n') if not line.strip().startswith('//'))
    if re.search(r'\bdescribe\s*\(', code):
        v.append('S3 A11yHomeSearchSeg.ets 不得另起 describe（段函数只在 HmA11yUi 唯一 describe 里调用）')
    if len(re.findall(r'^export function a11yHomeSearchCases\(\): void \{$', home_seg, re.M)) != 1:
        v.append('S3 A11yHomeSearchSeg.ets 须恰导出一个 a11yHomeSearchCases(): void')
    listed = [x.strip() for x in home_txt.splitlines() if x.strip() and not x.startswith('#')]
    m = re.search(r"A11Y_HS_DEVICE_CASES: string\[\] = \[(.*?)\];", home_seg, re.S)
    const = re.findall(r"'([^']+)'", m.group(1)) if m else []
    if listed != const or len(set(listed)) != len(listed) or not all(x.startswith('a11y_hs_') for x in listed) or len(listed) != 5:
        v.append('S4 HOME 名单不一致：device-cases.txt %s / 常量 %s（同序、a11y_hs_ 前缀、无重复、5 条）' % (listed, const))
    its = re.findall(r"^\s*it\('([^']+)'", code, re.M)
    other = re.findall(r"^\s*(?:hypiumIt|it)\((?!')", code, re.M)
    if sorted(its) != sorted(const) or len(set(its)) != len(its):
        v.append('S4 A11yHomeSearchSeg.ets 的 it(\'…\') 须与常量逐条各恰一次（实际 %s）' % its)
    if len(other) != 1:
        v.append('S4 A11yHomeSearchSeg.ets 除包装函数里一处 hypiumIt(name, …) 外不得另起非字面量 it（实际 %d）' % len(other))
    return v


class VerifyA11yHomeMerged(unittest.TestCase):
    """HM-BATCH1-FREEZE 集成 3（#24 只加）：HOME-SEARCH 段 / 宿主步并进 FUNDS / AGENT 已建的 HmA11yUi / entry-a11y 体系与登记自检。"""

    root = Path(__file__).resolve().parents[3]

    def texts(self):
        t = self.root / 'entry/src/ohosTest/ets/test'
        return ((t / 'HmA11yUi.test.ets').read_text(encoding='utf-8'), (t / 'A11yHomeSearchSeg.ets').read_text(encoding='utf-8'),
                (self.root / 'tools/ci/a11yhome/device-cases.txt').read_text(encoding='utf-8'),
                (t / 'A11yAgentSeg.ets').read_text(encoding='utf-8'), (self.root / 'tools/ci/a11yagent/device-cases.txt').read_text(encoding='utf-8'))

    def violations(self, suite, home_seg, home_txt, agent_seg, agent_txt):
        return a11y_segment_registration_violations(suite, agent_seg, agent_txt) + a11y_home_segment_violations(home_seg, home_txt)

    def test_real_home_registered_and_ah6_runs_from_ds02(self):
        self.assertEqual(self.violations(*self.texts()), [])
        guard = load_a11yhome_guard()
        # ② 两处宿主命令表逐字一致（AH6 的 HOST_CMDS 与 ds02 的 A11Y_HOST_STEPS HOME 项）。
        self.assertEqual(list(guard.HOST_CMDS), dict(A11Y_HOST_STEPS)[A11Y_HOME_TITLE])
        self.assertEqual(guard.HOST_STEP, A11Y_HOME_TITLE)
        # ① AH6 在 ds02 步里执行：真实登记 0 违反，且已是集成形态（HmA11yUi 在，不再输出「待集成」说明）。
        got, notes = guard.registration(str(self.root))
        self.assertEqual(got, [])
        self.assertEqual(notes, [])
        self.assertEqual(len(expected_names('a11y')), 20)

    def test_home_segment_mutations_are_killed(self):
        suite, seg, txt, aseg, atxt = self.texts()
        call = '    a11yHomeSearchCases();\n'
        imp = "import { a11yHomeSearchCases } from './A11yHomeSearchSeg';\n"
        self.assertEqual((suite.count(call), suite.count(imp)), (1, 1))
        first = re.search(r"  'a11y_hs_01_[a-z0-9_]+',\n", seg).group(0)
        it1 = "it('a11y_hs_02_"

        def s(old, new):
            self.assertEqual(suite.count(old), 1, old)
            return (suite.replace(old, new, 1), seg, txt, aseg, atxt)

        def g(old, new):
            self.assertEqual(seg.count(old), 1, old)
            return (suite, seg.replace(old, new, 1), txt, aseg, atxt)

        mutations = [
            ('摘 a11yHomeSearchCases() 调用', s(call, '')),
            ('a11yHomeSearchCases() 注释掉', s(call, '    // a11yHomeSearchCases();\n')),
            ('a11yHomeSearchCases() 调两次', s(call, call + call)),
            ('a11yHomeSearchCases() 挪到 describe 之外', (suite.replace(call, '', 1).replace(
                'export default function hmA11yUiTest() {\n', 'export default function hmA11yUiTest() {\n  a11yHomeSearchCases();\n', 1),
                seg, txt, aseg, atxt)),
            ('摘 HOME import', s(imp, '')),
            ('段文件另起 describe', g('export function a11yHomeSearchCases(): void {\n',
                                     "export function a11yHomeSearchCases(): void {\n  describe('A11yHome', () => {});\n")),
            ('名单少一条', (suite, seg, txt.replace(first.strip().strip("',") + '\n', '', 1), aseg, atxt)),
            ('常量多一条', g(first, first + "  'a11y_hs_06_extra',\n")),
            ('it 名重复', g(it1, "it('a11y_hs_01_home_popup_focus_on_close_when_shown', 0, async () => {});\n  " + it1)),
            ('段内另起非字面量 it', g(it1, "it(A11Y_HS_DEVICE_CASES[0], 0, async () => {});\n  " + it1)),
            ('名单换序', (suite, seg, txt.replace(first.strip().strip("',") + '\n', '', 1) + first.strip().strip("',") + '\n', aseg, atxt)),
        ]
        for name, args in mutations:
            self.assertNotEqual(args, (suite, seg, txt, aseg, atxt), name)
            got = self.violations(*args)
            self.assertTrue(got, '变异「%s」没被段登记自检杀' % name)
            print('KILLED a11y HOME 段登记变异 %s ← %s' % (name, got[0]))
        benign = [
            ('HOME 段调用前加注释', s(call, '    // 注释\n' + call)),
            ('HOME 段调用挪到 COMMON 段之后（乙补丁原位）', (suite.replace(call, '', 1).replace(
                '    a11yCommonCases();\n', '    a11yCommonCases();\n' + call, 1), seg, txt, aseg, atxt)),
        ]
        for name, args in benign:
            self.assertNotEqual(args, (suite, seg, txt, aseg, atxt), name)
            self.assertEqual(self.violations(*args), [], '良性改写「%s」被误报' % name)
            print('BENIGN a11y HOME 段登记 %s：0 违反' % name)

    def test_home_host_step_mutations_are_killed(self):
        source = (self.root / 'tools/ci/verify.sh').read_text(encoding='utf-8')
        start = source.index('step "%s"\n' % A11Y_HOME_TITLE)
        end = source.index('\n', source.index('record "%s" PASS ' % A11Y_HOME_TITLE)) + 1
        block = source[start:end]
        agent = source[source.index('step "FU-HM-A11Y-AGENT 宿主检查"\n'):
                       source.index('\n', source.index('record "FU-HM-A11Y-AGENT 宿主检查" PASS ')) + 1]
        body = 'python3 "$ROOT/tools/ci/a11yhome/check_a11y_home_search.py" ||'
        real = 'node "$ROOT/tools/ci/a11yhome/check-arkts.cjs" --real ||'

        def line_of(prefix):
            hits = [line for line in source.split('\n') if line.startswith(prefix)]
            self.assertEqual(len(hits), 1, prefix)
            return hits[0] + '\n'

        def sub(old, new):
            self.assertEqual(source.count(old), 1, old)
            return source.replace(old, new, 1)

        mutations = [
            ('摘 a11yhome 整步', sub(block, '')),
            ('只摘 a11yhome 本体行', sub(line_of(body), '')),
            ('摘 a11yhome 自测行', sub(line_of('python3 "$ROOT/tools/ci/a11yhome/check_a11y_home_search.py" --self-test'), '')),
            ('摘 a11yhome 逻辑行', sub(line_of('node "$ROOT/tools/ci/a11yhome/run-logic.cjs" ||'), '')),
            ('摘 ArkTS --real 行', sub(line_of(real), '')),
            ('摘 ArkTS --reference 行', sub(line_of('node "$ROOT/tools/ci/a11yhome/check-arkts.cjs" --reference'), '')),
            ('a11yhome 本体行改 || true', sub(line_of(body), body.replace(' ||', ' || true\n'))),
            ('a11yhome 本体行挪进 if false', sub(line_of(body), 'if false; then\n' + line_of(body) + 'fi\n')),
            ('a11yhome 整步挪到 --fast 早退之后', source.replace(block, '', 1).replace(
                '\nrun_unit_tests generated common/generated\n', '\n' + block + 'run_unit_tests generated common/generated\n', 1)),
            ('a11yhome 步排到 a11yagent 之前', source.replace(block, '', 1).replace(agent, block + agent, 1)),
        ]
        for name, mutated in mutations:
            self.assertNotEqual(mutated, source, name)
            got = a11y_host_registration_violations(mutated)
            self.assertTrue(got, '变异「%s」没被登记自检杀' % name)
            print('KILLED a11yhome 宿主登记变异 %s ← %s' % (name, got[0]))

if __name__ == '__main__':
    unittest.main(verbosity=2)
