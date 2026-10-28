#!/usr/bin/env python3
"""F-X-25 设备测试接线自测：执行 verify 的真实函数；模拟构建/设备端口，不算设备通过。"""
from pathlib import Path
import json
import re
import tempfile
import unittest
import os
import subprocess


class DeviceWiring(unittest.TestCase):
    def test_verify_dispatches_hap_and_har_and_requires_device_execution(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / 'tools/ci/verify.sh').read_text()
        function = source.split('run_device_tests() {', 1)[1].split('\nrun_device_tests core ', 1)[0]
        entry_dispatch = source.split('COULI_HM_TEST_TOTAL_TIMEOUT=', 1)[1].split('\n\n', 1)[0]
        entry_dispatch = 'COULI_HM_TEST_TOTAL_TIMEOUT=' + entry_dispatch
        with tempfile.TemporaryDirectory(prefix='fx25-dispatch-') as tmp:
            folder = Path(tmp)
            (folder / 'tools/ci').mkdir(parents=True)
            device = folder / 'tools/ci/device-test.sh'
            device.write_text('''#!/bin/bash
set -eu
[ -f "$1" ]
printf '%s\\n' "$2|$4|${COULI_HM_TEST_CASE_TIMEOUT:-}|${COULI_HM_TEST_TOTAL_TIMEOUT:-}" >> "$ROOT/device-receipts"
if [ "$PROBE" = "$2-device-fails" ]; then exit 1; fi
if [ "$PROBE" = "$2-no-report" ]; then exit 0; fi
echo 'DEVICE_TEST_PASS simulated_only'
''')
            device.chmod(0o755)
            # t2：entry 测试包构建前后的「与被测应用同源」（tools/ci/ohostest-app-source.cjs）：假 node 只记回执，按探针失败。
            (folder / 'bin').mkdir()
            fake_node = folder / 'bin/node'
            fake_node.write_text('''#!/bin/bash
set -eu
case "$1" in */tools/ci/ohostest-app-source.cjs) ;; *) exit 9 ;; esac
printf 'same-source|%s|%s|%s\\n' "$2" "${4:-}" "${5:-}" >> "$ROOT/build-receipts"
if [ "$PROBE" = "entry-same-source-$2-fails" ]; then exit 1; fi
exit 0
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
    if [ "$PROBE" = "$module-build-fails" ]; then return 1; fi
    if [ "$PROBE" != "$module-missing-hap" ]; then
        touch "$BUILD_DIR/$dir/build/$product/outputs/ohosTest/$module-ohosTest-unsigned.hap"
    fi
    if [ "$PROBE" != "$module-missing-compile" ]; then echo "Finished :$module:ohosTest@OhosTestCompileArkTS"; fi
}
run_device_tests() {''' + function + '''
run_device_tests core common/core core_test
''' + entry_dispatch + '\n')
            for probe in ['ok'] + [module + '-' + failure for module in ['core', 'entry']
                                  for failure in ['missing-hap', 'missing-compile', 'build-fails']] + [
                                  module + '-' + failure for module in ['core_test', 'entry_test']
                                  for failure in ['device-fails', 'no-report']] + [
                                  'entry-same-source-' + step + '-fails' for step in ['apply', 'restore', 'check']]:
                for receipt in ['build-receipts', 'device-receipts']:
                    (folder / receipt).unlink(missing_ok=True)
                result = subprocess.run(['bash', str(script), tmp, probe], capture_output=True, text=True,
                                        env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
                self.assertEqual(result.returncode, 0 if probe == 'ok' else 1, result.stdout + result.stderr)
                if probe == 'ok':
                    # core 自己的测试包不装应用，不做同源；entry：先换源 → 构建 → 立刻还原 → 核对测试包同源。
                    self.assertEqual((folder / 'build-receipts').read_text().splitlines(),
                                     ['core|genOnDeviceTestHap|default', 'same-source|apply|staging|entry',
                                      'entry|assembleHap|staging', 'same-source|restore||', 'same-source|check|staging|entry'])
                    # HM-07v-a（D10-405 D4）起 entry 分两步（main / hm07va）、同一测试包只构建一次（上面 build 回执仍只有一次），
                    # 两步都装同一 Staging 应用、各自 1800 秒（测试 v3 同步本自测的期望；构建 / 同源回执不变）。
                    self.assertEqual((folder / 'device-receipts').read_text().splitlines(),
                                     ['core_test|||'] + ['entry_test|' + tmp + '/Staging.hap|600000|1800'] * 2)  # D10-232
                if probe == 'entry-build-fails':
                    # 构建失败也要先还原构建镜像的模块配置，再报失败；不核对、不上设备。
                    self.assertEqual((folder / 'build-receipts').read_text().splitlines()[-2:],
                                     ['entry|assembleHap|staging', 'same-source|restore||'])
                if probe.startswith('entry-same-source-'):
                    self.assertFalse((folder / 'device-receipts').exists()
                                     and 'entry_test' in (folder / 'device-receipts').read_text(), probe)
                print('REFERENCE_ONLY verify dispatch: ' + probe)



class NamedRouteWiring(unittest.TestCase):
    """pages 档由 DS-02 固定后，F-X-25 测试页改走命名路由；只查接线，不算设备通过。"""

    def test_fx25_page_is_named_route_loaded_by_its_own_ability(self):
        root = Path(__file__).resolve().parents[2]
        test_root = root / 'entry/src/ohosTest'
        module = json.loads((test_root / 'module.json5').read_text())['module']
        self.assertEqual(module['pages'], '$profile:ds02_test_pages')
        pages = json.loads((test_root / 'resources/base/profile/ds02_test_pages.json').read_text())['src']
        self.assertNotIn('pages/Fx25WebPage', pages)
        self.assertFalse((test_root / 'resources/base/profile/fx25_pages.json').exists())
        abilities = {ability['name']: ability for ability in module['abilities']}
        ability = abilities['Fx25TestAbility']
        self.assertFalse(ability['exported'])
        self.assertEqual(ability['srcEntry'], './ets/testability/Fx25TestAbility.ets')
        page = (test_root / 'ets/pages/Fx25WebPage.ets').read_text()
        self.assertEqual(re.findall(r'^export const FX25_WEB_ROUTE: string = \'(\w+)\';$', page, re.M), ['Fx25WebPage'])
        self.assertEqual(re.findall(r'^@Entry\b.*$', page, re.M), ['@Entry({ routeName: FX25_WEB_ROUTE })'])
        self.assertIn('@ComponentV2', page)
        source = (test_root / 'ets/testability/Fx25TestAbility.ets').read_text()
        # 静态导入页面模块（导入即注册命名路由），用同一常量加载，失败有日志；不走路径加载、不动态导入。
        self.assertIn("import { FX25_WEB_ROUTE } from '../pages/Fx25WebPage';", source)
        self.assertIn('stage.loadContentByName(FX25_WEB_ROUTE).catch(', source)
        self.assertNotIn('loadContent(', source)
        self.assertNotIn("import('", source)
        others = [path for path in (test_root / 'ets').rglob('*.ets') if path.name != 'Fx25WebPage.ets'
                  and re.search(r"routeName:\s*(FX25_WEB_ROUTE|'Fx25WebPage')", path.read_text())]
        self.assertEqual(others, [])
        device = (test_root / 'ets/test/AuthChangeDevice.test.ets').read_text()
        self.assertGreaterEqual(device.count("abilityName: 'Fx25TestAbility'"), 1)
        print('REFERENCE_ONLY named route wiring: pages profile untouched, Fx25WebPage via routeName constant')


def strip_comments(source: str) -> str:
    """去掉 ETS / TS 的 // 行注释与 /* */ 块注释（字符串、模板字符串里的不动）。t1（R3-04 (3)）：一致性检查先去注释再匹配，
    同一行只出现在注释里不算接上了。"""
    out = []
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        if c in '\'"`':
            j = i + 1
            while j < n and source[j] != c:
                j += 2 if source[j] == '\\' else 1
            out.append(source[i:j + 1])
            i = j + 1
        elif source.startswith('//', i):
            j = source.find('\n', i)
            i = n if j < 0 else j
        elif source.startswith('/*', i):
            j = source.find('*/', i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def auth_wiring_problems(app: str, wiring: str) -> list:
    """AppBridge 的切号接线（trustedAuth 里的 client.* 订阅、wireAuth 成功分支的 config.* 赋值、TrustedAuthSync 的构造参数）
    必须在 ohosTest 的 Fx25AuthWiring 里逐条原样出现；返回缺了哪些。t1：两边都先去注释。"""
    app, wiring = strip_comments(app), strip_comments(wiring)
    flat = lambda text: re.sub(r'\s+', ' ', text)
    problems = []
    trusted = app.split('static trustedAuth(', 1)[1].split('\n  }\n', 1)[0]
    wired = app.split('const sync: TrustedAuthSync = auth;', 1)[1].split('\n  }\n', 1)[0]
    lines = re.findall(r'^\s*(client\.\w+\(.*\);)$', trusted, re.M) + re.findall(r'^\s*(config\.\w+ = .*;)$', wired, re.M)
    if len(lines) < 5:
        problems.append('AppBridge wiring extractor found only %d statements; adapt the check' % len(lines))
    problems += ['missing: ' + line for line in lines if line not in wiring]
    made = re.findall(r'new TrustedAuthSync\((.*?)\);', flat(trusted))
    copied = re.findall(r'new TrustedAuthSync\((.*?)\);', flat(wiring))
    if len(made) != 1 or len(copied) != 1:
        problems.append('expected one TrustedAuthSync construction on each side')
    else:
        want = [a.strip() for a in made[0].split(', new TrustedWebProfile(), ')]
        if want != ['(): SessionIdentity => client.sessionIdentity(epochs)', 'journal, ownerRecord']:
            problems.append('AppBridge TrustedAuthSync construction changed: ' + made[0])
        # t1：替身把归属记录当参数透传（调用方按生产选：注入标记存储 → null；生产沙盒标记 → 沙盒归属记录，见 E05）。
        if copied[0] != want[0] + ', new TrustedWebProfile(), pending, owner':
            problems.append('Fx25AuthWiring TrustedAuthSync construction differs: ' + copied[0])
    return problems


class DeviceAuthWiring(unittest.TestCase):
    """v7：entry 测试包里的 F-X-25 文件不得引 entry/src/main 或 staging 源码（测试包按 :core:default 编译，staging 变体要的
    调试导出不存在，见 Fx25AuthWiring 文件头）；替身接线必须与 AppBridge 逐条一致。只查源码，不算设备通过。"""

    def test_fx25_device_files_do_not_import_entry_sources_and_wiring_matches_app_bridge(self):
        root = Path(__file__).resolve().parents[2]
        test_root = root / 'entry/src/ohosTest/ets'
        fx25 = [path for path in test_root.rglob('*.ets') if path.name.startswith('Fx25') or path.name == 'AuthChangeDevice.test.ets']
        self.assertGreaterEqual(len(fx25), 7)
        for path in fx25:
            imports = re.findall(r"^import .* from '([^']+)';$", path.read_text(), re.M)
            bad = [i for i in imports if '/main/' in i or '/staging/' in i or i.startswith('entry/')]
            self.assertEqual(bad, [], path.name)
        app = (root / 'entry/src/main/ets/web/AppBridge.ets').read_text()
        wiring = (test_root / 'test/Fx25AuthWiring.ets').read_text()
        self.assertEqual(auth_wiring_problems(app, wiring), [])
        # 反例：替身少一条订阅、生产多一条订阅、构造参数不同，都必须报出来。
        guard = 'client.guardSessionSave((account: string | null): boolean => sync.admit(account));'
        self.assertIn(guard, wiring)
        self.assertNotEqual(auth_wiring_problems(app, wiring.replace(guard, '')), [])
        extra = app.replace(guard, guard + '\n    client.watchSomethingNew((): void => sync.retry());', 1)
        self.assertNotEqual(auth_wiring_problems(extra, wiring), [])
        self.assertNotEqual(auth_wiring_problems(app, wiring.replace('new TrustedWebProfile(), pending, owner', 'new TrustedWebProfile(), pending')), [])
        # t1 反例（R3-04 (3)）：替身里那一行只剩在注释里，必须报缺。
        self.assertNotEqual(auth_wiring_problems(app, wiring.replace(guard, '// ' + guard)), [])
        self.assertNotEqual(auth_wiring_problems(app, wiring.replace(guard, '/* ' + guard + ' */')), [])
        # 生产上注入标记存储时没有归属记录：E01 / E02 / E04 / E06 的替身调用都显式传 null；E05 用生产沙盒的两样（与 pending === null 同组合）。
        rigs = {path.name: strip_comments(path.read_text()) for path in (test_root / 'test').glob('Fx25*Rig.ets')}
        for name in ['Fx25DeviceRig.ets', 'Fx25CookieRig.ets', 'Fx25CoverRig.ets', 'Fx25CacheRig.ets', 'Fx25BeaconRig.ets']:
            self.assertIn('pending, null);', rigs[name], name)
        owner = rigs['Fx25OwnerRig.ets']
        self.assertIn('new FileTrustedAuthJournal(FileSlot.at(filesDir,', owner)
        self.assertIn('new FileTrustedWebOwnerRecord(FileSlot.at(filesDir,', owner)
        self.assertIn('this.journal, this.record);', owner)
        print('REFERENCE_ONLY device auth wiring: no entry/src/main import, Fx25AuthWiring == AppBridge wiring (5 negatives killed, comments stripped)')


class TeardownHostWiring(unittest.TestCase):
    """t1（plan-teardown 附表 A / 风险 3）：被压页要能「延期」，宿主 NavDestination 的 onShown / onHidden 必须接到
    TrustedWebConfig.hostVisible；可信容器与宿主页不得开 freezeWhenInactive（冻结的页面收不到卸下 / 挂上信号）。只查源码。"""

    def test_host_pages_report_visibility_and_never_freeze(self):
        root = Path(__file__).resolve().parents[2]
        host = strip_comments((root / 'entry/src/main/ets/web/WebPages.ets').read_text())
        web = strip_comments((root / 'features/web/src/main/ets/TrustedWebView.ets').read_text())
        fixture = strip_comments((root / 'entry/src/ohosTest/ets/pages/Fx25WebPage.ets').read_text())
        problems = []
        for name, text in [('WebPages.ets', host), ('TrustedWebView.ets', web), ('Fx25WebPage.ets', fixture)]:
            if 'freezeWhenInactive' in text:
                problems.append(name + ': freezeWhenInactive is forbidden for trusted containers and their hosts')
        trusted_hosts = host.count('TrustedWebView({')
        if trusted_hosts < 1:
            problems.append('WebPages.ets: no TrustedWebView host found; adapt the check')
        for event, value in [('onShown', 'true'), ('onHidden', 'false')]:
            # 回调体可以换行：从 .onShown( / .onHidden( 起，到链上下一个「换行 + 缩进 + .」为止，里面要有 hostVisible(值)。
            wired = sum(1 for m in re.finditer(r'\.' + event + r'\(', host)
                        if 'hostVisible(' + value + ')' in re.split(r'\n\s*\.(?=[a-zA-Z])', host[m.end():], maxsplit=1)[0])
            if wired < trusted_hosts:
                problems.append('WebPages.ets: NavDestination hosting TrustedWebView must call config.hostVisible(%s) in %s (%d/%d)'
                                % (value, event, wired, trusted_hosts))
        self.assertEqual(problems, [])
        print('REFERENCE_ONLY teardown host wiring: hostVisible on onShown/onHidden, no freezeWhenInactive')


class SameSourceHelper(unittest.TestCase):
    """t2：tools/ci/ohostest-app-source.cjs 的换源 / 还原 / 同源核对（临时小工程 + 假测试包；不算设备通过）。"""

    def test_apply_restore_and_check_same_source(self):
        import zipfile
        root = Path(__file__).resolve().parents[2]
        helper = str(root / 'tools/ci/ohostest-app-source.cjs')
        node = os.path.join(os.environ.get('DEVECO_HOME', '/Applications/DevEco-Studio.app/Contents'), 'tools/node/bin/node')
        with tempfile.TemporaryDirectory(prefix='fx25-same-source-') as tmp:
            build = Path(tmp)
            (build / 'build-profile.json5').write_text('''{ // 根配置
  "modules": [
    { "name": "entry", "srcPath": "./entry", "targets": [{ "name": "default" }, { "name": "staging" }] },
    { "name": "core", "srcPath": "./common/core", "targets": [{ "name": "default" }, { "name": "staging" }] },
    { "name": "designsystem", "srcPath": "./common/designsystem", "targets": [{ "name": "default" }] }
  ]
}''')
            profile = '''{
  // default = Release
  "targets": [
    { "name": "default", "source": { "sourceRoots": ["./src/release"] } },
    { "name": "staging", "source": { "sourceRoots": ["./src/staging"] } },
    { "name": "ohosTest", "source": { "sourceRoots": ["./src/release"] } }
  ]
}
'''
            for module in ['entry', 'common/core', 'common/designsystem']:
                (build / module / 'src/staging').mkdir(parents=True)
                (build / module / 'build-profile.json5').write_text(profile)

            def run(*args):
                return subprocess.run([node, helper] + list(args), capture_output=True, text=True)

            applied = run('apply', tmp, 'staging', 'entry')
            self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
            core = (build / 'common/core/build-profile.json5').read_text()
            default = json.loads(core)['targets'][0]
            self.assertEqual(default['name'], 'default')
            self.assertEqual(default['source']['sourceRoots'], ['./src/staging'])
            # 测试模块自己（entry）和没有 staging target 的模块不动。
            self.assertEqual((build / 'entry/build-profile.json5').read_text(), profile)
            self.assertEqual((build / 'common/designsystem/build-profile.json5').read_text(), profile)
            # 重复 apply 从原文件出发（先还原上次的备份），不会把备份覆盖成已改过的内容。
            self.assertEqual(run('apply', tmp, 'staging', 'entry').returncode, 0)
            self.assertEqual((build / 'common/core/build-profile.json5.ohostest-orig').read_text(), profile)
            self.assertEqual(run('restore', tmp).returncode, 0)
            self.assertEqual((build / 'common/core/build-profile.json5').read_text(), profile)
            self.assertFalse((build / 'common/core/build-profile.json5.ohostest-orig').exists())

            def hap(name, abc):
                path = build / name
                with zipfile.ZipFile(path, 'w') as z:
                    z.writestr('ets/modules.abc', abc)
                return str(path)
            good = hap('good.hap', b'\x00&core/src/staging/ets/config/DebugOnly&\x00&core/src/main/ets/X&1.0.0\x00')
            self.assertEqual(run('check', tmp, 'staging', 'entry', good).returncode, 0)
            mixed = hap('mixed.hap', b'&core/src/staging/ets/A&\x00&core/src/release/ets/config/DebugOnly&')
            self.assertEqual(run('check', tmp, 'staging', 'entry', mixed).returncode, 1)
            release = hap('release.hap', b'&core/src/main/ets/X&1.0.0\x00&core/src/release/ets/config/DebugOnly&')
            self.assertEqual(run('check', tmp, 'staging', 'entry', release).returncode, 1)
            no_variant = hap('none.hap', b'&core/src/main/ets/X&1.0.0')
            self.assertEqual(run('check', tmp, 'staging', 'entry', no_variant).returncode, 1)
            # 还没还原就核对：拒绝。
            self.assertEqual(run('apply', tmp, 'staging', 'entry').returncode, 0)
            self.assertEqual(run('check', tmp, 'staging', 'entry', good).returncode, 1)
            self.assertEqual(run('restore', tmp).returncode, 0)
            self.assertEqual(run('bogus').returncode, 2)
            print('REFERENCE_ONLY same-source helper: apply / restore / check (3 negatives rejected)')


if __name__ == '__main__':
    unittest.main(verbosity=2)
