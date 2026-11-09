#!/usr/bin/env python3
"""FU-HM-THEME-BASE-harmony 测试作者 v1：主题底座宿主检查（Python 3 标准库 + SDK ohos-typescript 解析，见 parse-ets.cjs）。

依据：NATIVE/FU-HM-THEME-BASE/brief-harmony.md §1.2、§2.1、§2.2、§3.1；裁定 D10-1153。.ets / .d.ts 一律走 AST，不用正则。

  C1  生产代码（entry 三个源码集、features、common 的 src/main）里 CouliTheme.install 恰好一处，在 EntryAbility.loadRoot（eb9db90 的实际位置，
      任务书 §1.1 写的 onWindowStageCreate 是它的调用方；本检查同时要求 onWindowStageCreate 调 this.loadRoot），实参恰为
      (this.context, BuildVariant.themeNeutralPreset())，且在 windowStage.loadContent 之前（只在冷启动安装一次）
  C2  CouliTheme.install 第二参可选、类型 SystemNeutralPreset、缺省不是 SYSTEM；方法体里唯一一处
      buildSystemColors(CouliColors.tokenResources(), <第二参>)，原样透传
  C3  CouliThemeMapping.ets：export enum SystemNeutralPreset 恰为 TOKEN='token'、SYSTEM='system'；export buildSystemColors 恰两参，
      第二参类型 SystemNeutralPreset、缺省 SystemNeutralPreset.TOKEN
  C4  BRAND_ROLES（22）/ NEUTRAL_ROLES（29）：顶层 export、数组字面量、元素全是字符串字面量、无重复、互不相交、并集 =
      tools/ci/ds02/fixtures/system-color-roles.json，品牌组 = 本文件钉的 22 个（任务书 §1.2 甲组）
  C5  Release 进包的源码（entry/src/main、entry/src/release、features/*/src/{main,release}、common/*/src/{main,release} 的 .ets / .ts /
      .json / .json5）原文（含注释）不含启动参数名；release BuildVariant.themeNeutralPreset() 静态无参、返回类型 SystemNeutralPreset、
      方法体恰为 return SystemNeutralPreset.TOKEN;
  C6  staging BuildVariant：有静态无参 themeNeutralPreset(): SystemNeutralPreset；applyLaunchOptions 用 want.parameters?.[…] 读该参数
      （字面量或本文件值为该串的顶层常量）；每处产出 SystemNeutralPreset.SYSTEM 的地方都在 `=== 'system'` 的真分支里（其他值 / 不带 = token）；
      不用 `as SystemNeutralPreset` 把外部串强转
  C5b / C6b（v2，评审 r1 S2-1）真执行 BuildVariant 的开关代码（eval-variant.cjs，切出原文转译后在 node 里跑）：staging 冷启动参数 system → SYSTEM，
      不带、want 没有 parameters、非法值（大小写不同、带空格、空串、token、非字符串）→ TOKEN；Release 无论参数是什么都 TOKEN
  C7  tools/ci/release-scan.sh 的 markers 表含该参数名（解析内嵌 Python，注释里的不算）
  C8  三个测试壳（Ds02R1Ability、Fx05aAbility、Hm07vAbility）仍是 CouliTheme.install(this.context)，默认 token
  C9  ThemeBase.test.ets 存在且 51 个角色名都在其字符串字面量里；designsystem List.test.ets 导入并调用 themeBaseTest；verify.sh 在 ds02-host 之后
      依次跑本检查 --self-test、本检查、run-logic.cjs、check-arkts.cjs，并在 HM-07v-a 制品步之后跑 --hap / --hap-staging
  C10 tools/ci/ds02/fixtures/contracts.d.ts：buildSystemColors 第二参可选，SystemNeutralPreset 有声明（#24，只加可选参）

用法：
  python3 tools/ci/themebase/check_theme_base.py                 本仓库（违反即退出 1）
  python3 tools/ci/themebase/check_theme_base.py --self-test     合成合规件 0 违反、每个错误实现被对应条目打红（REFERENCE_ONLY，不算产品通过）
  python3 tools/ci/themebase/check_theme_base.py --root <目录>    查别的目录
  python3 tools/ci/themebase/check_theme_base.py --hap X.hap     Release 制品里不得出现启动参数名（utf-8 / utf-16-le，含内层压缩包）
  python3 tools/ci/themebase/check_theme_base.py --hap-staging X.hap   Staging / Debug 制品里必须有
"""

import ast
import json
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PARSER = Path(__file__).with_name('parse-ets.cjs')
EVAL_VARIANT = Path(__file__).with_name('eval-variant.cjs')

KEY = 'couli_debug_theme_neutral'
MAPPING = 'common/designsystem/src/main/ets/theme/CouliThemeMapping.ets'
COLORS = 'common/designsystem/src/main/ets/CouliColors.ets'
ENTRY = 'entry/src/main/ets/entryability/EntryAbility.ets'
RELEASE_BV = 'entry/src/release/ets/variant/BuildVariant.ets'
STAGING_BV = 'entry/src/staging/ets/variant/BuildVariant.ets'
RELEASE_SCAN = 'tools/ci/release-scan.sh'
ROLES = 'tools/ci/ds02/fixtures/system-color-roles.json'
CONTRACTS = 'tools/ci/ds02/fixtures/contracts.d.ts'
SUITE = 'common/designsystem/src/test/ThemeBase.test.ets'
LIST = 'common/designsystem/src/test/List.test.ets'
VERIFY = 'tools/ci/verify.sh'
SHELLS = ['entry/src/ohosTest/ets/testability/%s.ets' % n for n in ('Ds02R1Ability', 'Fx05aAbility', 'Hm07vAbility')]
TEXT_EXT = ('.ets', '.ts', '.json', '.json5')
SKIP_DIRS = {'build', 'oh_modules', 'node_modules', '.hvigor', '.preview'}

# 任务书 §1.2 甲组（22）。乙组 = fixture 减本表。
BRAND = {
    'brand', 'iconEmphasize', 'backgroundEmphasize', 'fontEmphasize', 'iconSubEmphasize', 'compBackgroundEmphasize',
    'compEmphasizeSecondary', 'interactiveSelect', 'compEmphasizeTertiary', 'interactiveActive', 'interactiveFocus',
    'warning', 'alert', 'confirm', 'fontOnPrimary', 'fontOnSecondary', 'fontOnTertiary', 'fontOnFourth',
    'iconOnPrimary', 'iconOnSecondary', 'iconOnTertiary', 'iconOnFourth',
}


def parse_all(items):
    result = subprocess.run(['node', str(PARSER)], input=json.dumps([{'name': n, 'text': t} for n, t in items]),
                            capture_output=True, text=True, timeout=180)
    if result.returncode != 0:
        raise SystemExit('parse-ets.cjs 失败：' + result.stderr)
    parsed = json.loads(result.stdout)
    if len(parsed) != len(items):
        raise SystemExit('parse-ets.cjs 返回条数不对')
    return dict(zip([n for n, _ in items], parsed))


# (用例名, want.parameters)；None 的形状 = want 上没有 parameters。
OTHER_CASES = [('不带参数', {}), ('want 没有 parameters', None)] + [
    ('参数=%s' % json.dumps(v, ensure_ascii=False), {KEY: v})
    for v in ('bogus', 'SYSTEM', 'System', ' system', 'system ', '', 'token', 'TOKEN', 1, True, None, ['system'])]
SYSTEM_CASE = ('参数=system', {KEY: 'system'})


def eval_variant(mapping_text, variant_text):
    cases = []
    for name, parameters in [SYSTEM_CASE] + OTHER_CASES:
        cases.append({'name': name} if parameters is None else {'name': name, 'parameters': parameters})
    result = subprocess.run(['node', str(EVAL_VARIANT)], capture_output=True, text=True, timeout=120,
                            input=json.dumps({'mapping': mapping_text, 'variant': variant_text, 'key': KEY, 'cases': cases}))
    if result.returncode != 0:
        raise SystemExit('eval-variant.cjs 失败：' + result.stderr)
    return json.loads(result.stdout)


def check_variant_behavior(rule, label, mapping_text, variant_text, system_value):
    """system_value：参数=system 时应得到的串（staging 是 system，Release 是 token）。"""
    out = []
    outcome = eval_variant(mapping_text, variant_text)
    if outcome['incomplete']:
        return ['%s %s 无法执行：%s' % (rule, label, outcome['incomplete'])]
    if outcome['initial'] != 'token':
        out.append('%s %s 未调 applyLaunchOptions 时应为 token，实际 %s' % (rule, label, outcome['initial']))
    for row in outcome['results']:
        expected = system_value if row['name'] == SYSTEM_CASE[0] else 'token'
        if 'error' in row:
            out.append('%s %s %s 抛错：%s' % (rule, label, row['name'], row['error']))
        elif row.get('value') != expected:
            out.append('%s %s %s 应选到 %s，实际 %s' % (rule, label, row['name'], expected, row.get('value')))
    return out


def walk(base):
    if not base.is_dir():
        return
    for path in sorted(base.rglob('*')):
        if path.is_file() and not (SKIP_DIRS & set(p.name for p in path.relative_to(base).parents)):
            yield path


def module_dirs(root, group):
    base = root / group
    return sorted(p for p in base.iterdir() if p.is_dir()) if base.is_dir() else []


def production_sources(root):
    """会进任何产品制品的 .ets（含 staging）。"""
    folders = [root / 'entry/src/main', root / 'entry/src/staging', root / 'entry/src/release']
    for group in ('features', 'common'):
        folders += [d / 'src/main' for d in module_dirs(root, group)]
    for folder in folders:
        for path in walk(folder):
            if path.suffix == '.ets':
                yield path


def release_sources(root):
    """进 Release 制品的文本源码。"""
    folders = [root / 'entry/src/main', root / 'entry/src/release']
    for group in ('features', 'common'):
        for d in module_dirs(root, group):
            folders += [d / 'src/main', d / 'src/release']
    for folder in folders:
        for path in walk(folder):
            if path.suffix in TEXT_EXT:
                yield path


def read(root, rel, out, rule):
    path = root / rel
    if not path.is_file():
        out.append('%s 缺文件 %s' % (rule, rel))
        return None
    return path.read_text(encoding='utf-8')


def markers_in_release_scan(text):
    """release-scan.sh 内嵌 Python 的 markers 表里的字符串常量。"""
    if "<<'PY'\n" not in text:
        return None
    scanner = text.split("<<'PY'\n", 1)[1].split('\nPY', 1)[0]
    for node in ast.parse(scanner).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'markers' for t in node.targets) \
                and isinstance(node.value, ast.List):
            return {e.value for e in node.value.elts if isinstance(e, ast.Constant) and isinstance(e.value, str)}
    return None


def check_tree(root):
    out = []
    rels = [MAPPING, COLORS, ENTRY, RELEASE_BV, STAGING_BV, CONTRACTS, SUITE, LIST] + SHELLS
    texts = {}
    for rel in rels:
        rule = {MAPPING: 'C3', COLORS: 'C2', ENTRY: 'C1', RELEASE_BV: 'C5', STAGING_BV: 'C6', CONTRACTS: 'C10', SUITE: 'C9', LIST: 'C9'}.get(rel, 'C8')
        text = read(root, rel, out, rule)
        if text is not None:
            texts[rel] = text
    production = {}
    for path in production_sources(root):
        rel = str(path.relative_to(root))
        text = path.read_text(encoding='utf-8')
        if 'CouliTheme' in text and 'install' in text:
            production[rel] = text
    items = list(texts.items()) + [(rel, text) for rel, text in production.items() if rel not in texts]
    facts = parse_all(items)
    for rel, fact in facts.items():
        if fact['incomplete']:
            out.append('C0 %s 解析不完整：%s' % (rel, fact['incomplete']))
    if any(line.startswith('C0 ') for line in out):
        return out

    # C1
    calls = []
    for rel in production:
        calls += [(rel, c) for c in facts[rel]['calls'] if c['callee'] == 'CouliTheme.install']
    if len(calls) != 1:
        out.append('C1 CouliTheme.install 生产调用应恰好 1 处，实际 %d 处：%s' % (len(calls), [r + ':' + str(c['line']) for r, c in calls]))
    for rel, call in calls:
        if rel != ENTRY:
            out.append('C1 CouliTheme.install 不许出现在 %s:%d' % (rel, call['line']))
            continue
        if call['enclosing'] != 'EntryAbility.loadRoot':
            out.append('C1 CouliTheme.install 应在 EntryAbility.loadRoot 里，实际在 %s' % call['enclosing'])
        if not any(c['callee'] == 'this.loadRoot' and c['enclosing'] == 'EntryAbility.onWindowStageCreate' for c in facts[ENTRY]['calls']):
            out.append('C1 onWindowStageCreate 没有调 this.loadRoot')
        if call['args'] != ['this.context', 'BuildVariant.themeNeutralPreset()']:
            out.append('C1 CouliTheme.install 实参应为 (this.context, BuildVariant.themeNeutralPreset())，实际 %s' % call['args'])
        loads = [c for c in facts[ENTRY]['calls'] if c['callee'].endswith('.loadContent')]
        if not loads or not all(call['pos'] < c['pos'] for c in loads):
            out.append('C1 CouliTheme.install 必须在 loadContent 之前')

    # C2
    if COLORS in facts:
        method = facts[COLORS]['classes'].get('CouliTheme', {}).get('methods', {}).get('install')
        if method is None:
            out.append('C2 缺 CouliTheme.install')
        else:
            params = method['params']
            if len(params) != 2:
                out.append('C2 install 应为两参（context?, preset?），实际 %d' % len(params))
            else:
                second = params[1]
                if not second['optional'] and second['init'] is None:
                    out.append('C2 install 第二参必须可选（测试壳不改）')
                if second['type'] != 'SystemNeutralPreset':
                    out.append('C2 install 第二参类型应为 SystemNeutralPreset，实际 %s' % second['type'])
                if second['init'] not in (None, 'SystemNeutralPreset.TOKEN'):
                    out.append('C2 install 第二参缺省不得是 %s' % second['init'])
                builds = [c for c in facts[COLORS]['calls'] if c['callee'] == 'buildSystemColors' and c['enclosing'].endswith('CouliTheme.install')]
                if len(builds) != 1 or builds[0]['args'] != ['CouliColors.tokenResources()', second['name']]:
                    out.append('C2 install 必须唯一一处 buildSystemColors(CouliColors.tokenResources(), %s)，实际 %s' % (second['name'], [b['args'] for b in builds]))

    # C3 / C4
    if MAPPING in facts:
        mapping = facts[MAPPING]
        enum = mapping['enums'].get('SystemNeutralPreset')
        if enum is None or not enum['exported']:
            out.append('C3 缺 export enum SystemNeutralPreset')
        elif enum['members'] != {'TOKEN': 'token', 'SYSTEM': 'system'}:
            out.append('C3 SystemNeutralPreset 成员应恰为 TOKEN=token、SYSTEM=system，实际 %s' % enum['members'])
        fn = mapping['functions'].get('buildSystemColors')
        if fn is None or not fn['exported']:
            out.append('C3 缺 export function buildSystemColors')
        elif len(fn['params']) != 2:
            out.append('C3 buildSystemColors 应恰两参，实际 %d' % len(fn['params']))
        else:
            if fn['params'][1]['init'] != 'SystemNeutralPreset.TOKEN':
                out.append('C3 buildSystemColors 第二参缺省应为 SystemNeutralPreset.TOKEN，实际 %s' % fn['params'][1]['init'])
            if fn['params'][1]['type'] != 'SystemNeutralPreset':
                out.append('C3 buildSystemColors 第二参类型应为 SystemNeutralPreset，实际 %s' % fn['params'][1]['type'])
        roles_text = read(root, ROLES, out, 'C4')
        roles = json.loads(roles_text) if roles_text is not None else []
        tables = {}
        for name, count in (('BRAND_ROLES', 22), ('NEUTRAL_ROLES', 29)):
            table = mapping['consts'].get(name)
            if table is None or not table['exported']:
                out.append('C4 缺顶层 export const %s' % name)
                continue
            elements = table['elements']
            if elements is None or any(e is None for e in elements):
                out.append('C4 %s 必须是字符串字面量组成的数组字面量' % name)
                continue
            if len(elements) != count or len(set(elements)) != len(elements):
                out.append('C4 %s 应为 %d 个不重复的角色，实际 %d 个（去重 %d）' % (name, count, len(elements), len(set(elements))))
            tables[name] = set(elements)
        if len(tables) == 2:
            common = tables['BRAND_ROLES'] & tables['NEUTRAL_ROLES']
            if common:
                out.append('C4 两张表相交：%s' % sorted(common))
            union = tables['BRAND_ROLES'] | tables['NEUTRAL_ROLES']
            if union != set(roles):
                out.append('C4 并集与 fixture 不一致：缺 %s，多 %s' % (sorted(set(roles) - union), sorted(union - set(roles))))
            if tables['BRAND_ROLES'] != BRAND:
                out.append('C4 品牌组与任务书 §1.2 不一致：缺 %s，多 %s' % (sorted(BRAND - tables['BRAND_ROLES']), sorted(tables['BRAND_ROLES'] - BRAND)))
        if SUITE in facts:
            literal = {s['value'] for s in facts[SUITE]['strings']}
            missing = sorted(set(roles) - literal)
            if missing:
                out.append('C9 ThemeBase.test.ets 缺角色名：%s' % missing)

    # C5
    for path in release_sources(root):
        if KEY in path.read_text(encoding='utf-8', errors='replace'):
            out.append('C5 Release 进包源码含 %s：%s' % (KEY, path.relative_to(root)))
    if RELEASE_BV in facts:
        method = facts[RELEASE_BV]['classes'].get('BuildVariant', {}).get('methods', {}).get('themeNeutralPreset')
        if method is None:
            out.append('C5 release BuildVariant 缺 themeNeutralPreset')
        else:
            if not method['static'] or method['params'] or method['returnType'] != 'SystemNeutralPreset':
                out.append('C5 release themeNeutralPreset 应为 static 无参、返回 SystemNeutralPreset')
            if method['statements'] != ['return SystemNeutralPreset.TOKEN;']:
                out.append('C5 release themeNeutralPreset 方法体应恰为 return SystemNeutralPreset.TOKEN;，实际 %s' % method['statements'])

    # C5b / C6b：真执行（方法缺失时上面已报，这里不重复）
    if MAPPING in texts and facts[MAPPING]['enums'].get('SystemNeutralPreset'):
        for rel, rule, label, system_value in ((RELEASE_BV, 'C5b', 'Release', 'token'), (STAGING_BV, 'C6b', 'staging', 'system')):
            methods = facts[rel]['classes'].get('BuildVariant', {}).get('methods', {}) if rel in facts else {}
            if 'themeNeutralPreset' in methods and 'applyLaunchOptions' in methods:
                out += check_variant_behavior(rule, label, texts[MAPPING], texts[rel], system_value)

    # C6
    if STAGING_BV in facts:
        staging = facts[STAGING_BV]
        methods = staging['classes'].get('BuildVariant', {}).get('methods', {})
        preset = methods.get('themeNeutralPreset')
        if preset is None:
            out.append('C6 staging BuildVariant 缺 themeNeutralPreset')
        elif not preset['static'] or preset['params'] or preset['returnType'] != 'SystemNeutralPreset':
            out.append('C6 staging themeNeutralPreset 应为 static 无参、返回 SystemNeutralPreset')
        apply_method = methods.get('applyLaunchOptions')
        reads = apply_method['paramReads'] if apply_method else []
        names = {name for name, c in staging['consts'].items() if c['value'] == KEY}
        if not any(r.get('literal') == KEY or r.get('identifier') in names for r in reads):
            out.append('C6 applyLaunchOptions 没有用 want.parameters?.[…] 读 %s' % KEY)
        produced = [r for r in staging['refs'] if r['text'] == 'SystemNeutralPreset.SYSTEM' and not r['compared']]
        if not produced:
            out.append('C6 staging BuildVariant 没有任何产出 SystemNeutralPreset.SYSTEM 的分支')
        for ref in produced:
            if not any(g['branch'] == 'then' and 'system' in g['eq'] for g in ref['guards']):
                out.append("C6 第 %d 行的 SystemNeutralPreset.SYSTEM 不在 === 'system' 的真分支里" % ref['line'])
        for cast in staging['casts']:
            if cast['type'] == 'SystemNeutralPreset':
                out.append('C6 第 %d 行不得 as SystemNeutralPreset（外部串要显式比较）' % cast['line'])

    # C7
    scan = read(root, RELEASE_SCAN, out, 'C7')
    if scan is not None:
        markers = markers_in_release_scan(scan)
        if markers is None:
            out.append('C7 没找到 release-scan.sh 的 markers 表')
        elif KEY not in markers:
            out.append('C7 release-scan.sh markers 表缺 %s' % KEY)

    # C8
    for rel in SHELLS:
        if rel not in facts:
            continue
        installs = [c for c in facts[rel]['calls'] if c['callee'] == 'CouliTheme.install']
        if len(installs) != 1 or installs[0]['args'] != ['this.context']:
            out.append('C8 %s 应保持 CouliTheme.install(this.context)，实际 %s' % (rel, [c['args'] for c in installs]))

    # C9
    if LIST in facts:
        if './ThemeBase.test' not in {s['value'] for s in facts[LIST]['strings']}:
            out.append('C9 List.test.ets 没有导入 ./ThemeBase.test')
        if not any(c['callee'] == 'themeBaseTest' for c in facts[LIST]['calls']):
            out.append('C9 List.test.ets 没有调用 themeBaseTest()')
    verify = read(root, VERIFY, out, 'C9')
    if verify is not None:
        code = '\n'.join(line for line in verify.splitlines() if not line.lstrip().startswith('#'))
        order = ['record "ds02-host" PASS', 'check_theme_base.py" --self-test', 'check_theme_base.py" ||',
                 'themebase/run-logic.cjs"', 'themebase/check-arkts.cjs" --real']
        positions = [code.find(p) for p in order]
        if any(p < 0 for p in positions) or positions != sorted(positions):
            out.append('C9 verify.sh 需在 ds02-host 之后依次跑 themebase 的 --self-test、本体、run-logic、check-arkts，实际位置 %s' % positions)
        hap_order = ['record "HM-07v-a 深色入口制品检查"', 'check_theme_base.py" --hap "$OUT_DIR/Release.hap"', 'check_theme_base.py" --hap-staging']
        hap_positions = [code.find(p) for p in hap_order]
        if any(p < 0 for p in hap_positions) or hap_positions != sorted(hap_positions):
            out.append('C9 verify.sh 需在 HM-07v-a 制品步之后跑 --hap / --hap-staging，实际位置 %s' % hap_positions)

    # C10
    if CONTRACTS in facts:
        contract = facts[CONTRACTS]
        fn = contract['functions'].get('buildSystemColors')
        if fn is None or len(fn['params']) != 2 or not fn['params'][1]['optional'] or fn['params'][1]['type'] != 'SystemNeutralPreset':
            out.append('C10 contracts.d.ts 的 buildSystemColors 第二参应为可选 SystemNeutralPreset')
        if 'SystemNeutralPreset' not in contract['enums']:
            out.append('C10 contracts.d.ts 缺 SystemNeutralPreset 声明')
    return out


def hap_contains(hap, needle):
    encodings = [needle.encode('utf-8'), needle.encode('utf-16-le')]
    with zipfile.ZipFile(hap) as z:
        for info in z.infolist():
            data = z.read(info)
            if any(e in data for e in encodings):
                return info.filename
            if info.filename.endswith(('.hap', '.har', '.hsp', '.zip')):
                tmp = Path(tempfile.mkdtemp()) / 'inner.zip'
                tmp.write_bytes(data)
                try:
                    hit = hap_contains(tmp, needle)
                finally:
                    shutil.rmtree(tmp.parent, ignore_errors=True)
                if hit:
                    return info.filename + '!' + hit
    return None


# ---------------------------------------------------------------- 自测：合成合规件 + 错误实现

def self_test():
    roles = json.loads((ROOT / ROLES).read_text(encoding='utf-8'))
    brand = [r for r in roles if r in BRAND]
    neutral = [r for r in roles if r not in BRAND]
    arr = lambda xs: '[' + ', '.join("'%s'" % x for x in xs) + ']'
    mapping = (
        "export enum SystemNeutralPreset { TOKEN = 'token', SYSTEM = 'system' }\n"
        "export const BRAND_ROLES: string[] = %s;\n"
        "export const NEUTRAL_ROLES: string[] = %s;\n"
        "export function buildSystemColors(tokens: Map<string, ResourceColor>,\n"
        "  preset: SystemNeutralPreset = SystemNeutralPreset.TOKEN): CustomColors {\n  return {};\n}\n"
    ) % (arr(brand), arr(neutral))
    colors = (
        "export class CouliColors { static tokenResources(): Map<string, ResourceColor> { return new Map(); } }\n"
        "export class CouliTheme {\n"
        "  static install(context?: common.Context, preset: SystemNeutralPreset = SystemNeutralPreset.TOKEN): void {\n"
        "    ThemeControl.setDefaultTheme({ colors: buildSystemColors(CouliColors.tokenResources(), preset) });\n"
        "  }\n}\n"
    )
    entry = (
        "export default class EntryAbility extends UIAbility {\n"
        "  onNewWant(want: Want): void {\n  }\n"
        "  onWindowStageCreate(windowStage: window.WindowStage): void {\n    this.loadRoot(windowStage);\n  }\n"
        "  private async loadRoot(windowStage: window.WindowStage): Promise<void> {\n"
        "    CouliTheme.install(this.context, BuildVariant.themeNeutralPreset());\n"
        "    windowStage.loadContent('pages/RootPage', () => {});\n"
        "  }\n}\n"
    )
    release = (
        "export class BuildVariant {\n"
        "  static themeNeutralPreset(): SystemNeutralPreset {\n    return SystemNeutralPreset.TOKEN;\n  }\n"
        "  static applyLaunchOptions(context: common.ApplicationContext, want: Want): void {\n  }\n}\n"
    )
    staging = (
        "export class BuildVariant {\n"
        "  private static neutral: SystemNeutralPreset = SystemNeutralPreset.TOKEN;\n"
        "  static themeNeutralPreset(): SystemNeutralPreset {\n    return BuildVariant.neutral;\n  }\n"
        "  static applyLaunchOptions(context: common.ApplicationContext, want: Want): void {\n"
        "    const raw: Object | undefined = want.parameters?.['couli_debug_theme_neutral'];\n"
        "    BuildVariant.neutral = raw === 'system' ? SystemNeutralPreset.SYSTEM : SystemNeutralPreset.TOKEN;\n"
        "  }\n}\n"
    )
    scan = "#!/bin/bash\npython3 - <<'PY'\nmarkers = [\n    \"x\",\n    \"couli_debug_theme_neutral\",\n]\nPY\n"
    suite = 'const NAMES = %s;\n' % arr(roles)
    list_file = "import themeBaseTest from './ThemeBase.test';\nexport default function testsuite() {\n  themeBaseTest();\n}\n"
    verify = (
        'record "ds02-host" PASS\n'
        'python3 "$ROOT/tools/ci/themebase/check_theme_base.py" --self-test || fail_fast a b\n'
        'python3 "$ROOT/tools/ci/themebase/check_theme_base.py" || fail_fast a b\n'
        'node "$ROOT/tools/ci/themebase/run-logic.cjs" || fail_fast a b\n'
        'node "$ROOT/tools/ci/themebase/check-arkts.cjs" --real || fail_fast a b\n'
        'record "HM-07v-a 深色入口制品检查" PASS "x"\n'
        'python3 "$ROOT/tools/ci/themebase/check_theme_base.py" --hap "$OUT_DIR/Release.hap" || fail_fast a b\n'
        'python3 "$ROOT/tools/ci/themebase/check_theme_base.py" --hap-staging "$OUT_DIR/$cfg.hap" || fail_fast a b\n'
    )
    contracts = (
        "export declare enum SystemNeutralPreset { TOKEN = 'token', SYSTEM = 'system' }\n"
        "export declare function buildSystemColors(tokens: Map<string, ResourceColor>, preset?: SystemNeutralPreset): CustomColors;\n"
    )
    shell = "export default class A extends UIAbility {\n  onCreate(): void {\n    CouliTheme.install(this.context);\n  }\n}\n"
    base = {MAPPING: mapping, COLORS: colors, ENTRY: entry, RELEASE_BV: release, STAGING_BV: staging, RELEASE_SCAN: scan, SUITE: suite,
            LIST: list_file, VERIFY: verify, CONTRACTS: contracts, ROLES: json.dumps(roles)}
    for rel in SHELLS:
        base[rel] = shell

    def replace(rel, old, new):
        def apply(files):
            if old not in files[rel]:
                raise SystemExit('自测变异没对上：%s %r' % (rel, old))
            files[rel] = files[rel].replace(old, new)
        return apply

    def add(rel, text):
        def apply(files):
            files[rel] = text
        return apply

    moved_brand = arr(neutral + ['brand'])
    mutants = [
        ('C3', '映射默认改 SYSTEM', replace(MAPPING, 'preset: SystemNeutralPreset = SystemNeutralPreset.TOKEN', 'preset: SystemNeutralPreset = SystemNeutralPreset.SYSTEM')),
        ('C3', '映射第二参没有缺省', replace(MAPPING, 'preset: SystemNeutralPreset = SystemNeutralPreset.TOKEN', 'preset?: SystemNeutralPreset')),
        ('C3', '枚举值改写', replace(MAPPING, "SYSTEM = 'system'", "SYSTEM = 'sys'")),
        ('C3', '枚举多一个成员', replace(MAPPING, "SYSTEM = 'system' }", "SYSTEM = 'system', MIX = 'mix' }")),
        ('C4', '漏一个中性角色', replace(MAPPING, "'%s'" % neutral[-1], "'%s'" % neutral[-2])),
        ('C4', '品牌角色误入中性表', replace(MAPPING, 'NEUTRAL_ROLES: string[] = ' + arr(neutral), 'NEUTRAL_ROLES: string[] = ' + moved_brand)),
        ('C4', '中性角色误入品牌表（换位）', replace(MAPPING, "'%s', '%s'" % (brand[0], brand[1]), "'%s', '%s'" % (neutral[0], brand[1]))),
        ('C4', '表不导出', replace(MAPPING, 'export const BRAND_ROLES', 'const BRAND_ROLES')),
        ('C4', '表元素不是字面量', replace(MAPPING, "'%s'" % brand[0], 'ROLE_BRAND')),
        ('C1', 'install 不传第二参', replace(ENTRY, 'CouliTheme.install(this.context, BuildVariant.themeNeutralPreset())', 'CouliTheme.install(this.context)')),
        ('C1', 'install 写死 SYSTEM', replace(ENTRY, 'BuildVariant.themeNeutralPreset()', 'SystemNeutralPreset.SYSTEM')),
        ('C1', 'install 挪到 loadContent 之后', replace(ENTRY,
            "    CouliTheme.install(this.context, BuildVariant.themeNeutralPreset());\n    windowStage.loadContent('pages/RootPage', () => {});\n",
            "    windowStage.loadContent('pages/RootPage', () => {});\n    CouliTheme.install(this.context, BuildVariant.themeNeutralPreset());\n")),
        ('C1', 'install 挪到 onNewWant（热启动重装）', replace(ENTRY,
            "  onNewWant(want: Want): void {\n  }\n",
            "  onNewWant(want: Want): void {\n    CouliTheme.install(this.context, BuildVariant.themeNeutralPreset());\n  }\n")),
        ('C1', '多一处生产调用（feature 里）', add('features/me/src/main/ets/X.ets', "export function f(c: common.Context): void {\n  CouliTheme.install(c);\n}\n")),
        ('C2', 'install 不透传', replace(COLORS, 'buildSystemColors(CouliColors.tokenResources(), preset)', 'buildSystemColors(CouliColors.tokenResources())')),
        ('C2', 'install 缺省 SYSTEM', replace(COLORS, 'preset: SystemNeutralPreset = SystemNeutralPreset.TOKEN', 'preset: SystemNeutralPreset = SystemNeutralPreset.SYSTEM')),
        ('C2', 'install 第二参必填', replace(COLORS, 'preset: SystemNeutralPreset = SystemNeutralPreset.TOKEN', 'preset: SystemNeutralPreset')),
        ('C5', 'Release 带参数名', replace(RELEASE_BV, 'export class BuildVariant {', "const K = 'couli_debug_theme_neutral';\nexport class BuildVariant {")),
        ('C5', 'main 源码集带参数名', add('entry/src/main/ets/Y.ets', "export const K = 'couli_debug_theme_neutral';\n")),
        ('C5', 'feature 带参数名', add('features/me/src/main/ets/Z.ets', "export const K = 'couli_debug_theme_neutral';\n")),
        ('C5', 'Release 返回 SYSTEM', replace(RELEASE_BV, 'return SystemNeutralPreset.TOKEN;', 'return SystemNeutralPreset.SYSTEM;')),
        ('C5', 'Release 缺方法', replace(RELEASE_BV, 'static themeNeutralPreset(): SystemNeutralPreset {\n    return SystemNeutralPreset.TOKEN;\n  }\n', '')),
        ('C6', 'staging 缺方法', replace(STAGING_BV, 'static themeNeutralPreset(): SystemNeutralPreset {\n    return BuildVariant.neutral;\n  }\n', '')),
        ('C6', 'staging 不读参数', replace(STAGING_BV, "want.parameters?.['couli_debug_theme_neutral']", "want.parameters?.['other']")),
        ('C6', 'staging 默认 SYSTEM', replace(STAGING_BV, 'neutral: SystemNeutralPreset = SystemNeutralPreset.TOKEN', 'neutral: SystemNeutralPreset = SystemNeutralPreset.SYSTEM')),
        ('C6', 'staging 其他值也算 SYSTEM', replace(STAGING_BV, "raw === 'system' ? SystemNeutralPreset.SYSTEM : SystemNeutralPreset.TOKEN", "raw === 'token' ? SystemNeutralPreset.TOKEN : SystemNeutralPreset.SYSTEM")),
        ('C6', 'staging 强转外部串', replace(STAGING_BV, "raw === 'system' ? SystemNeutralPreset.SYSTEM : SystemNeutralPreset.TOKEN", "raw as SystemNeutralPreset")),
        ('C6b', 'staging 开关失效：themeNeutralPreset 恒 TOKEN（评审 M07）', replace(STAGING_BV, 'return BuildVariant.neutral;', 'return SystemNeutralPreset.TOKEN;')),
        ('C6b', "staging 复合条件：'token' 也算 SYSTEM（评审 M08）", replace(STAGING_BV, "raw === 'system' ?", "raw === 'system' || raw === 'token' ?")),
        ('C6b', 'staging 算出结果但没存到字段', replace(STAGING_BV, 'BuildVariant.neutral = raw', 'const chosen: SystemNeutralPreset = raw')),
        ('C6b', 'staging 放宽大小写', replace(STAGING_BV, "raw === 'system' ?", "String(raw).toLowerCase() === 'system' ?")),
        ('C6b', 'staging 默认字段是 SYSTEM', replace(STAGING_BV, 'neutral: SystemNeutralPreset = SystemNeutralPreset.TOKEN', 'neutral: SystemNeutralPreset = SystemNeutralPreset.SYSTEM')),
        ('C5b', 'Release 真执行得到 SYSTEM', replace(RELEASE_BV, 'return SystemNeutralPreset.TOKEN;', 'return SystemNeutralPreset.SYSTEM;')),
        ('C7', 'release-scan 缺标记', replace(RELEASE_SCAN, '    "couli_debug_theme_neutral",\n', '')),
        ('C7', 'release-scan 标记只在注释里', replace(RELEASE_SCAN, '    "couli_debug_theme_neutral",\n', '    # "couli_debug_theme_neutral",\n')),
        ('C8', '测试壳改成传 SYSTEM', replace(SHELLS[0], 'CouliTheme.install(this.context)', 'CouliTheme.install(this.context, SystemNeutralPreset.SYSTEM)')),
        ('C9', '套件少角色名', replace(SUITE, "'%s'" % roles[-1], "'x'")),
        ('C9', 'List 没导入', replace(LIST, "import themeBaseTest from './ThemeBase.test';\n", '')),
        ('C9', 'List 没调用', replace(LIST, '  themeBaseTest();\n', '')),
        ('C9', 'verify 步骤放到 ds02-host 之前', lambda f: f.__setitem__(VERIFY, f[VERIFY].replace('record "ds02-host" PASS\n', '') + 'record "ds02-host" PASS\n')),
        ('C9', 'verify 被注释掉', replace(VERIFY, 'python3 "$ROOT/tools/ci/themebase/check_theme_base.py" || fail_fast a b\n', '# python3 "$ROOT/tools/ci/themebase/check_theme_base.py" || fail_fast a b\n')),
        ('C9', 'verify 缺 hap 步', replace(VERIFY, 'python3 "$ROOT/tools/ci/themebase/check_theme_base.py" --hap-staging "$OUT_DIR/$cfg.hap" || fail_fast a b\n', '')),
        ('C10', 'contracts.d.ts 仍单参', replace(CONTRACTS, ', preset?: SystemNeutralPreset', '')),
        ('C0', '映射文件语法坏', replace(MAPPING, 'export function buildSystemColors(', 'export function buildSystemColors((')),
    ]

    def materialize(files, target):
        for rel, text in files.items():
            path = target / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8')

    survivors = 0
    with tempfile.TemporaryDirectory(prefix='themebase-selftest-') as tmp:
        tmp_path = Path(tmp)
        reference = tmp_path / 'reference'
        materialize(base, reference)
        problems = check_tree(reference)
        if problems:
            print('参照件应当 0 违反，实际：')
            for p in problems:
                print('  ' + p)
            return 1
        print('OK 参照件 0 违反')
        for index, (rule, name, mutate) in enumerate(mutants):
            files = dict(base)
            mutate(files)
            target = tmp_path / ('m%02d' % index)
            materialize(files, target)
            problems = check_tree(target)
            hit = [p for p in problems if p.startswith(rule + ' ')]
            if hit:
                print('KILLED %-3s %s' % (rule, name))
            else:
                survivors += 1
                print('SURVIVED %s %s：%s' % (rule, name, problems))
        release_hap = tmp_path / 'clean.hap'
        with zipfile.ZipFile(release_hap, 'w') as z:
            z.writestr('ets/modules.abc', b'nothing here')
        dirty_inner = tmp_path / 'inner.har'
        with zipfile.ZipFile(dirty_inner, 'w') as z:
            z.writestr('a.abc', KEY.encode('utf-16-le'))
        dirty_hap = tmp_path / 'dirty.hap'
        with zipfile.ZipFile(dirty_hap, 'w') as z:
            z.writestr('lib/inner.har', dirty_inner.read_bytes())
        if hap_contains(release_hap, KEY) is not None or hap_contains(dirty_hap, KEY) is None:
            survivors += 1
            print('SURVIVED hap 扫描')
        else:
            print('KILLED hap 内层压缩包 / utf-16 命中，干净包不命中')
    print('THEMEBASE --self-test: %d 个错误实现，%d 个未被拦下' % (len(mutants) + 1, survivors))
    return 1 if survivors else 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    if '--hap' in argv:
        hap = argv[argv.index('--hap') + 1]
        hit = hap_contains(hap, KEY)
        if hit:
            print('Release 制品含 %s：%s' % (KEY, hit))
            return 1
        print('OK Release 制品不含 %s' % KEY)
        return 0
    if '--hap-staging' in argv:
        hap = argv[argv.index('--hap-staging') + 1]
        if hap_contains(hap, KEY) is None:
            print('Staging / Debug 制品缺 %s' % KEY)
            return 1
        print('OK Staging / Debug 制品含 %s' % KEY)
        return 0
    root = Path(argv[argv.index('--root') + 1]).resolve() if '--root' in argv else ROOT
    problems = check_tree(root)
    for line in problems:
        print(line)
    print('THEMEBASE host: %d 项违反（%s）' % (len(problems), root))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
