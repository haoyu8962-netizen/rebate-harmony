#!/usr/bin/env python3
"""TOKENS-PIPE-harmony 测试作者 v1：错误实现矩阵（brief-harmony §4-7，至少 11 类，每类至少 1 个变异体，全部要被杀）。

在「已实现的仓库」的临时副本里逐个植入错误实现，跑本单的离线检查，记下谁打红。只读原仓库，不调 hvigor、不连设备。
  检查：pipe = tools/ci/tokens/check_tokens_pipe.py；unit = tools/codegen/test_tokens.py GeneratorUnit RealRepo；
        logic = tools/ci/tokens/run-logic.cjs（含设备测试离线演练）；gencheck = tools/codegen/gen.py --check；lint = tools/ci/lint.py
变异分两种：
  生成器源码变异：按「语义锚点」改 gen.py / gen_theme.py / ds02_test_data.py（正则找颜色校验、换位、num、来源路径），改完不重跑生成器
    （看测试能否直接拦住错误生成器），锚点没找到记 NOT_APPLIED（实现写法不同，评审照实现改锚点，不算通过）；
  生成物 / 产品变异：直接改 DesignTokens.ets、CouliThemeTokens.ets、资源、CouliMetrics、设备测试（与实现写法无关）。
用法：
  python3 tools/ci/tokens/mutants.py [--root <已实现的仓库>] [--only 名字,…] [--skip-lint]
退出码：全部变异体已植入且每个至少被一项检查打红 → 0；否则 1。实现前跑没有意义（基线本身就红，脚本会先跑基线并拒绝）。
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DT = 'common/generated/src/main/ets/DesignTokens.ets'
TT = 'common/designsystem/src/main/ets/theme/CouliThemeTokens.ets'
DS_DARK = 'common/designsystem/src/main/resources/dark/element/color.json'
DS_BASE = 'common/designsystem/src/main/resources/base/element/color.json'
ENTRY_BASE = 'entry/src/main/resources/base/element/color.json'
METRICS = 'common/designsystem/src/main/ets/CouliMetrics.ets'
DEVICE = 'entry/src/ohosTest/ets/test/Ds02ResourcesDevice.test.ets'
SNAP = 'contracts/snapshot/design/design-tokens.json'

CHECKS = {
    'pipe': ['python3', 'tools/ci/tokens/check_tokens_pipe.py'],
    'unit': ['python3', 'tools/codegen/test_tokens.py', 'GeneratorUnit', 'RealRepo'],
    'logic': ['node', 'tools/ci/tokens/run-logic.cjs'],
    'gencheck': ['python3', 'tools/codegen/gen.py', '--check'],
    'lint': ['python3', 'tools/ci/lint.py'],
}


class NotApplied(Exception):
    pass


def edit(rel, fn):
    def apply(root):
        p = Path(root) / rel
        if not p.is_file():
            raise NotApplied('缺 ' + rel)
        old = p.read_text(encoding='utf-8')
        new = fn(old)
        if new == old:
            raise NotApplied(rel + ' 锚点没找到')
        p.write_text(new, encoding='utf-8')
    return apply


def regex(rel, pattern, repl, count=0, flags=0):
    return edit(rel, lambda s: re.sub(pattern, repl, s, count=count, flags=flags))


def literal(rel, old, new, count=1):
    return edit(rel, lambda s: s.replace(old, new, count) if old in s else s)


def json_rows(rel, fn):
    def change(text):
        data = json.loads(text)
        fn(data['color'])
        return json.dumps(data, indent=2, ensure_ascii=False) + '\n'
    return edit(rel, change)


def set_row(name, value):
    def fn(rows):
        for r in rows:
            if r['name'] == name:
                r['value'] = value
    return fn


def chain(*steps):
    def apply(root):
        for step in steps:
            step(root)
    return apply


def write(rel, data_fn):
    def apply(root):
        p = Path(root) / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data_fn(root))
    return apply


def snapshot_bytes(root):
    return (Path(root) / SNAP).read_bytes()


SNAP_LITERALS = r'''(os\.path\.join\(\s*["']contracts["']\s*,\s*["']snapshot["']\s*,\s*["']design["']\s*,\s*["']design-tokens\.json["']\s*\)|["']contracts/snapshot/design/design-tokens\.json["'])'''

# (类别, 名字, 变异)
MUTANTS = [
    ('①gen.py 仍只认 6 位', 'gen-six-digit-only', regex('tools/codegen/gen.py', r'\{6\}\(\?:\[0-9A-Fa-f\]\{2\}\)\?', '{6}')),
    ('②DesignTokens 存成 ARGB', 'design-tokens-argb', regex(DT, r"'#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})'", r"'#\2\1'")),
    ('③资源仍是 RGBA（没换位）', 'gen-theme-no-swap', regex('tools/codegen/gen_theme.py',
                                                     r'return\s+"#"\s*\+\s*value\[7:9\]\s*\+\s*value\[1:7\]\s+if\s+len\(value\)\s*==\s*9\s+else\s+value',
                                                     'return value')),
    ('③资源仍是 RGBA（没换位）', 'resource-dark-rgba', json_rows(DS_DARK, set_row('color_overlay_scrim', '#0000008C'))),
    ('④colorsDark 回落浅色', 'colors-dark-fallback', literal(DT, "map.set('background.canvas', '#171513');",
                                                       "map.set('background.canvas', '#F2EEE6');")),
    ('④colorsDark 回落浅色', 'no-colors-dark', regex(DT, r'\bcolorsDark\b', 'colorsNight')),
    ('⑤shadowsDark 缺键或取了浅色', 'shadows-dark-light', literal(DT, "'#000000', 0.3)", "'#28251F', 0.06)")),
    ('⑤shadowsDark 缺键或取了浅色', 'shadows-dark-missing-none', regex(DT, r"(shadowsDark[\s\S]*?)map\.set\('none', \[\]\);\n", r'\1', count=1)),
    ('⑥component 被 int() 截断', 'gen-num-int', regex('tools/codegen/gen.py', r'else repr\(v\)', 'else str(int(v))')),
    ('⑥component 被 int() 截断', 'design-tokens-1', literal(DT, "map.set('checkbox.max-scale', 1.5);", "map.set('checkbox.max-scale', 1);")),
    ('⑦gen_theme 仍读 specs 副本', 'gen-theme-reads-specs', chain(
        write('specs/design-tokens.v0.4.0.json', snapshot_bytes),
        regex('tools/codegen/gen_theme.py', SNAP_LITERALS, '"specs/design-tokens.v0.4.0.json"', count=1))),
    ('⑧ds02_test_data 仍读夹具副本', 'ds02-reads-fixture', chain(
        write('tools/ci/ds02/fixtures/design-tokens.v0.4.0.json', snapshot_bytes),
        regex('tools/codegen/ds02_test_data.py', r'''["']contracts/snapshot/design/design-tokens\.json["']''',
              '"tools/ci/ds02/fixtures/design-tokens.v0.4.0.json"', count=1))),
    ('⑨CouliComponentMetrics 读旧表', 'metrics-old-table', chain(
        literal(TT, 'export class CouliThemeTokens {', 'export class CouliThemeTokens {\n  static readonly component: Map<string, number> = '
                'new Map<string, number>([[\'checkbox.max-scale\', 1.5]]);'),
        regex(METRICS, r"metric\(DesignTokens\.component, 'checkbox\.max-scale'", "metric(CouliThemeTokens.component, 'checkbox.max-scale'"),
        literal(METRICS, "import { DesignTokens", "import { CouliThemeTokens } from './theme/CouliThemeTokens';\nimport { DesignTokens"))),
    ('⑨CouliComponentMetrics 读旧表', 'metrics-hardcoded', regex(METRICS, r"metric\(DesignTokens\.component, 'checkbox\.max-scale', 'component'\)", '1')),
    ('⑩版本不一致', 'theme-version', regex(TT, r"(static readonly version: string = )['\"][^'\"]+['\"]", r"\1'0.4.0'")),
    ('⑩版本不一致', 'ds02-expected-old-sha', regex('common/designsystem/src/test/Ds02Expected.ets', r'[0-9a-f]{64}', '11539dc0' + '0' * 56, count=1)),
    ('⑪entry base 仍手写且与令牌不同', 'entry-base-handwritten', json_rows(ENTRY_BASE, set_row('start_window_background', '#F2EEE7'))),
    ('额外：手算遮罩 CouliShadow.mask 回来', 'shadow-mask-back', literal(METRICS, '  private static options(',
                                                             '  static mask(baseHex: string): string {\n    return baseHex;\n  }\n\n'
                                                             '  private static options(')),
    ('额外：手抄深色表', 'hand-dark-table', write('common/designsystem/src/main/ets/theme/DarkTable.ets',
                                          lambda root: b"export const DARK_TEXT: string = '#F2EEE6';\n")),
    ('额外：设备测试退回按下标', 'device-by-index', regex(DEVICE, r"expect\(actual\.size\)\.assertEqual\(EXPECTED_COLORS\.length\);",
                                                 'const values: ResourceColor[] = []; expect(values.length).assertEqual(EXPECTED_COLORS.length);')),
    ('额外：深色资源少一行', 'resource-dark-missing', json_rows(DS_DARK, lambda rows: rows.__delitem__(
        next(i for i, r in enumerate(rows) if r['name'] == 'color_overlay_on_image')))),
]


def copy_repo(src, dst):
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns('.git', 'build', 'oh_modules', 'node_modules', '.hvigor', '.preview',
                                                            '__pycache__'))


def run_checks(root, names):
    red = {}
    for name in names:
        r = subprocess.run(CHECKS[name], cwd=root, capture_output=True, text=True, timeout=1200)
        if r.returncode != 0:
            lines = [l for l in (r.stdout + r.stderr).splitlines() if l.strip()]
            hint = next((l for l in lines if re.match(r'^(T\d+ |FAIL |AssertionError|  |gen\.py|.*HM-LINT-11)', l)), lines[-1] if lines else '')
            red[name] = hint.strip()[:140]
    return red


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=str(ROOT))
    ap.add_argument('--only')
    ap.add_argument('--skip-lint', action='store_true')
    args = ap.parse_args()
    names = [n for n in CHECKS if not (args.skip_lint and n == 'lint')]
    only = set(args.only.split(',')) if args.only else None
    tmp = tempfile.mkdtemp(prefix='tokens-mutants-')
    failed = False
    try:
        base = os.path.join(tmp, 'base')
        copy_repo(args.root, base)
        t0 = time.time()
        red = run_checks(base, names)
        if red:
            print('基线（未植入变异）就有检查红，变异矩阵无意义：%s' % red, file=sys.stderr)
            return 1
        print('基线：%s 全绿（%.0fs）' % (' / '.join(names), time.time() - t0))
        print('| 类别 | 变异体 | 打红的检查 | 首条红因 |')
        print('| --- | --- | --- | --- |')
        for category, name, apply in MUTANTS:
            if only and name not in only:
                continue
            d = os.path.join(tmp, name)
            copy_repo(base, d)
            try:
                apply(d)
            except NotApplied as e:
                print('| %s | %s | NOT_APPLIED | %s |' % (category, name, e))
                failed = True
                continue
            red = run_checks(d, names)
            if not red:
                failed = True
            first = next(iter(red.values()), '存活！')
            print('| %s | %s | %s | %s |' % (category, name, ', '.join(red) or 'SURVIVED', first.replace('|', '/')))
            shutil.rmtree(d, ignore_errors=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print('错误实现矩阵：%s' % ('全部植入且全部被杀' if not failed else '有 NOT_APPLIED 或存活，见上表'))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
