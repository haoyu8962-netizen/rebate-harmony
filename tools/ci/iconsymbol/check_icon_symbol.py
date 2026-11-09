#!/usr/bin/env python3
"""FU-HM-ICON-SYMBOL-harmony 测试作者 v1：CouliIcon 通用名换系统符号的宿主检查（Python 3 标准库 + SDK ohos-typescript，见 icon_ast.cjs）。

依据：NATIVE/FU-HM-ICON-SYMBOL/brief-harmony.md §2.1、§2.2、§3.1、§3.4、§4；裁定 D10-1153（filter / trend 留 Path）。.ets 一律走 AST，不用正则。

  I0  关键文件解析不完整即红
  I1-names  logic/CouliIconNames.ets：SYMBOL_ICON_NAMES（34）/ PATH_ICON_NAMES（10）顶层导出、字面量数组、无重复、与本文件钉的表一致，无 import、无 $r；Logic.ets 导出两者
  I1-switch couliSymbolOf（CouliIcon.ets 顶层）恰一个 switch，分支 = SYMBOL_ICON_NAMES = 钉的 34 名；$r 实参全是 'sys.symbol.*' 字面量；返回类型 Resource | undefined
  I1-map    真执行 couliSymbolOf（icon_ast.cjs 切出原文）：34 名各得任务书 §2.2 的符号；10 个自有名与未知名得 undefined、不抛错
  I1-sdk    34 个符号与 switch 里的每个 $r 都在 SDK sysResource.js 的 sys.symbol 表里
  I2-tab    Navigation.ets 底栏映射 home / chat / orders / user / search 的 normal 符号 = 本表同名项。TAB-BAR 未合（TabBar 仍画 CouliIcon、没有 BottomTabBarStyle）时 SKIP；
            一旦合入却读不出映射就是违反（不静默跳过）。--require-tabbar：未合也算违反（批 1 冻结用）
  I3-table  CouliIconPaths 路径表恰为 10 个自有名（34 名不得残留、自有项不得删）；scalePath 与 ICON_VIEWPORT / ICON_STROKE 保留
  I4-glyph  CouliIcon 的 build：唯一 SymbolGlyph(couliSymbolOf(this.name)) 在 if (couliSymbolOf(this.name) !== undefined) 真分支，.fontSize(this.iconSize + 'vp')（vp，无 fp），
            .fontColor([this.color])，.accessibilityLevel('no')，无符号动效
  I4-path   else 分支是唯一 ForEach(CouliIconPaths.get(this.name), …)，Path 写法与现行逐项相同（尺寸、缩放、fill、stroke 跟随 color、线帽）
  I4-shell  外层 Stack 宽高跟 iconSize、accessibilityLevel('no')；@Param name / iconSize / color 的名字、类型、缺省不变；struct 仍 @ComponentV2、export
  I5 全部只在本单模式跑（D10-1168）：--ticket 或 --base <rev>。不带这两个参数 = 常驻模式（verify.sh 用），I5 不判，其余规则不变。
  I5-count  生产调用点 CouliIcon( ≥ 113（TAB-BAR 合入后 Navigation 的 2 处按书换掉，门槛 111），staging ≥ 14（AST 计数，注释不算）；
  I5-import 59c1976 上 import 了 CouliIcon 的文件仍 import（TAB-BAR 合入后的 Navigation.ets 除外）；Index.ets 仍导出 CouliIcon、CouliIconPaths
  I5-base   仅 --base <rev>：相对该提交，页面与组件目录只改了 CouliIcon.ets、新增 logic/CouliIconNames.ets（任务书 §4 红线）
  I6-wiring IconSymbol.test.ets 含 44 个名字；List.test.ets 导入并调用 iconSymbolTest；verify.sh 在 ds02-host 之后依次跑本检查 --self-test、本检查（常驻模式：
            不带参数，或批 1 冻结后带 --require-tabbar；带 --ticket / --base 算违反）、run-logic.cjs、check-arkts.cjs

用法：
  python3 tools/ci/iconsymbol/check_icon_symbol.py                 本仓库，常驻模式：不判 I5（违反即退出 1）
  python3 tools/ci/iconsymbol/check_icon_symbol.py --ticket        本单模式：加判 I5-count、I5-import（本单提交时跑）
  python3 tools/ci/iconsymbol/check_icon_symbol.py --self-test     合成合规件 0 违反、每个错误实现被对应条目打红（REFERENCE_ONLY，不算产品通过）
  python3 tools/ci/iconsymbol/check_icon_symbol.py --root <目录>    查别的目录
  python3 tools/ci/iconsymbol/check_icon_symbol.py --base <rev>     本单模式，再加 I5-base 页面零改动（任务书 §4）
  python3 tools/ci/iconsymbol/check_icon_symbol.py --require-tabbar 批 1 冻结用：TAB-BAR 没合也算违反
  python3 tools/ci/iconsymbol/check_icon_symbol.py --dump-callsites 打印调用点计数（生成 callsites-59c1976.json 用）
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AST = Path(__file__).with_name('icon_ast.cjs')
BASELINE = Path(__file__).with_name('callsites-59c1976.json')

DS = 'common/designsystem'
ICON = DS + '/src/main/ets/components/CouliIcon.ets'
NAMES = DS + '/src/main/ets/logic/CouliIconNames.ets'
NAV = DS + '/src/main/ets/components/Navigation.ets'
LOGIC = DS + '/Logic.ets'
INDEX = DS + '/Index.ets'
SUITE = DS + '/src/test/IconSymbol.test.ets'
LIST = DS + '/src/test/List.test.ets'
VERIFY = 'tools/ci/verify.sh'
SKIP_DIRS = {'build', 'oh_modules', 'node_modules', '.hvigor', '.preview'}

# 任务书 §2.2：系统符号 34 个（名字 → sys.symbol）。
SYMBOLS = {
    'home': 'house', 'chat': 'ellipsis_message', 'orders': 'doc_plaintext', 'user': 'person', 'search': 'magnifyingglass',
    'back': 'arrow_left', 'chevron': 'chevron_right', 'chevron-down': 'chevron_down', 'close': 'xmark', 'eye': 'eye',
    'eye-off': 'eye_slash', 'clock': 'clock', 'thumb-up': 'hand_thumbsup', 'thumb-down': 'hand_thumbsdown', 'check': 'checkmark_circle',
    'alert': 'exclamationmark_triangle', 'info': 'info_circle', 'copy': 'rectangle_on_rectangle', 'settings': 'gearshape', 'doc': 'doc_text',
    'shield': 'checkmark_shield', 'card': 'creditcard', 'help': 'questionmark_circle', 'wallet': 'wallet', 'ledger': 'list_bullet',
    'find-order': 'doc_text_badge_magnifyingglass', 'user-plus': 'person_badge_plus', 'heart': 'heart', 'headset': 'headphones', 'link': 'link',
    'bell': 'bell', 'star': 'star', 'merge': 'arrow_triangle_merge', 'image': 'picture',
}
# 任务书 §2.2：保留 Path 的 10 个自有名（D10-1153：filter / trend 留 Path）。
OWN = ['category.supermarket', 'category.fresh', 'category.baby', 'category.beauty', 'category.household', 'category.electronics',
       'guide', 'clipboard', 'filter', 'trend']
TAB_NAMES = ['home', 'chat', 'orders', 'user', 'search']
UNKNOWN = ['', ' ', 'nope', 'HOME', ' home', 'home ', 'house', 'sys.symbol.house', 'chevron_right', 'chevron-up', 'eye_off', 'category.', 'category.unknown', 'FILTER']

PATH_CHAIN = [
    ('width', ['this.iconSize']), ('height', ['this.iconSize']), ('commands', ['scalePath(cmd, this.factor())']), ('fill', ['Color.Transparent']),
    ('stroke', ['this.color']), ('strokeWidth', ['ICON_STROKE * this.iconSize / ICON_VIEWPORT']), ('strokeLineCap', ['LineCapStyle.Round']),
    ('strokeLineJoin', ['LineJoinStyle.Round']),
]
PATH_KEY = '(cmd: string, index: number) => index + cmd'
PARAMS = {
    'name': (['Param'], 'string', "'info'"),
    'iconSize': (['Param'], 'number', '24'),
    'color': (['Param'], 'ResourceColor', 'CouliColors.textPrimary'),
}
VP_FORMS = {"this.iconSize + 'vp'", 'this.iconSize + "vp"', '`${this.iconSize}vp`'}
ALLOWED_CHANGES = {ICON, NAMES}
BASE_SCOPE = ['features', 'entry/src/main', 'entry/src/staging', DS + '/src/main/ets', INDEX]
PRODUCTION_FLOOR = 113
TABBAR_REPLACED_CALLS = 2  # Navigation.ets 的 TabBar 里两处 CouliIcon，TAB-BAR 单换成 BottomTabBarStyle 后消失。
# verify.sh 常驻步认这两种写法（批 1 冻结时加 --require-tabbar，D10-1168）；带 --ticket / --base 都对不上，I6 报红。
RESIDENT_LINES = ['check_icon_symbol.py" ||', 'check_icon_symbol.py" --require-tabbar ||']


def parse_all(items, symbols_override):
    files = []
    for name, text, evals in items:
        entry = {'name': name, 'text': text}
        if evals is not None:
            entry['evalNames'] = evals
        files.append(entry)
    result = subprocess.run(['node', str(AST)], input=json.dumps({'files': files}), capture_output=True, text=True, timeout=180)
    if result.returncode != 0:
        raise SystemExit('icon_ast.cjs 失败（SDK 找不到或解析器出错，不算通过）：' + result.stderr)
    parsed = json.loads(result.stdout)
    if len(parsed['files']) != len(items):
        raise SystemExit('icon_ast.cjs 返回条数不对')
    table = set(parsed['symbols']) if symbols_override is None else set(symbols_override)
    return table, dict(zip([n for n, _, _ in items], parsed['files']))


def walk(base):
    if not base.is_dir():
        return
    for path in sorted(base.rglob('*.ets')):
        if path.is_file() and not (SKIP_DIRS & set(p.name for p in path.relative_to(base).parents)):
            yield path


def module_dirs(root, group):
    base = root / group
    return sorted(p for p in base.iterdir() if p.is_dir()) if base.is_dir() else []


def source_groups(root):
    production = [root / 'entry/src/main', root / DS / 'src/main'] + [d / 'src/main' for d in module_dirs(root, 'features')]
    return production, [root / 'entry/src/staging']


def norm(text):
    return ' '.join(text.split())


def scan_sources(root):
    """(相对路径 → 原文, 生产集合, staging 集合)；只收含 CouliIcon 字样的文件，AST 再数真实调用。"""
    production, staging = source_groups(root)
    texts, prod, stag = {}, set(), set()
    for folders, bucket in ((production, prod), (staging, stag)):
        for folder in folders:
            for path in walk(folder):
                text = path.read_text(encoding='utf-8')
                if 'CouliIcon' in text:
                    rel = str(path.relative_to(root))
                    texts[rel] = text
                    bucket.add(rel)
    return texts, prod, stag


def read(root, rel, out, rule):
    path = root / rel
    if not path.is_file():
        out.append('%s 缺文件 %s' % (rule, rel))
        return None
    return path.read_text(encoding='utf-8')


def changed_files(root, base):
    """相对 base 的已跟踪改动 + 未跟踪新增。"""
    def git(*args):
        result = subprocess.run(['git', '-C', str(root)] + list(args), capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit('git 失败：' + result.stderr)
        return [line for line in result.stdout.splitlines() if line]
    return sorted(set(git('diff', '--name-only', base, '--', *BASE_SCOPE)) | set(git('ls-files', '--others', '--exclude-standard', '--', *BASE_SCOPE)))


def check_tree(root, symbols_override=None, require_tab=False, base=None, ticket=False):
    """返回 (违反, 说明)。ticket / base 都没给 = 常驻模式，I5 不判（D10-1168）。"""
    out, notes = [], []
    rules = {ICON: 'I1-switch', NAMES: 'I1-names', NAV: 'I2-tab', LOGIC: 'I1-names', INDEX: 'I5-import', SUITE: 'I6-wiring', LIST: 'I6-wiring'}
    texts = {}
    for rel, rule in rules.items():
        text = read(root, rel, out, rule)
        if text is not None:
            texts[rel] = text
    sources, production, staging = scan_sources(root)
    probe = list(SYMBOLS) + OWN + UNKNOWN
    items = [(rel, text, probe if rel == ICON else None) for rel, text in texts.items()]
    items += [(rel, text, None) for rel, text in sources.items() if rel not in texts]
    table, facts = parse_all(items, symbols_override)
    for rel, fact in facts.items():
        if fact['incomplete']:
            out.append('I0 %s 解析不完整：%s' % (rel, fact['incomplete']))
    if any(v.startswith('I0 ') for v in out):
        return out, notes

    expected_names = set(SYMBOLS)
    names_fact = facts.get(NAMES)
    symbol_names = None
    if names_fact:
        tables = {}
        for const, pinned in (('SYMBOL_ICON_NAMES', expected_names), ('PATH_ICON_NAMES', set(OWN))):
            entry = names_fact['consts'].get(const)
            if entry is None or not entry['exported']:
                out.append('I1-names 缺顶层 export const %s' % const)
                continue
            elements = entry['elements']
            if elements is None or any(e is None for e in elements):
                out.append('I1-names %s 必须是字符串字面量组成的数组字面量' % const)
                continue
            if len(elements) != len(set(elements)):
                out.append('I1-names %s 有重复名字' % const)
            if set(elements) != pinned:
                out.append('I1-names %s 与任务书 §2.2 不一致：缺 %s，多 %s' % (const, sorted(pinned - set(elements)), sorted(set(elements) - pinned)))
            tables[const] = set(elements)
        if 'SYMBOL_ICON_NAMES' in tables:
            symbol_names = tables['SYMBOL_ICON_NAMES']
        if len(tables) == 2 and tables['SYMBOL_ICON_NAMES'] & tables['PATH_ICON_NAMES']:
            out.append('I1-names 两张表相交：%s' % sorted(tables['SYMBOL_ICON_NAMES'] & tables['PATH_ICON_NAMES']))
        if names_fact['imports'] or names_fact['dollarR']:
            out.append('I1-names CouliIconNames.ets 必须是纯逻辑（无 import、无 $r）')
    if LOGIC in facts:
        exported = [e for e in facts[LOGIC]['exports'] if e['module'].endswith('logic/CouliIconNames')]
        have = set(n for e in exported for n in e['names'])
        if not {'SYMBOL_ICON_NAMES', 'PATH_ICON_NAMES'} <= have:
            out.append('I1-names Logic.ets 没有从 logic/CouliIconNames 导出两张表，实际 %s' % sorted(have))

    icon = facts.get(ICON)
    if icon is not None:
        fn = icon.get('symbolFn')
        if fn is None:
            out.append('I1-switch CouliIcon.ets 缺顶层函数 couliSymbolOf')
        else:
            if fn['returnType'] is None or norm(fn['returnType']) != 'Resource | undefined':
                out.append('I1-switch couliSymbolOf 返回类型应为 Resource | undefined，实际 %s' % fn['returnType'])
            if len(fn['switches']) != 1 or len(fn['params']) != 1 or fn['switches'][0]['on'] != fn['params'][0]:
                out.append('I1-switch couliSymbolOf 应恰有一个按名字参数的 switch，实际 %s' % fn['switches'])
            else:
                labels = fn['switches'][0]['labels']
                if any(label is None for label in labels) or len(labels) != len(set(labels)):
                    out.append('I1-switch switch 分支必须是不重复的字符串字面量：%s' % labels)
                label_set = set(label for label in labels if label is not None)
                if label_set != expected_names:
                    out.append('I1-switch switch 分支与 34 名不一致：缺 %s，多 %s' % (sorted(expected_names - label_set), sorted(label_set - expected_names)))
                if symbol_names is not None and label_set != symbol_names:
                    out.append('I1-switch switch 分支与 SYMBOL_ICON_NAMES 不一致：%s' % sorted(label_set ^ symbol_names))
            for resource in fn['resources']:
                if resource is None or not resource.startswith('sys.symbol.'):
                    out.append("I1-switch $r 实参必须是 'sys.symbol.*' 字面量，实际 %s" % resource)
                elif resource[len('sys.symbol.'):] not in table:
                    out.append('I1-sdk SDK sysResource.js 没有 %s' % resource)
            evaluated = icon.get('symbolEval')
            if evaluated is None:
                out.append('I1-map couliSymbolOf 没有被执行')
            elif 'error' in evaluated:
                out.append('I1-map couliSymbolOf 无法执行：%s' % evaluated['error'])
            else:
                results = evaluated['results']
                for name, symbol in SYMBOLS.items():
                    if results.get(name) != 'sys.symbol.' + symbol:
                        out.append('I1-map %s 应映射到 sys.symbol.%s，实际 %s' % (name, symbol, results.get(name)))
                for name in OWN + UNKNOWN:
                    if results.get(name) is not None:
                        kind = '抛错' if str(results.get(name)).startswith('THROW') else '有符号'
                        out.append('I1-map %r 应返回 undefined（走路径表），实际%s：%s' % (name, kind, results.get(name)))
        for symbol in SYMBOLS.values():
            if symbol not in table:
                out.append('I1-sdk SDK sysResource.js 没有 sys.symbol.%s（任务书 §2.2 表要改）' % symbol)

        # I3
        cls = icon['classes'].get('CouliIconPaths')
        if cls is None or not cls['exported']:
            out.append('I3-table 缺 export class CouliIconPaths')
        else:
            if any(n is None for n in cls['sets']):
                out.append('I3-table 路径表的名字必须是字面量')
            table_names = set(n for n in cls['sets'] if n is not None)
            lost = set(OWN) - table_names
            extra = table_names - set(OWN)
            if lost:
                out.append('I3-table 路径表丢了自有名：%s' % sorted(lost))
            if extra:
                out.append('I3-table 路径表多留了名字（通用名要删，防止两套都留）：%s' % sorted(extra))
            if len(cls['sets']) != len(set(cls['sets'])):
                out.append('I3-table 路径表有重复写入')
        if not icon['functions'].get('scalePath', {}).get('exported'):
            out.append('I3-table scalePath 必须保留并 export（自有图标还在用）')
        for const in ('ICON_VIEWPORT', 'ICON_STROKE'):
            if const not in icon['consts']:
                out.append('I3-table 常量 %s 必须保留' % const)

        # I4
        struct = icon['structs'].get('CouliIcon')
        if struct is None or not struct['exported'] or 'ComponentV2' not in struct['decorators']:
            out.append('I4-shell 缺 @ComponentV2 export struct CouliIcon')
        else:
            for name, (decorators, type_text, init) in PARAMS.items():
                param = struct['params'].get(name)
                if param is None or param['decorators'] != decorators or param['type'] != type_text or param['init'] != init:
                    out.append('I4-shell @Param %s 应为 %s = %s，实际 %s' % (name, type_text, init, param))
            render = struct['render']
            if render is None or render['stack'] is None or render['stack']['root'] != 'Stack':
                out.append('I4-shell build 根节点应为 Stack')
            else:
                shell = dict((c['name'], c['args']) for c in render['stack']['chain'])
                for attr, args in (('width', ['this.iconSize']), ('height', ['this.iconSize']), ('accessibilityLevel', ["'no'"])):
                    if shell.get(attr) != args:
                        out.append('I4-shell Stack.%s 应为 %s，实际 %s' % (attr, args, shell.get(attr)))
                counts = render['counts']
                for component in ('SymbolGlyph', 'ForEach', 'Path'):
                    if counts.get(component, 0) != 1:
                        out.append('I4-%s build 里 %s 应恰 1 处，实际 %d' % ('glyph' if component == 'SymbolGlyph' else 'path', component, counts.get(component, 0)))
                condition = render['condition']
                if condition is None or norm(condition) != 'couliSymbolOf(this.name) !== undefined':
                    out.append('I4-glyph Stack 里应是唯一的 if (couliSymbolOf(this.name) !== undefined)，实际 %s（子节点 %d 个）' % (condition, render['children']))
                glyph = render['thenGlyph']
                if glyph is None or glyph['root'] != 'SymbolGlyph' or glyph['args'] != ['couliSymbolOf(this.name)']:
                    out.append('I4-glyph 真分支应为 SymbolGlyph(couliSymbolOf(this.name))，实际 %s' % (glyph and (glyph['root'], glyph['args'])))
                else:
                    attrs = dict((c['name'], c['args']) for c in glyph['chain'])
                    size = attrs.get('fontSize')
                    if size is None or len(size) != 1 or norm(size[0]) not in VP_FORMS:
                        out.append("I4-glyph SymbolGlyph.fontSize 应为 this.iconSize + 'vp'（数字默认 fp），实际 %s" % size)
                    if attrs.get('fontColor') != ['[this.color]']:
                        out.append('I4-glyph SymbolGlyph.fontColor 应为 [this.color]，实际 %s' % attrs.get('fontColor'))
                    if attrs.get('accessibilityLevel') != ["'no'"]:
                        out.append("I4-glyph SymbolGlyph.accessibilityLevel 应为 'no'，实际 %s" % attrs.get('accessibilityLevel'))
                    for attr in ('symbolEffect', 'effectStrategy'):
                        if attr in attrs:
                            out.append('I4-glyph 本单不做符号动效，不许 .%s' % attr)
                    fp = [c['name'] for c in glyph['chain'] for a in c['args'] if 'fp' in a]
                    if fp:
                        out.append('I4-glyph SymbolGlyph 不许用 fp：%s' % fp)
                each = render['elseForEach']
                if each is None or each['root'] != 'ForEach' or len(each['args']) != 3 or each['args'][0] != 'CouliIconPaths.get(this.name)' or norm(each['args'][2]) != PATH_KEY:
                    out.append('I4-path else 分支应为 ForEach(CouliIconPaths.get(this.name), …, %s)，实际 %s' % (PATH_KEY, each and each['args']))
                path_node = render['path']
                actual = None if path_node is None or path_node['root'] != 'Path' else [(c['name'], [norm(a) for a in c['args']]) for c in path_node['chain']]
                if actual != PATH_CHAIN:
                    out.append('I4-path Path 写法与现行不同（描边、线帽、着色跟 color）：%s' % actual)

    # I2
    tab_merged = False
    if NAV in facts:
        nav = facts[NAV]
        tab_calls = [c for c in nav['couliIconCalls'] if c['enclosing'].startswith('TabBar')]
        tab_merged = not (tab_calls and 'BottomTabBarStyle' not in nav['identifiers'])
        if not tab_merged:
            if require_tab:
                out.append('I2-tab --require-tabbar：TAB-BAR 还没合（TabBar 仍画 CouliIcon），批 1 冻结前必须合入')
            else:
                notes.append('SKIP I2-tab：TAB-BAR 未合（TabBar 仍画 CouliIcon、无 BottomTabBarStyle）；合入后自动生效，未合时不判 5 个同名符号（任务书 §3.1-2）')
        else:
            mapped = nav['tabSymbols']
            if mapped is None:
                out.append('I2-tab Navigation.ets 已是 TAB-BAR 形态，但读不出底栏映射（期望模块级 switch，分支返回 { normal: $r(...), selected: ... }）')
            else:
                for name in TAB_NAMES:
                    expected = 'sys.symbol.' + SYMBOLS[name]
                    actual = mapped['normal'].get(name)
                    if actual != expected:
                        out.append('I2-tab 底栏 %s 的 normal 符号应为 %s（与 CouliIcon 同名同符号），实际 %s' % (name, expected, actual))

    # I5
    calls_production = sum(len(facts[rel]['couliIconCalls']) for rel in production if rel in facts)
    calls_staging = sum(len(facts[rel]['couliIconCalls']) for rel in staging if rel in facts)
    floor = PRODUCTION_FLOOR - (TABBAR_REPLACED_CALLS if tab_merged else 0)
    if calls_production < floor:
        out.append('I5-count 生产调用点 CouliIcon( 应 ≥ %d，实际 %d（页面零改动，见任务书 §3.1-5）' % (floor, calls_production))
    baseline = json.loads(BASELINE.read_text(encoding='utf-8'))
    if calls_staging < sum(baseline['staging'].values()):
        out.append('I5-count staging 调用点 CouliIcon( 应 ≥ %d，实际 %d' % (sum(baseline['staging'].values()), calls_staging))
    for rel in list(baseline['production']) + list(baseline['staging']):
        if tab_merged and rel == NAV:
            continue
        fact = facts.get(rel)
        if fact is None or not any('CouliIcon' in i['names'] for i in fact['imports']):
            out.append('I5-import %s 在 59c1976 导入了 CouliIcon，现在没有了（页面不许顺手改）' % rel)
    if INDEX in facts:
        have = set(n for e in facts[INDEX]['exports'] if e['module'].endswith('components/CouliIcon') for n in e['names'])
        if not {'CouliIcon', 'CouliIconPaths'} <= have:
            out.append('I5-import Index.ets 必须继续导出 CouliIcon、CouliIconPaths，实际 %s' % sorted(have))
    if base is not None:
        extra = [rel for rel in changed_files(root, base) if rel not in ALLOWED_CHANGES]
        if extra:
            out.append('I5-base 相对 %s 不该改的文件：%s' % (base, extra))

    # I6
    if SUITE in facts:
        missing = sorted((expected_names | set(OWN)) - set(facts[SUITE]['strings']))
        if missing:
            out.append('I6-wiring IconSymbol.test.ets 缺名字：%s' % missing)
    if LIST in facts:
        if './IconSymbol.test' not in [i['module'] for i in facts[LIST]['imports']]:
            out.append('I6-wiring List.test.ets 没有导入 ./IconSymbol.test')
        if 'iconSymbolTest' not in facts[LIST]['callees']:
            out.append('I6-wiring List.test.ets 没有调用 iconSymbolTest()')
    verify = read(root, VERIFY, out, 'I6-wiring')
    if verify is not None:
        code = '\n'.join(line for line in verify.splitlines() if not line.lstrip().startswith('#'))
        resident = next((p for p in RESIDENT_LINES if p in code), RESIDENT_LINES[0])
        order = ['record "ds02-host" PASS', 'check_icon_symbol.py" --self-test', resident, 'iconsymbol/run-logic.cjs"', 'iconsymbol/check-arkts.cjs" --real']
        positions = [code.find(p) for p in order]
        if any(p < 0 for p in positions) or positions != sorted(positions):
            out.append('I6-wiring verify.sh 需在 ds02-host 之后依次跑 iconsymbol 的 --self-test、本体、run-logic、check-arkts，实际位置 %s' % positions)
    if not (ticket or base is not None):
        out = [v for v in out if not v.startswith('I5-')]
    return out, notes


def dump_callsites(root):
    sources, production, staging = scan_sources(root)
    _, facts = parse_all([(rel, text, None) for rel, text in sources.items()], None)
    def bucket(names):
        return {rel: len(facts[rel]['couliIconCalls']) for rel in sorted(names) if facts[rel]['couliIconCalls']}
    print(json.dumps({'production': bucket(production), 'staging': bucket(staging)}, ensure_ascii=False, indent=2))
    return 0


# ---------------------------------------------------------------- 自测：合成合规件 + 错误实现

def reference_files():
    baseline = json.loads(BASELINE.read_text(encoding='utf-8'))
    cases = ''.join("    case '%s':\n      return $r('sys.symbol.%s');\n" % item for item in SYMBOLS.items())
    sets = ''.join("    m.set('%s', ['M1 1']);\n" % name for name in OWN)
    icon = (
        "import { CouliColors } from '../CouliColors';\n"
        "export class CouliIconPaths {\n"
        "  static readonly table: Map<string, string[]> = CouliIconPaths.build();\n"
        "  static get(name: string): string[] {\n    return CouliIconPaths.table.get(name) ?? [];\n  }\n"
        "  private static build(): Map<string, string[]> {\n    const m: Map<string, string[]> = new Map<string, string[]>();\n" + sets +
        "    return m;\n  }\n}\n"
        "export function scalePath(cmd: string, k: number): string {\n  return cmd + k;\n}\n"
        "function couliSymbolOf(name: string): Resource | undefined {\n  switch (name) {\n" + cases +
        "    default:\n      return undefined;\n  }\n}\n"
        "@ComponentV2\nexport struct CouliIcon {\n"
        "  @Param name: string = 'info';\n  @Param iconSize: number = 24;\n  @Param color: ResourceColor = CouliColors.textPrimary;\n"
        "  private factor(): number {\n    return 1;\n  }\n"
        "  build() {\n    Stack() {\n      if (couliSymbolOf(this.name) !== undefined) {\n"
        "        SymbolGlyph(couliSymbolOf(this.name))\n          .fontSize(this.iconSize + 'vp')\n          .fontColor([this.color])\n          .accessibilityLevel('no')\n"
        "      } else {\n        ForEach(CouliIconPaths.get(this.name), (cmd: string) => {\n          Path()\n"
        "            .width(this.iconSize)\n            .height(this.iconSize)\n            .commands(scalePath(cmd, this.factor()))\n            .fill(Color.Transparent)\n"
        "            .stroke(this.color)\n            .strokeWidth(ICON_STROKE * this.iconSize / ICON_VIEWPORT)\n            .strokeLineCap(LineCapStyle.Round)\n"
        "            .strokeLineJoin(LineJoinStyle.Round)\n        }, (cmd: string, index: number) => index + cmd)\n      }\n    }\n"
        "    .width(this.iconSize)\n    .height(this.iconSize)\n    .accessibilityLevel('no')\n  }\n}\n"
        "const ICON_VIEWPORT: number = 24;\nconst ICON_STROKE: number = 1.75;\n"
    )
    arr = lambda xs: '[' + ', '.join("'%s'" % x for x in xs) + ']'
    names = "export const SYMBOL_ICON_NAMES: string[] = %s;\nexport const PATH_ICON_NAMES: string[] = %s;\n" % (arr(SYMBOLS), arr(OWN))
    logic = "export { SYMBOL_ICON_NAMES, PATH_ICON_NAMES } from './src/main/ets/logic/CouliIconNames';\n"
    index = "export { CouliIcon, CouliIconPaths } from './src/main/ets/components/CouliIcon';\n"
    nav_unmerged = (
        "import { CouliIcon } from './CouliIcon';\n@ComponentV2\nexport struct TabBar {\n  @Builder\n  bar(icon: string) {\n"
        "    Column() {\n      CouliIcon({ name: icon })\n      CouliIcon({ name: icon })\n    }\n  }\n  build() {\n    Tabs() {\n    }\n  }\n}\n"
    )
    suite = 'const NAMES = %s;\n' % arr(list(SYMBOLS) + OWN)
    list_file = "import iconSymbolTest from './IconSymbol.test';\nexport default function testsuite() {\n  iconSymbolTest();\n}\n"
    verify = (
        'record "ds02-host" PASS\n'
        'python3 "$ROOT/tools/ci/iconsymbol/check_icon_symbol.py" --self-test || fail_fast a b\n'
        'python3 "$ROOT/tools/ci/iconsymbol/check_icon_symbol.py" || fail_fast a b\n'
        'node "$ROOT/tools/ci/iconsymbol/run-logic.cjs" || fail_fast a b\n'
        'node "$ROOT/tools/ci/iconsymbol/check-arkts.cjs" --real || fail_fast a b\n'
    )
    files = {ICON: icon, NAMES: names, LOGIC: logic, INDEX: index, SUITE: suite, LIST: list_file, VERIFY: verify}
    for rel, count in list(baseline['production'].items()) + list(baseline['staging'].items()):
        if rel == NAV:
            files[rel] = nav_unmerged
            continue
        files[rel] = (
            "import { CouliIcon } from 'designsystem';\n@ComponentV2\nexport struct P {\n  build() {\n    Column() {\n"
            + "      CouliIcon({ name: 'info' })\n" * count + "    }\n  }\n}\n"
        )
    if NAV not in files:
        files[NAV] = nav_unmerged
    return files


TAB_MERGED = (
    "class TabSymbols {\n  normal: Resource = $r('sys.symbol.house');\n  selected: Resource = $r('sys.symbol.house');\n}\n"
    "function symbolsOf(icon: string): TabSymbols {\n  switch (icon) {\n"
    "    case 'home':\n      return { normal: $r('sys.symbol.house'), selected: $r('sys.symbol.house_fill') };\n"
    "    case 'chat':\n      return { normal: $r('sys.symbol.ellipsis_message'), selected: $r('sys.symbol.ellipsis_message_fill') };\n"
    "    case 'orders':\n      return { normal: $r('sys.symbol.doc_plaintext'), selected: $r('sys.symbol.doc_plaintext_fill') };\n"
    "    case 'user':\n      return { normal: $r('sys.symbol.person'), selected: $r('sys.symbol.person_fill') };\n"
    "    case 'search':\n      return { normal: $r('sys.symbol.magnifyingglass'), selected: $r('sys.symbol.magnifyingglass') };\n"
    "    default:\n      return { normal: $r('sys.symbol.questionmark_circle'), selected: $r('sys.symbol.questionmark_circle') };\n  }\n}\n"
    "@ComponentV2\nexport struct TabBar {\n  private bar(icon: string): BottomTabBarStyle {\n    const s: TabSymbols = symbolsOf(icon);\n"
    "    return new BottomTabBarStyle({ normal: new SymbolGlyphModifier(s.normal), selected: new SymbolGlyphModifier(s.selected) }, icon);\n  }\n"
    "  build() {\n    Tabs() {\n    }\n  }\n}\n"
)


def self_test():
    base = reference_files()
    sample_page = next(rel for rel in base if rel.startswith('features/') and "CouliIcon({ name: 'info' })\n" in base[rel])

    def replace(rel, old, new):
        def apply(files):
            if old not in files[rel]:
                raise SystemExit('自测变异没对上：%s %r' % (rel, old))
            files[rel] = files[rel].replace(old, new)
        return apply

    def tab_merged_with(mutate=None):
        def apply(files):
            files[NAV] = TAB_MERGED
            if mutate:
                mutate(files)
        return apply

    def remove_calls(files):
        files[sample_page] = files[sample_page].replace("      CouliIcon({ name: 'info' })\n", '', 1)

    def drop_import(files):
        files[sample_page] = files[sample_page].replace("import { CouliIcon } from 'designsystem';\n", '')

    all_names = list(SYMBOLS)
    mutants = [
        # 书 §3.1-6 / §3.4：漏名字、错符号、未知名抛错、fp、Path 多留、删自有、Navigation 不一致
        ('I1-switch', '漏一个名字（switch）', replace(ICON, "    case 'star':\n      return $r('sys.symbol.star');\n", '')),
        ('I1-map', '漏一个名字（star 落 default 成 undefined）', replace(ICON, "    case 'star':\n      return $r('sys.symbol.star');\n", '')),
        ('I1-names', '名单漏一个', replace(NAMES, "'heart', ", '')),
        ('I1-names', '名单多一个', replace(NAMES, "'heart', ", "'heart', 'x', ")),
        ('I1-sdk', '符号名拼错（SDK 没有）', replace(ICON, "$r('sys.symbol.house')", "$r('sys.symbol.housee')")),
        ('I1-map', '符号存在但用错（check 成 xmark）', replace(ICON, "$r('sys.symbol.checkmark_circle')", "$r('sys.symbol.xmark')")),
        ('I1-map', '未知名抛错', replace(ICON, '    default:\n      return undefined;\n', "    default:\n      throw new Error('unknown icon');\n")),
        ('I1-map', '未知名回落某符号', replace(ICON, '    default:\n      return undefined;\n', "    default:\n      return $r('sys.symbol.info_circle');\n")),
        ('I1-switch', '自有名进 switch（filter）', replace(ICON, '    default:\n      return undefined;\n', "    case 'filter':\n      return $r('sys.symbol.filter_color');\n    default:\n      return undefined;\n")),
        ('I1-map', '自有名进 switch（行为）', replace(ICON, '    default:\n      return undefined;\n', "    case 'filter':\n      return $r('sys.symbol.filter_color');\n    default:\n      return undefined;\n")),
        ('I1-switch', '$r 实参非字面量', replace(ICON, "$r('sys.symbol.star')", "$r('sys.symbol.' + name)")),
        ('I1-switch', '映射不是 switch（if）', replace(ICON, "  switch (name) {", "  if (name === 'zz') {\n    return undefined;\n  }\n  switch (name + '') {")),
        ('I1-switch', '缺 couliSymbolOf', replace(ICON, 'function couliSymbolOf(', 'function other(')),
        ('I1-switch', '返回类型改成 Resource', replace(ICON, 'function couliSymbolOf(name: string): Resource | undefined', 'function couliSymbolOf(name: string): Resource')),
        ('I1-names', 'Logic.ets 没导出', replace(LOGIC, "export { SYMBOL_ICON_NAMES, PATH_ICON_NAMES } from './src/main/ets/logic/CouliIconNames';\n", '')),
        ('I1-names', 'CouliIconNames 带 $r', replace(NAMES, 'export const SYMBOL', "export const R: Resource = $r('sys.symbol.house');\nexport const SYMBOL")),
        ('I1-names', 'CouliIconNames 带 import', replace(NAMES, 'export const SYMBOL', "import { hilog } from '@kit.PerformanceAnalysisKit';\nexport const SYMBOL")),
        ('I1-names', '名单不是字面量', replace(NAMES, "'home'", 'HOME_NAME')),
        ('I1-names', '名字两表都在', replace(NAMES, "['category.supermarket'", "['home', 'category.supermarket'")),
        ('I3-table', '改回路径（通用名留表）', replace(ICON, "    return m;\n", "    m.set('home', ['M1 1']);\n    return m;\n")),
        ('I3-table', '删路径表某自有项', replace(ICON, "    m.set('category.fresh', ['M1 1']);\n", '')),
        ('I3-table', '路径表丢 filter（D10-1153 要留）', replace(ICON, "    m.set('filter', ['M1 1']);\n", '')),
        ('I3-table', '删 scalePath', replace(ICON, 'export function scalePath', 'function scalePath')),
        ('I3-table', '删 ICON_STROKE', replace(ICON, 'const ICON_STROKE: number = 1.75;\n', '')),
        ('I4-glyph', '写 fp', replace(ICON, "this.iconSize + 'vp'", "this.iconSize + 'fp'")),
        ('I4-glyph', '数字字号（默认 fp）', replace(ICON, "this.iconSize + 'vp'", 'this.iconSize')),
        ('I4-glyph', '字号写死', replace(ICON, "this.iconSize + 'vp'", "'24vp'")),
        ('I4-glyph', 'SymbolGlyph 没 accessibilityLevel', replace(ICON, ".fontColor([this.color])\n          .accessibilityLevel('no')\n", '.fontColor([this.color])\n')),
        ('I4-glyph', 'fontColor 写死', replace(ICON, '.fontColor([this.color])', '.fontColor([CouliColors.textPrimary])')),
        ('I4-glyph', '没 fontColor', replace(ICON, '          .fontColor([this.color])\n', '')),
        ('I4-glyph', '加了动效', replace(ICON, ".fontColor([this.color])\n", ".fontColor([this.color])\n          .symbolEffect(new SymbolEffect(), true)\n")),
        ('I4-glyph', 'if 条件写反', replace(ICON, 'couliSymbolOf(this.name) !== undefined', 'couliSymbolOf(this.name) === undefined')),
        ('I4-glyph', '另一处多画 SymbolGlyph', replace(ICON, "      } else {\n        ForEach(", "      } else {\n        SymbolGlyph($r('sys.symbol.house'))\n        ForEach(")),
        ('I4-glyph', 'ForEach 挪到 if 外（两套都画）', replace(ICON, "      if (couliSymbolOf(this.name) !== undefined) {", "      ForEach([], (s: string) => {\n      })\n      if (couliSymbolOf(this.name) !== undefined) {")),
        ('I4-path', 'Path 描边不跟 color', replace(ICON, '.stroke(this.color)', '.stroke(CouliColors.textPrimary)')),
        ('I4-path', 'Path 线帽改了', replace(ICON, 'LineCapStyle.Round', 'LineCapStyle.Butt')),
        ('I4-path', '路径分支不是 CouliIconPaths.get', replace(ICON, 'ForEach(CouliIconPaths.get(this.name),', 'ForEach(CouliIconPaths.get(this.name + \'\'),')),
        ('I4-shell', 'Stack 没读屏隐藏', replace(ICON, "    .height(this.iconSize)\n    .accessibilityLevel('no')\n", '    .height(this.iconSize)\n')),
        ('I4-shell', 'Stack 宽度写死', replace(ICON, '    .width(this.iconSize)\n    .height(this.iconSize)\n', '    .width(24)\n    .height(this.iconSize)\n')),
        ('I4-shell', '参数改名 iconSize → size', replace(ICON, '@Param iconSize: number = 24;', '@Param size: number = 24;')),
        ('I4-shell', '参数缺省改了', replace(ICON, '@Param iconSize: number = 24;', '@Param iconSize: number = 20;')),
        ('I4-shell', '颜色缺省改了', replace(ICON, 'CouliColors.textPrimary;\n', 'CouliColors.textSecondary;\n')),
        ('I2-tab', 'Navigation 与本表不一致（TAB-BAR 已合）', tab_merged_with(replace(NAV, "$r('sys.symbol.doc_plaintext')", "$r('sys.symbol.doc_text')"))),
        ('I2-tab', 'home 换成别的符号（TAB-BAR 已合）', tab_merged_with(replace(NAV, "normal: $r('sys.symbol.house')", "normal: $r('sys.symbol.house_fill')"))),
        ('I2-tab', '已合但读不出映射（改成查表）', tab_merged_with(lambda f: f.__setitem__(NAV, f[NAV].split('function symbolsOf')[0]
                                                                     + "function symbolsOf(icon: string): TabSymbols {\n  return new TabSymbols();\n}\n"
                                                                     + '@ComponentV2' + f[NAV].split('@ComponentV2', 1)[1]))),
        ('I2-tab', '底栏缺一个名字（TAB-BAR 已合）', tab_merged_with(replace(NAV, "    case 'search':\n      return { normal: $r('sys.symbol.magnifyingglass'), selected: $r('sys.symbol.magnifyingglass') };\n", ''))),
        ('I5-count', '页面删调用（少一处）', remove_calls),
        ('I5-import', '页面删 import', drop_import),
        ('I5-import', 'Index 不导出 CouliIconPaths', replace(INDEX, 'export { CouliIcon, CouliIconPaths }', 'export { CouliIcon }')),
        ('I5-import', '页面文件删了', lambda f: f.pop(sample_page)),
        ('I6-wiring', '套件少名字', replace(SUITE, "'heart'", "'x'")),
        ('I6-wiring', 'List 没导入', replace(LIST, "import iconSymbolTest from './IconSymbol.test';\n", '')),
        ('I6-wiring', 'List 没调用', replace(LIST, '  iconSymbolTest();\n', '')),
        ('I6-wiring', 'verify 缺本体步', replace(VERIFY, 'python3 "$ROOT/tools/ci/iconsymbol/check_icon_symbol.py" || fail_fast a b\n', '')),
        ('I6-wiring', 'verify 常驻步带 --ticket（I5 混进常驻）', replace(VERIFY, 'check_icon_symbol.py" || fail_fast', 'check_icon_symbol.py" --ticket || fail_fast')),
        ('I6-wiring', 'verify 常驻步带 --base（I5 混进常驻）', replace(VERIFY, 'check_icon_symbol.py" || fail_fast', 'check_icon_symbol.py" --base 59c1976 || fail_fast')),
        ('I6-wiring', 'verify 被注释', replace(VERIFY, 'node "$ROOT/tools/ci/iconsymbol/run-logic.cjs" || fail_fast a b\n', '# node "$ROOT/tools/ci/iconsymbol/run-logic.cjs" || fail_fast a b\n')),
        ('I0', 'CouliIcon.ets 语法坏', replace(ICON, 'export class CouliIconPaths {', 'export class CouliIconPaths {{')),
    ]

    def materialize(files, target):
        for rel, text in files.items():
            path = target / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8')

    survivors = 0
    checks = len(mutants)
    with tempfile.TemporaryDirectory(prefix='iconsymbol-selftest-') as tmp:
        tmp_path = Path(tmp)
        reference = tmp_path / 'reference'
        materialize(base, reference)
        problems, notes = check_tree(reference)
        if problems or not any(n.startswith('SKIP I2-tab') for n in notes):
            print('参照件应当 0 违反且 I2 跳过，实际：%s / %s' % (problems, notes))
            return 1
        print('OK 参照件 0 违反（TAB-BAR 未合，I2 跳过）')
        problems, _ = check_tree(reference, ticket=True)
        if problems:
            print('参照件本单模式应当 0 违反，实际：%s' % problems)
            return 1
        print('OK 参照件本单模式 0 违反')

        merged_files = dict(base)
        merged_files[NAV] = TAB_MERGED
        merged = tmp_path / 'merged'
        materialize(merged_files, merged)
        problems, notes = check_tree(merged)
        if problems or notes:
            print('TAB-BAR 已合的参照件应当 0 违反且不跳过，实际：%s / %s' % (problems, notes))
            return 1
        print('OK TAB-BAR 已合的参照件 0 违反（Navigation 的 2 处调用按书减掉，门槛 111）')
        problems, _ = check_tree(merged, ticket=True)
        if problems:
            print('TAB-BAR 已合的参照件本单模式应当 0 违反，实际：%s' % problems)
            return 1
        print('OK TAB-BAR 已合的参照件本单模式 0 违反')

        # 常驻模式（D10-1168）：I5 的错误实现不报；verify 带 --require-tabbar 的写法算合规。
        for index, (rule, name, mutate) in enumerate(m for m in mutants if m[0].startswith('I5-')):
            files = dict(base)
            mutate(files)
            target = tmp_path / ('r%02d' % index)
            materialize(files, target)
            problems, _ = check_tree(target)
            if problems:
                print('常驻模式不该判 I5（%s），实际：%s' % (name, problems))
                return 1
        print('OK 常驻模式不判 I5（%d 个 I5 错误实现都不报）' % len([m for m in mutants if m[0].startswith('I5-')]))
        files = dict(base)
        files[VERIFY] = files[VERIFY].replace('check_icon_symbol.py" || fail_fast', 'check_icon_symbol.py" --require-tabbar || fail_fast')
        frozen = tmp_path / 'frozen'
        materialize(files, frozen)
        problems, _ = check_tree(frozen)
        if problems:
            print('verify 带 --require-tabbar 应当合规，实际：%s' % problems)
            return 1
        print('OK verify 常驻步带 --require-tabbar 合规')

        for index, (rule, name, mutate) in enumerate(mutants):
            files = dict(base)
            mutate(files)
            target = tmp_path / ('m%02d' % index)
            materialize(files, target)
            problems, _ = check_tree(target, ticket=rule.startswith('I5-'))
            hit = [p for p in problems if p.startswith(rule + ' ')]
            if hit:
                print('KILLED %-9s %s' % (rule, name))
            else:
                survivors += 1
                print('SURVIVED %s %s：%s' % (rule, name, problems))

        # 带参数的判定：--require-tabbar、SDK 表缺符号、--base 页面零改动
        checks += 5
        problems, _ = check_tree(reference, require_tab=True)
        if any(p.startswith('I2-tab ') for p in problems):
            print('KILLED I2-tab    --require-tabbar 未合即红')
        else:
            survivors += 1
            print('SURVIVED --require-tabbar：%s' % problems)
        problems, _ = check_tree(reference, symbols_override=[s for s in set(SYMBOLS.values()) if s != 'house'])
        if any(p.startswith('I1-sdk ') for p in problems):
            print('KILLED I1-sdk    SDK 表缺一个符号')
        else:
            survivors += 1
            print('SURVIVED SDK 表缺符号：%s' % problems)

        repo = tmp_path / 'repo'
        materialize(base, repo)
        def git(*args):
            subprocess.run(['git', '-C', str(repo), '-c', 'user.email=selftest@invalid', '-c', 'user.name=selftest', '-c', 'commit.gpgsign=false'] + list(args),
                           check=True, capture_output=True)
        git('init', '-q')
        git('add', '-A')
        git('commit', '-qm', 'base')
        (repo / ICON).write_text(base[ICON] + '// 本单改动\n', encoding='utf-8')
        problems, _ = check_tree(repo, base='HEAD')
        if any(p.startswith('I5-base') for p in problems):
            survivors += 1
            print('SURVIVED --base 只改 CouliIcon.ets 不应报：%s' % problems)
        else:
            print('OK        --base 只改 CouliIcon.ets 不报')
        (repo / sample_page).write_text(base[sample_page] + '// 顺手改\n', encoding='utf-8')
        problems, _ = check_tree(repo, base='HEAD')
        if any(p.startswith('I5-base') for p in problems):
            print('KILLED I5-base   页面顺手改一行')
        else:
            survivors += 1
            print('SURVIVED --base 页面改动：%s' % problems)
        (repo / sample_page).write_text(base[sample_page], encoding='utf-8')
        remove_only = dict(base)
        remove_calls(remove_only)
        (repo / sample_page).write_text(remove_only[sample_page], encoding='utf-8')
        problems, _ = check_tree(repo, base='HEAD')
        if any(p.startswith('I5-count') for p in problems):
            print('KILLED I5-count  --base 也判调用点（本单模式）')
        else:
            survivors += 1
            print('SURVIVED --base 没判 I5-count：%s' % problems)
        (repo / sample_page).write_text(base[sample_page], encoding='utf-8')
        extra = repo / 'features/home/src/main/ets/Added.ets'
        extra.parent.mkdir(parents=True, exist_ok=True)
        extra.write_text('export const A: number = 1;\n', encoding='utf-8')
        problems, _ = check_tree(repo, base='HEAD')
        if any(p.startswith('I5-base') for p in problems):
            print('KILLED I5-base   新增未跟踪页面文件')
        else:
            survivors += 1
            print('SURVIVED --base 新增文件：%s' % problems)
    print('ICONSYMBOL --self-test: %d 个错误实现，%d 个未被拦下' % (checks, survivors))
    return 1 if survivors else 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    root = Path(argv[argv.index('--root') + 1]).resolve() if '--root' in argv else ROOT
    if '--dump-callsites' in argv:
        return dump_callsites(root)
    base = argv[argv.index('--base') + 1] if '--base' in argv else None
    ticket = '--ticket' in argv
    problems, notes = check_tree(root, require_tab='--require-tabbar' in argv, base=base, ticket=ticket)
    if not ticket and base is None:
        notes.append('常驻模式：I5 不判（D10-1168）；本单提交用 --ticket 或 --base <rev>')
    for line in notes:
        print(line)
    for line in problems:
        print(line)
    print('ICONSYMBOL host: %d 项违反（%s）' % (len(problems), root))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
