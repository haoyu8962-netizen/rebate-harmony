#!/usr/bin/env python3
"""FU-HM-G1-SYSTEM-CONTROLS 冻结收窄（D10-951 ②）：按 import 图实算 me12v / wa / wb / wc 四份守卫「实际依赖」的业务件清单。

测试作者写的**算法件**（不是产品实现、也不是 G1 检查脚本）：tests 与交回清单都用它，收窄实现者可以直接把输出写进 fixture。

算法（逐步写死，改口径须走 #24）：
1. 被守文件 = 每份 fixture 的 strict + tree + tree_exempt + views + append_only 的键，再加脚本常量里单独守的文件（me12v 的 G4 守卫区
   MeTabView.ets、me12wb 的 G3 RootPage.ets），取 .ets；tree 里去掉 common/designsystem/ 自身（它是被依赖方）和 entry/src/staging/
   （D10-951 ②：me12wa 的 staging 整树移出冻结；只许追加的 staging 文件仍是被守文件，留在 append_only 里算）。
2. 每个被守文件用 lint.lex_scan（ohos-typescript 语法树，不手写词法）取 import：
   - from 'designsystem'、'designsystem/Logic'、'designsystem/Brand' 的命名导入，按对应入口文件的 export 映射到定义文件，再跟随定义文件里的
     `export { X } from` 转发；
   - 相对路径 import 落进 common/designsystem/ 的，直接算该文件；
   - designsystem 的命名空间 / 默认 / 动态导入无法定位到符号，抛 Unresolved，不猜。
3. 种子 = 第 2 步得到的定义文件 ∩ A 类（§1.3 的 8 个业务·红线相关文件）。
4. 闭包：从种子出发，只沿 **A 类文件** 自身的 import 边（相对路径或 designsystem 入口）继续走，走到的文件若也是 A 类就并入。
5. 输出：每份守卫的 keep（闭包，排序）、direct（种子）、reached_other（第 2 步命中但不是 A 类的 designsystem 文件，仅供核对，不进清单）。

用法：
    python3 tools/ci/system-controls/frozen_deps.py [--root <仓库根>]      # 打印 JSON
"""
import argparse
import importlib.util
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
DS = 'common/designsystem'
DS_ETS = DS + '/src/main/ets/'
STAGING = 'entry/src/staging/'
ENTRY_FILES = {'designsystem': DS + '/Index.ets', 'designsystem/Logic': DS + '/Logic.ets', 'designsystem/Brand': DS + '/Brand.ets'}
FIXTURES = {
    'me12v': 'tools/ci/me12v/fixtures/logic-baseline-c782ca8.json',
    'me12wa': 'tools/ci/me12wa/fixtures/settings-baseline-cc872c3.json',
    'me12wb': 'tools/ci/me12wb/fixtures/privacy-baseline-8699e5a.json',
    'me12wc': 'tools/ci/me12wc/fixtures/risk-baseline-30201f0.json',
}
# 守在脚本常量里、不在 fixture 的 strict / tree 里：me12v G4 守卫区（check_me_visual.py 的 ME_TAB_VIEW）、me12wb G3（check_privacy_visual.py 的 ROOT_PAGE）。
EXTRA_GUARDED = {'me12v': ['features/me/src/main/ets/MeTabView.ets'], 'me12wb': ['entry/src/main/ets/pages/RootPage.ets']}
# 任务书 §1.3 A 类（业务·红线相关）。分类是裁定输入（D10-827 ⑤ / D10-951 ②），依赖是算出来的。
CLASS_A = sorted(DS_ETS + p for p in [
    'format/CouliFormat.ets', 'format/PriceTerms.ets', 'components/PendingConfirm.ets', 'components/StepUpPanel.ets',
    'components/CodeCells.ets', 'logic/StepUpPanelFit.ets', 'components/Clipboard.ets', 'logic/ClipboardPromptLayout.ets',
])


class Unresolved(Exception):
    pass


def load_lint(root):
    spec = importlib.util.spec_from_file_location('couli_lint_for_frozen_deps', os.path.join(root, 'tools/ci/lint.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture_paths(data, key):
    """strict / tree 有 dict（路径 → 摘要）和 list（[摘要, 路径]）两种形状，views 是 dict，tree_exempt 是路径 list。"""
    value = data.get(key)
    if not value:
        return []
    if isinstance(value, dict):
        return list(value)
    return [item[1] if isinstance(item, list) else item for item in value]


def guarded_files(root, guard):
    with open(os.path.join(root, FIXTURES[guard]), encoding='utf-8') as f:
        data = json.load(f)
    paths = set(EXTRA_GUARDED.get(guard, []))
    for key in ('strict', 'tree_exempt', 'views', 'append_only'):
        paths.update(fixture_paths(data, key))
    paths.update(p for p in fixture_paths(data, 'tree') if not p.startswith(STAGING))
    return sorted(p for p in paths if p.endswith('.ets') and not p.startswith(DS + '/'))


class Graph:
    def __init__(self, root):
        self.root = root
        self.lint = load_lint(root)
        self.lexed = {}
        self.exports = {}

    def read(self, rel):
        with open(os.path.join(self.root, rel), encoding='utf-8') as f:
            return f.read()

    def imports(self, rel):
        if rel not in self.lexed:
            result = self.lint.lex_scan([(os.path.basename(rel), self.read(rel))])[0]
            if result.get('incomplete'):
                raise Unresolved('%s 解析不完整：%s' % (rel, result['incomplete']))
            self.lexed[rel] = result['imports']
        return self.lexed[rel]

    def resolve_relative(self, base, module):
        target = os.path.normpath(os.path.join(os.path.dirname(base), module))
        for suffix in ('', '.ets', '.ts'):
            candidate = target + suffix
            if os.path.isfile(os.path.join(self.root, candidate)):
                return candidate.replace(os.sep, '/')
        raise Unresolved('%s 的相对导入 %s 找不到文件' % (base, module))

    def export_map(self, rel):
        """文件 rel 里 `export { name as alias } from './x'` 的 {alias: (目标文件, 原名)}。"""
        if rel not in self.exports:
            table = {}
            for imp in self.imports(rel):
                if imp['kind'] != 'export' or not imp['module']:
                    continue
                if not imp['names']:
                    raise Unresolved('%s 有 export * from %s，无法按符号定位' % (rel, imp['module']))
                target = self.resolve_relative(rel, imp['module'])
                for item in imp['names']:
                    table[item['alias']] = (target, item['name'])
            self.exports[rel] = table
        return self.exports[rel]

    def definition(self, entry_rel, symbol):
        """沿 export 转发找到符号的定义文件。"""
        rel, name = entry_rel, symbol
        seen = set()
        while True:
            table = self.export_map(rel)
            if name not in table:
                if rel == entry_rel:
                    raise Unresolved('%s 没有导出 %s' % (entry_rel, symbol))
                return rel
            if (rel, name) in seen:
                raise Unresolved('%s 的 %s 转发成环' % (entry_rel, symbol))
            seen.add((rel, name))
            rel, name = table[name]

    def designsystem_edges(self, rel):
        """rel 直接依赖的 designsystem 文件集合。"""
        out = set()
        for imp in self.imports(rel):
            module = imp['module']
            if imp['kind'] not in ('import', 'dynamic', 'require', 'import-equals', 'import-type') or module is None:
                continue
            if module in ENTRY_FILES:
                if imp['kind'] != 'import' or not imp['names']:
                    raise Unresolved('%s:%d designsystem 的导入形态无法按符号定位（kind=%s）' % (rel, imp['line'], imp['kind']))
                for item in imp['names']:
                    if item['name'] == 'default':
                        raise Unresolved('%s:%d designsystem 默认导入无法定位' % (rel, imp['line']))
                    out.add(self.definition(ENTRY_FILES[module], item['name']))
            elif module.startswith('.'):
                target = self.resolve_relative(rel, module)
                if target.startswith(DS + '/'):
                    out.add(target)
        return out


def derive(root):
    graph = Graph(root)
    class_a = set(CLASS_A)
    report = {}
    for guard in sorted(FIXTURES):
        files = guarded_files(root, guard)
        missing = [rel for rel in files if not os.path.isfile(os.path.join(root, rel))]
        direct = set()
        for rel in files:
            if rel not in missing:
                direct |= graph.designsystem_edges(rel)
        seeds = direct & class_a
        keep = set(seeds)
        todo = sorted(keep)
        while todo:
            for dep in graph.designsystem_edges(todo.pop()) & class_a:
                if dep not in keep:
                    keep.add(dep)
                    todo.append(dep)
        report[guard] = {
            'guarded_ets': len(files),
            'missing_guarded': missing,
            'direct': sorted(seeds),
            'keep': sorted(keep),
            'reached_other': sorted(direct - class_a),
        }
    return report


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', default=ROOT)
    args = parser.parse_args(argv)
    print(json.dumps(derive(os.path.abspath(args.root)), ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
