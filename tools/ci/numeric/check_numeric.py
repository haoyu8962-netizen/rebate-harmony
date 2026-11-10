#!/usr/bin/env python3
"""FU-HM-NUMERIC-TRANSITION-harmony 测试作者 v1：数字过渡不闪退的宿主结构检查（Python 3 标准库 + SDK ohos-typescript 解析，见 numeric_ast.cjs）。

背景：NATIVE/followups.md「FU-HM-NUMERIC-TRANSITION」；证据 NATIVE/HM-L2-PRICE-TAG/impl-harmony-handback.md try2 / try3。
API 20 模拟器上 `new NumericTextTransition()` 无参构造抛 TypeError（Cannot read property flipDirection of undefined），整个应用退出；
传选项对象（try3 用 `{ enableBlur: false }`）不崩。SDK 依据：text_common.d.ts `constructor(options?: NumericTextTransitionOptions)`，
NumericTextTransitionOptions 只有 flipDirection?: FlipDirection、enableBlur?: boolean 两个字段，均 @since 20。
本单只修「不崩」：PRICE-TAG 的直接替换结论（D10-1177 ⑤）和 MotionPolicy.numericTransition 都不动。

  N0  相关文件（提到 NumericTextTransition / contentTransition / CouliMotion，以及下面四个目标文件）解析不完整即违反
  N1  全仓（.ets / .ts；不含 tools/、docs/、build、oh_modules、node_modules、.hvigor、.git）每处 new NumericTextTransition：
        N1-args   必须有括号且恰 1 个实参（无参、`new X` 不带括号、多参都红）
        N1-object 实参必须是对象字面量，或本文件里「const 名字 = 对象字面量」的标识符（undefined / null / 形参 / let / 调用结果都红）
        N1-empty  对象至少 1 个字段（空 {} 未经设备实证）
        N1-key    只许 `键: 值` 普通属性，键 ⊆ {flipDirection, enableBlur}（展开、简写、计算键、方法、别的键都红）
        N1-value  enableBlur 的值是 true / false 字面量；flipDirection 的值是 FlipDirection.DOWN / FlipDirection.UP
        N1-ref    NumericTextTransition 只能出现在 new 的被调位置和类型位置；别名、当值传、属性访问（globalThis.X）都红
  N2  CouliMotion.numeric() 签名与返回：
        N2-class  CouliMotion.ets 里有导出的 class CouliMotion，且名为 numeric 的成员恰 1 个
        N2-sig    static 方法、0 个形参、返回类型恰为 NumericTextTransition
        N2-return 至少一个 return，每个 return 都是 new NumericTextTransition(…)（实参由 N1 判）
        N2-call   全仓 CouliMotion.numeric(…) 调用都不带实参
  N3  FeelLab（entry/src/staging/ets/catalog/FeelLab.ets）：
        N3-demo   至少一处 .contentTransition(CouliMotion.numeric())——数字过渡那一项还在，不靠删样例「不崩」
        N3-route  每处 .contentTransition(x) 的 x 都恰是 CouliMotion.numeric()
        N3-direct 不直接写 NumericTextTransition（样例页演示的是手感底座，不另起构造）
  N4  不动的结论：
        N4-policy MotionPolicy.numericTransition 仍是 static (reduced: boolean): boolean，方法体恰为 `return !reduced;`
        N4-replace Price.ets 不出现 contentTransition / NumericTextTransition / CouliMotion.numeric（D10-1177 ⑤ 直接替换）
  N5  扫描本身：CouliMotion.ets、FeelLab.ets、MotionPolicy.ets、Price.ets 都在扫描范围里

用法：
  python3 tools/ci/numeric/check_numeric.py                 本仓库（违反即退出 1）
  python3 tools/ci/numeric/check_numeric.py --root <目录>    查别的目录
  python3 tools/ci/numeric/check_numeric.py --self-test     参照件（fixtures/good）0 违反、合法变体 0 违反、每个变异被预期代码打红；
                                                            另跑 run-numeric.cjs 对参照件全绿、对行为变异全红（REFERENCE_ONLY，不算产品通过）
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
AST = HERE / 'numeric_ast.cjs'
RUNNER = HERE / 'run-numeric.cjs'
GOOD = HERE / 'fixtures' / 'good'

MOTION = 'common/designsystem/src/main/ets/components/CouliMotion.ets'
POLICY = 'common/designsystem/src/main/ets/logic/MotionPolicy.ets'
PRICE = 'common/designsystem/src/main/ets/components/Price.ets'
FEEL_LAB = 'entry/src/staging/ets/catalog/FeelLab.ets'
TARGETS = [MOTION, POLICY, PRICE, FEEL_LAB]

SKIP_DIRS = {'.git', 'node_modules', 'oh_modules', 'build', '.hvigor', '.idea', '.preview', 'docs'}
SKIP_TOP = {'tools'}
OPTION_KEYS = {'flipDirection', 'enableBlur'}
FLIP_VALUES = {'member:FlipDirection.DOWN', 'member:FlipDirection.UP'}
RELEVANT = ('NumericTextTransition', 'contentTransition', 'CouliMotion')


def scan(root):
    out = []
    root = Path(root)
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = Path(dirpath).relative_to(root)
        keep = []
        for d in dirnames:
            if d in SKIP_DIRS or (rel_dir == Path('.') and d in SKIP_TOP):
                continue
            keep.append(d)
        dirnames[:] = sorted(keep)
        for f in sorted(filenames):
            if f.endswith('.ets') or f.endswith('.ts'):
                if f.endswith('.d.ts'):
                    continue
                out.append((rel_dir / f).as_posix())
    return out


def parse(root, rels):
    payload = []
    for rel in rels:
        payload.append({'name': rel, 'text': (Path(root) / rel).read_text(encoding='utf-8', errors='replace')})
    proc = subprocess.run(['node', str(AST)], input=json.dumps(payload), capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit('numeric_ast.cjs 失败：' + proc.stderr[-2000:])
    facts = json.loads(proc.stdout)
    return {f['name']: (f, payload[i]['text']) for i, f in enumerate(facts)}


def check(root):
    v = []

    def bad(code, where, msg):
        v.append((code, where, msg))

    rels = scan(root)
    for t in TARGETS:
        if t not in rels:
            bad('N5-scope', t, '目标文件不在扫描范围（不存在或被排除）')
    facts = parse(root, rels)

    # N0
    for rel, (f, text) in facts.items():
        if f['incomplete'] and (rel in TARGETS or any(k in text for k in RELEVANT)):
            bad('N0', rel, '解析不完整：' + '；'.join(f['incomplete'][:3]))

    # N1 / N2-call
    for rel, (f, _text) in facts.items():
        for n in f['news']:
            where = '%s:%d' % (rel, n['line'])
            if n['calleeText'].strip('() ') != 'NumericTextTransition':
                bad('N1-ref', where, 'new 的被调不是裸标识符 NumericTextTransition：' + n['calleeText'])
            if not n['hasParens'] or n['argCount'] != 1:
                bad('N1-args', where, '必须恰 1 个选项对象实参（API 20 无参构造即闪退）：' + n['text'])
                continue
            a = n['args'][0]
            if a['form'] != 'object':
                bad('N1-object', where, '实参不是对象字面量 / 本文件 const 对象字面量（%s%s）：%s'
                    % (a['form'], ('，' + a['reason']) if a.get('reason') else '', a['text']))
                continue
            props = a['props']
            if not props:
                bad('N1-empty', where, '选项对象是空的 {}：' + a['text'])
            for p in props:
                if p['kind'] != 'prop' or p['key'] not in OPTION_KEYS:
                    bad('N1-key', where, '选项只许 flipDirection / enableBlur 的普通属性，实际 %s %s' % (p['kind'], p['key']))
                    continue
                if p['key'] == 'enableBlur' and p['valueKind'] != 'boolean':
                    bad('N1-value', where, 'enableBlur 的值要是 true / false 字面量，实际 ' + p['value'])
                if p['key'] == 'flipDirection' and p['valueKind'] not in FLIP_VALUES:
                    bad('N1-value', where, 'flipDirection 的值要是 FlipDirection.DOWN / UP，实际 ' + p['value'])
            keys = [p['key'] for p in props if p['kind'] == 'prop']
            if len(keys) != len(set(keys)):
                bad('N1-key', where, '选项对象有重复键')
        for r in f['refs']:
            bad('N1-ref', '%s:%d' % (rel, r['line']), 'NumericTextTransition 只能用在 new 与类型位置（%s）：%s'
                % (r['context'], r['text']))
        for c in f['numericCalls']:
            if c['argCount'] != 0:
                bad('N2-call', '%s:%d' % (rel, c['line']), 'CouliMotion.numeric 调用带了实参：' + c['text'])

    # N2
    if MOTION in facts:
        f = facts[MOTION][0]
        cls = f['couliMotionClass']
        if not cls or not cls['exported']:
            bad('N2-class', MOTION, '没有导出的 class CouliMotion')
        if len(f['numeric']) != 1:
            bad('N2-class', MOTION, 'CouliMotion 里名为 numeric 的成员应恰 1 个，实际 %d' % len(f['numeric']))
        for m in f['numeric']:
            where = '%s:%d' % (MOTION, m['line'])
            if m['kind'] != 'MethodDeclaration' or not m['isStatic']:
                bad('N2-sig', where, 'numeric 要是 static 方法（实际 %s，static=%s）' % (m['kind'], m['isStatic']))
            if m['params']:
                bad('N2-sig', where, 'numeric 签名要无形参，实际 (%s)' % ', '.join(m['params']))
            if (m['returnType'] or '').replace(' ', '') != 'NumericTextTransition':
                bad('N2-sig', where, 'numeric 返回类型要恰为 NumericTextTransition，实际 %s' % m['returnType'])
            if not m['returns']:
                bad('N2-return', where, 'numeric 没有 return')
            for r in m['returns']:
                if not r['isNewNumeric']:
                    bad('N2-return', '%s:%d' % (MOTION, r['line']), 'numeric 的每个 return 都要是 new NumericTextTransition(…)，实际 '
                        + (r['text'] or '（空 return）'))

    # N3
    if FEEL_LAB in facts:
        f = facts[FEEL_LAB][0]
        if not any(t['isCouliNumericNoArg'] for t in f['transitions']):
            bad('N3-demo', FEEL_LAB, '数字过渡样例没了：找不到 .contentTransition(CouliMotion.numeric())')
        for t in f['transitions']:
            if not t['isCouliNumericNoArg']:
                bad('N3-route', '%s:%d' % (FEEL_LAB, t['line']), '.contentTransition 实参要恰是 CouliMotion.numeric()，实际 ' + t['arg'])
        if f['news'] or f['refs']:
            line = (f['news'] or f['refs'])[0]['line']
            bad('N3-direct', '%s:%d' % (FEEL_LAB, line), 'FeelLab 不直接写 NumericTextTransition，走 CouliMotion.numeric()')

    # N4
    if POLICY in facts:
        f = facts[POLICY][0]
        ms = f['policy']
        if len(ms) != 1:
            bad('N4-policy', POLICY, 'MotionPolicy.numericTransition 应恰 1 个，实际 %d' % len(ms))
        for m in ms:
            sig_ok = (m['kind'] == 'MethodDeclaration' and m['isStatic'] and [p.replace(' ', '') for p in m['params']] == ['reduced:boolean']
                      and (m['returnType'] or '') == 'boolean')
            if not sig_ok or m['statements'] != ['return !reduced;']:
                bad('N4-policy', '%s:%d' % (POLICY, m['line']), 'MotionPolicy.numericTransition 被改了（本单不动）：(%s): %s { %s }'
                    % (', '.join(m['params']), m['returnType'], ' '.join(m['statements'])))
    if PRICE in facts:
        f, _ = facts[PRICE]
        if f['transitions'] or f['news'] or f['refs'] or f['numericCalls']:
            bad('N4-replace', PRICE, 'Price.ets 出现了 contentTransition / NumericTextTransition / CouliMotion.numeric（PRICE-TAG 维持直接替换）')

    return v, len(rels)


def report(v, n, label):
    for code, where, msg in sorted(v):
        print('VIOLATION %s %s %s' % (code, where, msg))
    print('%s: %d 个文件，%d 处违反' % (label, n, len(v)))


# ---------------- 自测 ----------------

GOOD_NEW = 'new NumericTextTransition({ enableBlur: false })'
NUMERIC_BLOCK = '  static numeric(): NumericTextTransition {\n    return %s;\n  }' % GOOD_NEW
OTHER = 'features/home/src/main/ets/view/NumericProbe.ets'
OTHER_TEST = 'common/designsystem/src/test/NumericProbe.test.ets'


def other_file(body):
    return ('export function probeTransition(): NumericTextTransition {\n%s\n}\n' % body)


# 合法变体：都应 0 违反（不误红）。(名称, 文件, 旧, 新)；文件不存在时「旧」为 None 表示新建。
VARIANTS = [
    ('flipDirection DOWN', MOTION, GOOD_NEW, 'new NumericTextTransition({ flipDirection: FlipDirection.DOWN })'),
    ('两个字段', MOTION, GOOD_NEW, 'new NumericTextTransition({ flipDirection: FlipDirection.UP, enableBlur: true })'),
    ('本文件 const 选项', MOTION, NUMERIC_BLOCK,
     '  static numeric(): NumericTextTransition {\n    const options: NumericTextTransitionOptions = { enableBlur: false };\n'
     '    return new NumericTextTransition(options);\n  }'),
    ('别处带选项构造', OTHER, None, other_file('  return new NumericTextTransition({ enableBlur: false });')),
    ('FeelLab 额外注释不影响', FEEL_LAB, '      Row({ space: CouliSpacing.space2 }) {',
     '      // 数字过渡：走 CouliMotion.numeric()\n      Row({ space: CouliSpacing.space2 }) {'),
]

# 变异：(名称, 文件, 旧, 新, 预期代码, 是否同时喂 run-numeric 必红)
MUTANTS = [
    ('基线：numeric 无参构造', MOTION, GOOD_NEW, 'new NumericTextTransition()', 'N1-args', True),
    ('new 不带括号', MOTION, GOOD_NEW, 'new NumericTextTransition', 'N1-args', True),
    ('括号包着被调再无参', MOTION, GOOD_NEW, 'new (NumericTextTransition)()', 'N1-args', True),
    ('两个实参', MOTION, GOOD_NEW, 'new NumericTextTransition({ enableBlur: false }, { enableBlur: true })', 'N1-args', False),
    ('传 undefined', MOTION, GOOD_NEW, 'new NumericTextTransition(undefined)', 'N1-object', True),
    ('传 null', MOTION, GOOD_NEW, 'new NumericTextTransition(null)', 'N1-object', True),
    ('空对象', MOTION, GOOD_NEW, 'new NumericTextTransition({})', 'N1-empty', True),
    ('字段值 undefined', MOTION, GOOD_NEW, 'new NumericTextTransition({ enableBlur: undefined })', 'N1-value', True),
    ('enableBlur 非字面量', MOTION, GOOD_NEW, 'new NumericTextTransition({ enableBlur: CouliMotion.reduced() })', 'N1-value', False),
    ('flipDirection 写数字', MOTION, GOOD_NEW, 'new NumericTextTransition({ flipDirection: 0 })', 'N1-value', False),
    ('未知键', MOTION, GOOD_NEW, 'new NumericTextTransition({ blur: false })', 'N1-key', True),
    ('展开', MOTION, NUMERIC_BLOCK,
     '  static numeric(): NumericTextTransition {\n    const base: NumericTextTransitionOptions = { enableBlur: false };\n'
     '    return new NumericTextTransition({ ...base });\n  }', 'N1-key', False),
    ('let 选项', MOTION, NUMERIC_BLOCK,
     '  static numeric(): NumericTextTransition {\n    let options: NumericTextTransitionOptions = { enableBlur: false };\n'
     '    return new NumericTextTransition(options);\n  }', 'N1-object', False),
    ('const 选项是空对象', MOTION, NUMERIC_BLOCK,
     '  static numeric(): NumericTextTransition {\n    const options: NumericTextTransitionOptions = {};\n'
     '    return new NumericTextTransition(options);\n  }', 'N1-empty', True),
    ('选项来自调用', MOTION, GOOD_NEW, 'new NumericTextTransition(CouliMotion.options())', 'N1-object', False),
    ('别名后无参构造', MOTION, NUMERIC_BLOCK,
     '  static numeric(): NumericTextTransition {\n    const Ctor = NumericTextTransition;\n    return new Ctor();\n  }', 'N1-ref', True),
    ('globalThis 属性访问', MOTION, GOOD_NEW, 'new globalThis.NumericTextTransition()', 'N1-ref', True),
    ('numeric 加可选形参', MOTION, 'static numeric(): NumericTextTransition {',
     'static numeric(options?: NumericTextTransitionOptions): NumericTextTransition {', 'N2-sig', False),
    ('numeric 返回类型放宽', MOTION, 'static numeric(): NumericTextTransition {', 'static numeric(): ContentTransition {', 'N2-sig', False),
    ('numeric 改实例方法', MOTION, 'static numeric(): NumericTextTransition {', 'numeric(): NumericTextTransition {', 'N2-sig', False),
    ('numeric 返回缓存字段', MOTION, NUMERIC_BLOCK,
     '  private static cached: NumericTextTransition = %s;\n\n  static numeric(): NumericTextTransition {\n'
     '    return CouliMotion.cached;\n  }' % GOOD_NEW, 'N2-return', False),
    ('numeric 有一支返回别的', MOTION, NUMERIC_BLOCK,
     '  static numeric(): NumericTextTransition {\n    if (CouliMotion.reduced()) {\n      return CouliMotion.numericFallback();\n'
     '    }\n    return %s;\n  }' % GOOD_NEW, 'N2-return', False),
    ('numeric 被删', MOTION, NUMERIC_BLOCK + '\n', '', 'N2-class', True),
    ('CouliMotion 解析不完整', MOTION, NUMERIC_BLOCK, NUMERIC_BLOCK + '\n  static broken(: void {', 'N0', False),
    ('FeelLab 直接无参 new', FEEL_LAB, '.contentTransition(CouliMotion.numeric())',
     '.contentTransition(new NumericTextTransition())', 'N1-args', False),
    ('FeelLab 直接带参 new', FEEL_LAB, '.contentTransition(CouliMotion.numeric())',
     '.contentTransition(new NumericTextTransition({ enableBlur: false }))', 'N3-direct', False),
    ('FeelLab 改挂 undefined', FEEL_LAB, '.contentTransition(CouliMotion.numeric())', '.contentTransition(undefined)', 'N3-demo', False),
    ('FeelLab 删掉数字过渡样例', FEEL_LAB, '\n          .contentTransition(CouliMotion.numeric())', '', 'N3-demo', False),
    ('FeelLab 多挂一处别的过渡', FEEL_LAB, '          .contentTransition(CouliMotion.numeric())',
     '          .contentTransition(CouliMotion.numeric())\n          .contentTransition(undefined)', 'N3-route', False),
    ('FeelLab 给 numeric 传参', FEEL_LAB, '.contentTransition(CouliMotion.numeric())',
     '.contentTransition(CouliMotion.numeric({ enableBlur: false }))', 'N2-call', False),
    ('features 里无参构造', OTHER, None, other_file('  return new NumericTextTransition();'), 'N1-args', False),
    ('测试文件里无参构造', OTHER_TEST, None, other_file('  return new NumericTextTransition();'), 'N1-args', False),
    ('别处以值传类', OTHER, None, other_file('  const make: Function = NumericTextTransition;\n  return new NumericTextTransition({ enableBlur: false });'),
     'N1-ref', False),
    ('MotionPolicy 改成恒 true', POLICY, 'return !reduced;', 'return true;', 'N4-policy', False),
    ('MotionPolicy 改签名', POLICY, 'static numericTransition(reduced: boolean): boolean {',
     'static numericTransition(reduced: boolean, api: number): boolean {', 'N4-policy', False),
    ('Price 挂回数字过渡', PRICE, '      Span(this.content.mainAmount)',
     '      Span(this.content.mainAmount)\n        .contentTransition(CouliMotion.numeric())', 'N4-replace', False),
    ('FeelLab 被删', FEEL_LAB, 'DELETE', None, 'N5-scope', False),
]


def build_tree(tmp):
    tree = Path(tmp) / 'tree'
    shutil.copytree(GOOD, tree)
    return tree


def apply(tree, rel, old, new):
    p = tree / rel
    if old == 'DELETE':
        p.unlink()
        return
    if old is None:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(new, encoding='utf-8')
        return
    text = p.read_text(encoding='utf-8')
    if text.count(old) != 1:
        raise SystemExit('自测夹具失配：%s 里「%s」出现 %d 次' % (rel, old[:60], text.count(old)))
    p.write_text(text.replace(old, new), encoding='utf-8')


def runner(tree, expect_red):
    cmd = ['node', str(RUNNER), '--root', str(tree)] + (['--expect-red'] if expect_red else [])
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode == 0, proc.stdout.strip().splitlines()[-1:] if proc.stdout else [proc.stderr[-300:]]


def self_test():
    failures = 0
    for t in TARGETS:
        if not (GOOD / t).is_file():
            print('SELFTEST 缺参照件 ' + t)
            return 1
    with tempfile.TemporaryDirectory(prefix='numeric-selftest-') as tmp:
        tree = build_tree(tmp)
        v, n = check(tree)
        ok_run, tail = runner(tree, False)
        if v or not ok_run:
            report(v, n, 'SELFTEST 参照件')
            print('SELFTEST FAIL 参照件应 0 违反且 run-numeric 全绿：', tail)
            failures += 1
        else:
            print('SELFTEST OK 参照件 0 违反；run-numeric %s' % ' '.join(tail))
    for name, rel, old, new in VARIANTS:
        with tempfile.TemporaryDirectory(prefix='numeric-selftest-') as tmp:
            tree = build_tree(tmp)
            apply(tree, rel, old, new)
            v, _ = check(tree)
            ok_run, tail = runner(tree, False) if rel == MOTION else (True, [])
            if v or not ok_run:
                print('SELFTEST FAIL 合法变体被误红「%s」：%s %s' % (name, [c for c, _, _ in v], tail))
                failures += 1
            else:
                print('SELFTEST OK 合法变体「%s」0 违反' % name)
    for name, rel, old, new, code, behaviour in MUTANTS:
        with tempfile.TemporaryDirectory(prefix='numeric-selftest-') as tmp:
            tree = build_tree(tmp)
            apply(tree, rel, old, new)
            v, _ = check(tree)
            codes = sorted({c for c, _, _ in v})
            hit = code in codes
            run_ok, tail = (True, [])
            if behaviour:
                run_ok, tail = runner(tree, True)
            if hit and run_ok:
                print('SELFTEST OK 变异「%s」→ %s%s' % (name, ','.join(codes), '；run-numeric 红' if behaviour else ''))
            else:
                print('SELFTEST FAIL 变异「%s」预期 %s，实际 %s%s' % (name, code, codes or '0 违反',
                                                              '' if run_ok else '；run-numeric 没红 ' + ' '.join(tail)))
                failures += 1
    total = 1 + len(VARIANTS) + len(MUTANTS)
    print('SELFTEST %s：%d 项，失败 %d（REFERENCE_ONLY，不算产品通过）' % ('PASS' if failures == 0 else 'FAIL', total, failures))
    return 1 if failures else 0


def main():
    args = sys.argv[1:]
    if '--self-test' in args:
        sys.exit(self_test())
    root = Path(args[args.index('--root') + 1]).resolve() if '--root' in args else ROOT
    v, n = check(root)
    report(v, n, 'FU-HM-NUMERIC-TRANSITION 宿主检查 ' + str(root))
    sys.exit(1 if v else 0)


if __name__ == '__main__':
    main()
