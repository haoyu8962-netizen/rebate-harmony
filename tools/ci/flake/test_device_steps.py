#!/usr/bin/env python3
"""FU-HM-DEVICE-FLAKE 宿主自测：verify.sh 设备步「跑完再汇总」与 rerun-device-step.sh（D10-642）。

执行 verify.sh 里真实的 run_device_tests / run_device_test_hap / device_step_failed 与分派段、真实的 rerun-device-step.sh；
构建与设备都是替身，只证明调度语义，不算设备通过。
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
STEPS = ['entry', 'entry-hm07va', 'entry-hm07vb', 'entry-hm05r', 'entry-me12v', 'entry-me12wa', 'entry-me12wb', 'entry-me12wc']
SETS = ['main', 'hm07va', 'hm07vb', 'hm05r', 'me12v', 'me12wa', 'me12wb', 'me12wc']

FAKE_DEVICE = '''#!/bin/bash
set -eu
[ -f "$1" ]
printf '%s\\n' "$2|${COULI_HM_DEVICE_SET:-}|${COULI_HM_TEST_FILTER:-}|${COULI_HM_TEST_TOTAL_TIMEOUT:-}" >> "$RECEIPTS"
for s in ${FAIL_SETS:-}; do
  if [ "$s" = "${COULI_HM_DEVICE_SET:-}" ]; then echo "  FAIL some_case"; exit 1; fi
done
if [ "${NO_DEVICE:-}" = 1 ]; then echo "device-test：没有已连接的鸿蒙设备 / 模拟器（hdc list targets 无 Connected 目标）" >&2; exit 1; fi
if [ "${NO_DEVICE:-}" = lost ]; then echo "device-test：设备 127.0.0.1:5555 不响应（hdc shell 失败：[Fail][E001005] Device not found or connected）" >&2; exit 1; fi
if [ "${NO_DEVICE:-}" = lostboot ]; then echo "device-test：设备 127.0.0.1:5555 失联：不响应（hdc shell 失败：[Fail][E001005] Device not found or connected）" >&2; exit 1; fi
if [ "${NO_DEVICE:-}" = boot ]; then echo "device-test：设备 127.0.0.1:5555 在 300 秒内没有开机完成（bootevent.boot.completed≠true）" >&2; exit 1; fi
if [ "${NO_REPORT_SET:-}" = "${COULI_HM_DEVICE_SET:-}" ]; then exit 0; fi
echo "FLAKE_TRACE self_heal=0 capture_retake=0 capture_invalid=0 ds02_container_gone=0（只打印，不参与判定；hilog 计数为下限）"
echo "DEVICE_TEST_PASS set=${COULI_HM_DEVICE_SET:-} simulated_only"
'''


class DeviceStepsRunAll(unittest.TestCase):
    def harness(self, tmp: Path) -> Path:
        source = (ROOT / 'tools/ci/verify.sh').read_text()
        function = source.split('run_device_tests() {', 1)[1].split('\nrun_device_tests core ', 1)[0]
        dispatch = 'COULI_HM_TEST_TOTAL_TIMEOUT=' + source.split('COULI_HM_TEST_TOTAL_TIMEOUT=', 1)[1].split('\n\n', 1)[0]
        self.assertIn('DEVICE_STEPS_FAILED', dispatch, '汇总判定必须紧跟在设备步分派后面')
        (tmp / 'tools/ci').mkdir(parents=True)
        device = tmp / 'tools/ci/device-test.sh'
        device.write_text(FAKE_DEVICE)
        device.chmod(0o755)
        (tmp / 'bin').mkdir()
        node = tmp / 'bin/node'
        node.write_text('#!/bin/bash\nexit 0\n')
        node.chmod(0o755)
        script = tmp / 'probe.sh'
        script.write_text('''#!/bin/bash
set -euo pipefail
ROOT="$1"
BUILD_DIR="$ROOT"; OUT_DIR="$ROOT"; LOG_DIR="$ROOT"; HVIGORW=fake_hvigor; NODE_BIN="$ROOT/bin"; API_COMPAT_PATTERN=unreachable
if [ -n "${KEEP_BUILD:-}" ]; then
    BUILD_DIR="$KEEP_BUILD"; OUT_DIR="$KEEP_BUILD/.verify-out"; mkdir -p "$OUT_DIR"
    [ -f "$OUT_DIR/Staging.hap" ] || printf 'app-%s' "$RANDOM$RANDOM" > "$OUT_DIR/Staging.hap"
fi
step() { :; }
record() { echo "RECORD|$1|$2"; }
show_matches() { :; }
api_compat_hits() { return 1; }
fail_fast() { echo "EXPECTED_FAILURE $*"; exit 1; }
fake_hvigor() {
    local args="$*" module product dir
    case "$args" in
        *module=entry@ohosTest*) module=entry; product=staging; dir=entry ;;
        *module=core@ohosTest*) module=core; product=default; dir=common/core ;;
        *) return 1 ;;
    esac
    mkdir -p "$BUILD_DIR/$dir/build/$product/outputs/ohosTest"
    printf 'test-%s-%s' "$module" "${KEEP_BUILD:+$RANDOM$RANDOM}" > "$BUILD_DIR/$dir/build/$product/outputs/ohosTest/$module-ohosTest-unsigned.hap"
    echo "Finished :$module:ohosTest@OhosTestCompileArkTS"
}
run_device_tests() {''' + function + '''
run_device_tests core common/core core_test
''' + dispatch + '''
echo ALL_GREEN
''')
        return script

    def run_probe(self, env: dict, keep: Path = None) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory(prefix='flake-steps-') as name:
            tmp = Path(name)
            script = self.harness(tmp)
            receipts = tmp / 'receipts'
            if keep is not None:
                # 端到端（评审 r2 S2-B）：测试包 / 应用包放在调用方给的构建目录里，跑完包仍在，stdout 即「首跑 verify 日志」。
                env = {**env, 'KEEP_BUILD': str(keep)}
            result = subprocess.run(['bash', str(script), name], capture_output=True, text=True, errors='replace',
                                    env={**os.environ, 'RECEIPTS': str(receipts), **env})
            result.receipts = receipts.read_text().splitlines() if receipts.exists() else []
            return result

    def test_all_green(self):
        r = self.run_probe({})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('ALL_GREEN', r.stdout)
        self.assertEqual([x.split('|')[1] for x in r.receipts], ['all'] + SETS)
        self.assertNotIn('DEVICE_STEPS_FAILED', r.stdout)
        # 评审 r1 S1-1：每个设备步开跑前打印两包 sha256（core 无应用包记 none）。
        shas = [l for l in r.stdout.splitlines() if l.startswith('DEVICE_HAP_SHA256 step=')]
        self.assertEqual([l.split()[1] for l in shas], ['step=core'] + ['step=' + x for x in STEPS])
        self.assertTrue(shas[0].split()[2] == 'app=none' and all(len(l.split()[3]) == len('test=') + 64 for l in shas))
        # 评审 r2 S2-A：每步的设施留痕计数进汇总（INFO，只打印）。
        self.assertEqual(r.stdout.count('RECORD|flake-trace '), 9)
        self.assertIn('RECORD|flake-trace entry-hm07va|INFO', r.stdout)

    def test_one_red_step_does_not_stop_later_steps(self):
        for i, s in enumerate(SETS):
            r = self.run_probe({'FAIL_SETS': s})
            self.assertEqual(r.returncode, 1, s)
            self.assertNotIn('ALL_GREEN', r.stdout)
            # 红步之后的设备步仍全部跑过（D10-642 ①「其余设备步都已通过」可在同一轮核对）。
            self.assertEqual([x.split('|')[1] for x in r.receipts], ['all'] + SETS, s)
            self.assertIn('DEVICE_STEPS_FAILED ' + STEPS[i] + '\n', r.stdout)
            self.assertIn('EXPECTED_FAILURE device-test ' + STEPS[i] + ' ', r.stdout)
            self.assertIn('RECORD|device-test ' + STEPS[i] + '|FAIL', r.stdout)
            for j, other in enumerate(STEPS):
                if j != i:
                    self.assertIn('RECORD|device-test ' + other + '|PASS', r.stdout)
        print('REFERENCE_ONLY run-all: each of 8 entry steps red alone -> other 7 still run and PASS, overall exit 1')

    def test_several_red_and_core_red(self):
        r = self.run_probe({'FAIL_SETS': 'all hm07va me12wb'})
        self.assertEqual(r.returncode, 1)
        self.assertEqual(len(r.receipts), 9)
        self.assertIn('DEVICE_STEPS_FAILED core entry-hm07va entry-me12wb\n', r.stdout)

    def test_missing_pass_line_is_red(self):
        r = self.run_probe({'NO_REPORT_SET': 'me12v'})
        self.assertEqual(r.returncode, 1)
        self.assertIn('DEVICE_STEPS_FAILED entry-me12v\n', r.stdout)
        self.assertEqual(len(r.receipts), 9)

    def test_no_device_fails_fast(self):
        for kind in ['1', 'lost', 'lostboot', 'boot']:
            r = self.run_probe({'NO_DEVICE': kind})
            self.assertEqual(r.returncode, 1, kind)
            self.assertEqual(len(r.receipts), 1, '没有设备 / 失联 / 开机未完成时第一步即停：' + kind)
            self.assertIn('设备不可用', r.stdout)

    def test_end_to_end_real_verify_output_feeds_rerun(self):
        """评审 r2 S2-B：verify.sh 真实的分派 / sha 打印代码跑出的日志，直接喂给真实的复跑脚本。"""
        with tempfile.TemporaryDirectory(prefix='flake-e2e-') as name:
            t = Path(name)
            build = t / 'build'
            r = self.run_probe({'FAIL_SETS': 'hm07vb'}, keep=build)
            self.assertEqual(r.returncode, 1)
            log = t / 'verify.log'
            log.write_text(r.stdout)
            repo = t / 'repo'
            (repo / 'tools/ci').mkdir(parents=True)
            shutil.copy(ROOT / 'tools/ci/verify.sh', repo / 'tools/ci/verify.sh')
            shutil.copy(ROOT / 'tools/ci/rerun-device-step.sh', repo / 'tools/ci/rerun-device-step.sh')
            (repo / 'tools/ci/device-test.sh').write_text(FAKE_DEVICE)
            (repo / 'tools/ci/device-test.sh').chmod(0o755)
            env = {**os.environ, 'RECEIPTS': str(t / 'rr'), 'COULI_HM_BUILD_DIR': str(build)}
            run = lambda: subprocess.run(['bash', str(repo / 'tools/ci/rerun-device-step.sh'), 'entry-hm07vb', str(log)],
                                         capture_output=True, text=True, errors='replace', env=env)
            ok = run()
            self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
            self.assertIn('RERUN_PASS step=entry-hm07vb attempt=1（第 1 次复跑）same_package=yes', ok.stdout)
            # 改包（模拟后来又构建了一次）后，用同一份真实首跑日志必须拒跑。
            (build / 'entry/build/staging/outputs/ohosTest/entry-ohosTest-unsigned.hap').write_text('rebuilt')
            bad = run()
            self.assertEqual(bad.returncode, 1)
            self.assertIn('same_package=no test', bad.stdout)
        print('REFERENCE_ONLY e2e: real verify DEVICE_HAP_SHA256 / DEVICE_STEPS_FAILED lines accepted by rerun; rebuilt package refused')

    def test_device_test_prints_flake_trace_without_judging(self):
        src = (ROOT / 'tools/ci/device-test.sh').read_text()
        clear, aa = src.index('hs hilog -r'), src.index('shell aa test -b')
        trace, verdict = src.index('echo "FLAKE_TRACE self_heal='), src.index('die "aa test 退出码')
        self.assertLess(clear, aa)
        self.assertLess(aa, trace)
        self.assertLess(trace, verdict)
        block = src[src.index('TRACE="$WORK/flake-trace.log"'):trace]
        self.assertNotIn('die ', block, '留痕只打印、不判定')
        self.assertNotIn('exit', block)
        # v5（评审 r4 S2-1）：Ds02Ui beforeAll 的吸收留痕也抓进来并计数。
        self.assertIn('DS02_BEFOREALL_TRAIL', src[src.index('hs "hilog -x"'):trace])
        self.assertIn('ds02_container_gone=${ds02_gone:-0}', src[trace:verdict])

    def test_release_scan_runs_before_device_steps(self):
        source = (ROOT / 'tools/ci/verify.sh').read_text()
        scan = source.index('step "release-scan：Release 必须不命中"')
        device = source.index('\nrun_device_tests core ')
        verdict = source.index('DEVICE_STEPS_FAILED')
        self.assertLess(scan, device)
        self.assertLess(device, verdict)
        self.assertLess(verdict, source.rindex('echo "结果：通过"'))


class RerunDeviceStep(unittest.TestCase):
    """评审 r1 S1-1：复跑必须带首跑日志，核只红一步、同一个安装包、每份日志每步只一次。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='flake-rerun-')
        t = Path(self.tmp.name)
        self.repo = t / 'repo'
        (self.repo / 'tools/ci').mkdir(parents=True)
        shutil.copy(ROOT / 'tools/ci/verify.sh', self.repo / 'tools/ci/verify.sh')
        shutil.copy(ROOT / 'tools/ci/rerun-device-step.sh', self.repo / 'tools/ci/rerun-device-step.sh')
        (self.repo / 'tools/ci/device-test.sh').write_text(FAKE_DEVICE)
        (self.repo / 'tools/ci/device-test.sh').chmod(0o755)
        self.build = t / 'build'
        (self.build / '.verify-out').mkdir(parents=True)
        self.app = self.build / '.verify-out/Staging.hap'
        self.app.write_text('app')
        self.hap = self.build / 'entry/build/staging/outputs/ohosTest/entry-ohosTest-unsigned.hap'
        self.hap.parent.mkdir(parents=True)
        self.hap.write_text('test')
        self.receipts = t / 'receipts'
        self.t = t

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def sha(p: Path) -> str:
        import hashlib
        return hashlib.sha256(p.read_bytes()).hexdigest()

    def first_log(self, red, app=None, test=None, name='first.log') -> Path:
        lines = ['==> 设备测试']
        for step in STEPS:
            lines.append('DEVICE_HAP_SHA256 step=%s app=%s test=%s' % (step, app or self.sha(self.app), test or self.sha(self.hap)))
        if red is not None:
            lines.append('DEVICE_STEPS_FAILED' + ''.join(' ' + r for r in red))
        log = self.t / name
        log.write_text('\n'.join(lines) + '\n')
        return log

    def rerun(self, step, log, **env):
        self.receipts.unlink(missing_ok=True)
        return subprocess.run(['bash', str(self.repo / 'tools/ci/rerun-device-step.sh'), step, str(log)], capture_output=True, text=True,
                              errors='replace', env={**os.environ, 'RECEIPTS': str(self.receipts), 'COULI_HM_BUILD_DIR': str(self.build), **env})

    def ran(self) -> bool:
        return self.receipts.exists()

    def test_reads_filter_and_set_from_verify_and_marks_first_attempt(self):
        verify = (ROOT / 'tools/ci/verify.sh').read_text()
        for step, s in zip(STEPS, SETS):
            log = self.first_log([step], name=step + '.log')
            r = self.rerun(step, log)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('RERUN_PASS step=' + step + ' attempt=1（第 1 次复跑）same_package=yes', r.stdout)
            module, dset, flt, total = self.receipts.read_text().splitlines()[0].split('|')
            self.assertEqual((module, dset, total), ('entry_test', s, '1800'))
            self.assertIn(' ' + step + ' ' + flt + ' ' + s + '\n', verify)
            marks = list((self.build / '.verify-out/rerun-marks').glob(step + '-*'))
            self.assertEqual(len(marks), 1)
            self.assertFalse(Path(str(log) + '.rerun-' + step).exists(), '标记不放在日志旁')
        print('REFERENCE_ONLY rerun: 8 steps, filter/set from verify.sh, first attempt marked in $OUT_DIR/rerun-marks by step + package sha')

    def test_second_rerun_refused_even_after_red(self):
        log = self.first_log(['entry-hm07va'])
        r = self.rerun('entry-hm07va', log, FAIL_SETS='hm07va')
        self.assertEqual(r.returncode, 1)
        self.assertIn('RERUN_FAIL step=entry-hm07va attempt=1（第 1 次复跑）', r.stdout)
        r = self.rerun('entry-hm07va', log)
        self.assertEqual(r.returncode, 1)
        self.assertIn('RERUN_REFUSED step=entry-hm07va attempt=2', r.stdout)
        self.assertFalse(self.ran(), '第二次复跑不得上设备')
        print('REFERENCE_ONLY rerun: second rerun of same step / same first-run log refused (no device run)')

    def test_copy_rename_symlink_log_cannot_reset_count(self):
        """评审 r2 S1-1'：次数按「步骤 + 两包 sha」记，与日志路径无关。"""
        log = self.first_log(['entry-hm07va'])
        r = self.rerun('entry-hm07va', log)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        first_rerun_log = [l for l in r.stdout.splitlines() if l.startswith('  日志 ')][0]
        copy = self.t / 'copy.log'
        shutil.copy(log, copy)
        renamed = self.t / 'archive' / 'verify-r9.log'
        renamed.parent.mkdir()
        shutil.move(str(log), renamed)
        link = self.t / 'link.log'
        link.symlink_to(copy)
        for other in [copy, renamed, link]:
            r = self.rerun('entry-hm07va', other)
            self.assertEqual(r.returncode, 1, other)
            self.assertIn('RERUN_REFUSED step=entry-hm07va attempt=2', r.stdout)
            self.assertIn(first_rerun_log.split('；')[0].replace('  日志 ', ''), r.stdout, '拒跑行列出之前那次复跑的日志')
            self.assertFalse(self.ran(), '不得上设备')
        print('REFERENCE_ONLY rerun: copied / renamed / symlinked first-run log refused (attempt=2), previous rerun log listed')

    def test_new_verify_with_new_package_allows_first_rerun_same_log_path(self):
        log = self.first_log(['entry-me12v'])
        self.assertEqual(self.rerun('entry-me12v', log).returncode, 0)
        # 新一轮 verify：包重建（sha 变），同一路径日志被覆盖。
        self.app.write_text('app-round-2')
        self.hap.write_text('test-round-2')
        log = self.first_log(['entry-me12v'])
        r = self.rerun('entry-me12v', log)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('attempt=1（第 1 次复跑）', r.stdout)
        self.assertEqual(len(list((self.build / '.verify-out/rerun-marks').glob('entry-me12v-*'))), 2)
        print('REFERENCE_ONLY rerun: new verify round (new packages, same log path) -> first rerun allowed')

    def test_package_mismatch_refused(self):
        for which in ['app', 'test']:
            log = self.first_log(['entry-me12v'], **{which: 'f' * 64}, name=which + '.log')
            r = self.rerun('entry-me12v', log)
            self.assertEqual(r.returncode, 1, which)
            self.assertIn('RERUN_REFUSED step=entry-me12v same_package=no ' + which, r.stdout)
            self.assertFalse(self.ran())
            self.assertFalse((self.build / '.verify-out/rerun-marks').exists(), '拒跑不占用复跑次数')
        log = self.first_log(['entry-me12v'], name='gone.log')
        self.hap.unlink()
        r = self.rerun('entry-me12v', log)
        self.assertEqual(r.returncode, 1)
        self.assertIn('same_package=no', r.stdout)
        self.assertFalse(self.ran())
        print('REFERENCE_ONLY rerun: app / test sha256 differ from first run, or package gone -> refused')

    def test_multiple_or_other_or_no_red_refused(self):
        cases = [(['entry-hm07va', 'entry-me12v'], 'first_run_red=2 steps'), (['core', 'entry-me12v'], 'first_run_red=2 steps'),
                 (['entry-me12wb'], 'first_run_red=entry-me12wb'), (None, 'first_run_red=none')]
        for n, (red, want) in enumerate(cases):
            log = self.first_log(red, name='m%d.log' % n)
            r = self.rerun('entry-me12v', log)
            self.assertEqual(r.returncode, 1, red)
            self.assertIn('RERUN_REFUSED step=entry-me12v ' + want, r.stdout)
            self.assertFalse(self.ran())
        log = self.t / 'nosha.log'
        log.write_text('DEVICE_STEPS_FAILED entry-me12v\n')
        r = self.rerun('entry-me12v', log)
        self.assertIn('same_package=unknown', r.stdout)
        self.assertFalse(self.ran())
        print('REFERENCE_ONLY rerun: >1 red / other step red / no red / no sha line -> refused')

    def test_usage_errors(self):
        log = self.first_log(['entry'])
        for args in [['entry-nope', str(log)], ['core', str(log)], ['../x', str(log)], ['entry'], ['entry', str(self.t / 'none.log')]]:
            r = subprocess.run(['bash', str(self.repo / 'tools/ci/rerun-device-step.sh'), *args], capture_output=True, text=True,
                               errors='replace', env={**os.environ, 'RECEIPTS': str(self.receipts), 'COULI_HM_BUILD_DIR': str(self.build)})
            self.assertEqual(r.returncode, 2, args)

    def test_verify_prints_hap_sha_before_each_device_step(self):
        source = (ROOT / 'tools/ci/verify.sh').read_text()
        body = source.split('run_device_test_hap() {', 1)[1].split('\n}\n', 1)[0]
        self.assertLess(body.index('echo "DEVICE_HAP_SHA256 step=$label app=$app_sha test=$test_sha"'), body.index('/tools/ci/device-test.sh'))


if __name__ == '__main__':
    unittest.main()
