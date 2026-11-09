#!/usr/bin/env python3
"""FU-HM-FEEL-KIT-harmony 测试作者 v3：手感底座宿主检查（Python 3 标准库 + SDK ohos-typescript 解析，见 parse-ets.cjs）。

依据：NATIVE/FU-HM-FEEL-KIT/brief-harmony.md §2、§3.1；裁定 D10-1153（VIBRATE 手写一行、目录改判 11 项按表、目录矩阵只改标记与说明）、D10-1163（减弱动态保留淡入；冷启动直达的隐私口径）。.ets 一律走 AST。

  C0  相关文件解析不完整即违反
  C1  vibrator 只在 CouliHaptics.ets 导入（来自 @kit.SensorServiceKit）；别处不 import、不引用 @ohos.vibrator（书 §3.1-1）
  C2  entry/src/main/module.json5 requestPermissions 集合恰 {INTERNET, VIBRATE}，VIBRATE 那项只有 name（手写一行，system_grant 不要 reason）；
      其他模块不声明 VIBRATE；--hap / --hap-staging 对制品断言同一集合（书 §3.1-2）
  C3  features/*/src/main、entry/src/main、designsystem/src/main 除 CouliHaptics.ets、HapticMoments.ets 外无 CouliHaptics.* 调用（本单 0 处，
      书 §3.1-3 / 用例 10；L2 起按 #24 收窄）；HapticPlan 只在 CouliHaptics.ets 导入；CouliHaptics 公开成员恰 5 个静态无参方法（不暴露可注入的生产 API）
  C4  isAnimationReduceEnabled[Sync] / on / offAnimationReduceStateChange 的每次引用都在 `if (deviceInfo.sdkApiVersion >= 23)` 的 then 分支里
      （版本判断直接写在 if 上；间接变量、else 分支、复合条件都不算，SDK SdkComparisonValidator 同口径）；所在文件导入 deviceInfo；
      CouliMotion.ets 必须用到读取与订阅两个接口（书 §2.3、§3.1-4）
  C5  CouliPressable：@ComponentV2 struct，有 kind / onTap；每处 .onClick 同链有 stateStyles 或 clickEffect；BOUNCE 用
      clickEffect({ level: ClickEffectLevel.LIGHT })，HIGHLIGHT 用 stateStyles 的 pressed 背景 CouliColors.backgroundMuted；经 MotionPolicy.press 退化（书 §2.4、§3.1-5）
      v3（评审 r1 S2-3）每处 .onClick 闭包里实际调用 this.onTap；MotionPolicy.press 第二实参是 this.kind、第一实参读减弱动态；
      clickEffect 只在 BOUNCE 分支、stateStyles 只在 HIGHLIGHT 分支，分支条件是 press 结果与 PressKind 的单一比较
  C6  CouliMotion / MotionPolicy：字面量不超过 400（十六进制日志域除外）；不读 motion 令牌（D10-838）；有 durationMicro / durationEnter；
      HapticMoments、MotionPolicy 无 @kit / @ohos 导入、无 $r（进 Logic.ets）（书 §3.1-6、§1 表 test_host）
  C7  CatalogManifest：KIND_L1='L1 系统控件'、KIND_L2='L2 业务组件'，旧常量不存在，每个组件的 KIND 与 fixtures/catalog-kinds.json（书 §2.5）一致；
      inventory.tsv 第 3 列同步、单值；Ds02Expected ×2、Ds02Catalog.test、run-unit、check-ui-facilities 不再留旧值；§2.5「说明照实」四处（书 §3.1-7）
  C8  FeelLab：目录里 L2、staging 样例页有 5 个触感、两种 Press、减弱动态显示；进包源码（main / release）不含 FeelLab；--hap 制品不含（书 §2.6、§3.3）
  C9  冷启动直达：staging BuildVariant 新增推 CATALOG_ROUTE 的方法同时看 CatalogLaunch、presentationReady、隐私状态，并由 environmentSettled 调用；
      v2（D10-1163 ②）eval-cold-start.cjs 真执行该方法：有待打开组件 + 界面就绪 + CONSENTED 或 BASIC_MODE 才推，NOT_DECIDED 不推；Release 进包源码不含直达符号（真机行为归设备步）
      v3（评审 r1 S2-4）eval-cold-retry.cjs 真执行 environmentSettled 可达的方法 + 真实 CatalogLaunch + 假 setTimeout：NOT_DECIDED 0 次调度、同意后不补开；
      未就绪时重试、就绪后恰推 1 次；一直不就绪时重试有上限；重复触发不重复推（markOpening）；take 后可再次打开
  C10 登记：List.test 导入并调用 feelKitTest；Logic.ets / Index.ets 导出；EntryAbility.loadRoot 里 CouliTheme.install 之后、loadContent 之前恰 1 处 CouliMotion.attach()；
      verify.sh 跑本检查（自测 + 本体）、run-logic、check-arkts 与制品步（书 §2.3、§4、§6）

用法：
  python3 tools/ci/feelkit/check_feel_kit.py                  本仓库（违反即退出 1）
  python3 tools/ci/feelkit/check_feel_kit.py --self-test      合成合规件 0 违反、每个错误实现被打红（REFERENCE_ONLY，不算产品通过；含 run-logic 行为变异，书 §3.3）
  python3 tools/ci/feelkit/check_feel_kit.py --root <目录>     查别的目录
  python3 tools/ci/feelkit/check_feel_kit.py --hap X.hap      Release 制品：权限集合 = {INTERNET, VIBRATE}，不含 FeelLab
  python3 tools/ci/feelkit/check_feel_kit.py --hap-staging X.hap   Staging / Debug 制品：权限集合同上，含 FeelLab
"""

import csv
import io
import json
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PARSER = Path(__file__).with_name('parse-ets.cjs')
RUN_LOGIC = Path(__file__).with_name('run-logic.cjs')
EVAL_COLD_START = Path(__file__).with_name('eval-cold-start.cjs')
EVAL_COLD_RETRY = Path(__file__).with_name('eval-cold-retry.cjs')
CATALOG_LAUNCH = 'entry/src/staging/ets/catalog/CatalogLaunch.ets'
COLD_RETRY_MAX_TIMERS = 1000
KINDS_FIXTURE = 'tools/ci/feelkit/fixtures/catalog-kinds.json'

LIB = 'common/designsystem/src/main/ets/'
HAPTICS = LIB + 'components/CouliHaptics.ets'
MOTION = LIB + 'components/CouliMotion.ets'
PRESSABLE = LIB + 'components/CouliPressable.ets'
MOMENTS = LIB + 'logic/HapticMoments.ets'
POLICY = LIB + 'logic/MotionPolicy.ets'
LOGIC_INDEX = 'common/designsystem/Logic.ets'
MAIN_INDEX = 'common/designsystem/Index.ets'
MODULE = 'entry/src/main/module.json5'
ENTRY = 'entry/src/main/ets/entryability/EntryAbility.ets'
STAGING_BV = 'entry/src/staging/ets/variant/BuildVariant.ets'
CATALOG_DIR = 'entry/src/staging/ets/catalog'
MANIFEST = CATALOG_DIR + '/CatalogManifest.ets'
INVENTORY = 'tools/ci/ds02/fixtures/inventory.tsv'
EXPECTED = ['common/designsystem/src/test/Ds02Expected.ets', 'entry/src/ohosTest/ets/test/Ds02Expected.ets']
CATALOG_TEST = 'entry/src/ohosTest/ets/test/Ds02Catalog.test.ets'
STUBS = ['tools/ci/ds02/run-unit.cjs', 'tools/ci/ds02/check-ui-facilities.cjs']
SUITE = 'common/designsystem/src/test/FeelKit.test.ets'
LIST = 'common/designsystem/src/test/List.test.ets'
VERIFY = 'tools/ci/verify.sh'

PERMISSIONS = {'ohos.permission.INTERNET', 'ohos.permission.VIBRATE'}
VIBRATE = 'ohos.permission.VIBRATE'
KIND_L1 = 'L1 系统控件'
KIND_L2 = 'L2 业务组件'
OLD_KINDS = ('系统控件', '自绘')
HAPTIC_METHODS = ['selection', 'success', 'warning', 'failure', 'threshold']
NEW_APIS = {'isAnimationReduceEnabled', 'isAnimationReduceEnabledSync', 'onAnimationReduceStateChange', 'offAnimationReduceStateChange'}
SKIP_DIRS = {'build', 'oh_modules', 'node_modules', '.hvigor', '.preview'}
LOGIC_EXPORTS = {'HapticMoments': {'HapticMoment', 'HAPTIC_EFFECT', 'HapticPlan', 'HapticPort'},
                 'MotionPolicy': {'MotionPolicy', 'MotionKind', 'MotionSpec', 'PressKind'}}
INDEX_EXPORTS = {'CouliHaptics': {'CouliHaptics'}, 'CouliMotion': {'CouliMotion'}, 'CouliPressable': {'CouliPressable'}, 'MotionPolicy': {'PressKind'}}
KIT_COMPONENTS = {'CouliHaptics', 'CouliMotion', 'CouliPressable'}


def parse_all(items):
    result = subprocess.run(['node', str(PARSER)], input=json.dumps([{'name': n, 'text': t} for n, t in items]),
                            capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        raise SystemExit('parse-ets.cjs 失败：' + result.stderr)
    parsed = json.loads(result.stdout)
    if len(parsed) != len(items):
        raise SystemExit('parse-ets.cjs 返回条数不对')
    return dict(zip([n for n, _ in items], parsed))


def walk(base):
    if not base.is_dir():
        return
    for path in sorted(base.rglob('*')):
        if path.is_file() and not (SKIP_DIRS & set(p.name for p in path.relative_to(base).parents)):
            yield path


def module_dirs(root, group):
    base = root / group
    return sorted(p for p in base.iterdir() if p.is_dir()) if base.is_dir() else []


def ets_files(folders):
    for folder in folders:
        for path in walk(folder):
            if path.suffix == '.ets':
                yield path


def production_folders(root):
    """会进任何产品制品的源码（含 staging）。"""
    folders = [root / 'entry/src/main', root / 'entry/src/staging', root / 'entry/src/release']
    for group in ('features', 'common'):
        for d in module_dirs(root, group):
            folders += [d / 'src/main', d / 'src/release', d / 'src/staging']
    return folders


def release_folders(root):
    """会进 Release 制品的源码（不含 staging）。"""
    folders = [root / 'entry/src/main', root / 'entry/src/release']
    for group in ('features', 'common'):
        for d in module_dirs(root, group):
            folders += [d / 'src/main', d / 'src/release']
    return folders


def rel(root, path):
    return path.relative_to(root).as_posix()


def text_of(root, name):
    path = root / name
    return path.read_text(encoding='utf-8') if path.is_file() else None


def load_json5(text):
    """够用的 JSON5：去注释与尾逗号（字符串内不动）。"""
    out = []
    i = 0
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == '\\':
                out.append(text[i + 1])
                i += 1
            elif ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
            out.append(ch)
        elif text.startswith('//', i):
            while i < len(text) and text[i] != '\n':
                i += 1
            continue
        elif text.startswith('/*', i):
            i = text.index('*/', i) + 2
            continue
        else:
            out.append(ch)
        i += 1
    cleaned = ''.join(out)
    result = []
    for j, ch in enumerate(cleaned):
        if ch == ',':
            rest = cleaned[j + 1:].lstrip()
            if rest[:1] in ('}', ']'):
                continue
        result.append(ch)
    return json.loads(''.join(result))


def permissions_of(module):
    return [p.get('name') for p in module.get('module', {}).get('requestPermissions', [])]


def check_permissions(names, label):
    out = []
    if len(names) != len(set(names)):
        out.append('C2 %s 权限有重复：%s' % (label, names))
    if set(names) != PERMISSIONS:
        out.append('C2 %s 权限集合应恰为 %s，实际 %s' % (label, sorted(PERMISSIONS), sorted(set(names))))
    return out


def has_version_guard(guards):
    return any(g['kind'] == 'if' and g['branch'] == 'then' and g['versionFloor'] is not None and g['versionFloor'] >= 23 for g in guards)


def imports_name(facts, imported, modules):
    return any(i['module'] in modules and any(n['imported'] == imported for n in i['names']) for i in facts['imports'])


def strip_quotes(arg):
    return arg[1:-1] if len(arg) >= 2 and arg[0] in '\'"`' and arg[-1] == arg[0] else arg


def eval_cold_start(body):
    result = subprocess.run(['node', str(EVAL_COLD_START)], input=json.dumps({'body': body}), capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise SystemExit('eval-cold-start.cjs 失败：' + result.stderr)
    return json.loads(result.stdout)


def eval_cold_retry(catalog_launch, cls, consts):
    payload = {'catalogLaunch': catalog_launch, 'methods': cls['methods'], 'properties': cls['properties'], 'consts': consts}
    result = subprocess.run(['node', str(EVAL_COLD_RETRY)], input=json.dumps(payload), capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise SystemExit('eval-cold-retry.cjs 失败：' + result.stderr)
    return json.loads(result.stdout)


def check_cold_retry(outcome):
    """v3（评审 r1 S2-4）：判定 eval-cold-retry.cjs 记录的事实。"""
    if outcome.get('incomplete'):
        return ['C9 冷启动重试无法执行：%s' % outcome['incomplete']]
    out = []
    rows = {r['name']: r for r in outcome['results']}
    expectations = {
        'not_decided_not_ready': lambda r: r['pushes'] == 0 and r['timers'] == 0,
        'not_decided_ready': lambda r: r['pushes'] == 0 and r['timers'] == 0,
        'later_ready_consented': lambda r: r['firstTimers'] >= 1 and r['pushes'] == 1 and r['drained'],
        'later_ready_basic_mode': lambda r: r['firstTimers'] >= 1 and r['pushes'] == 1 and r['drained'],
        'never_ready_is_bounded': lambda r: r['pushes'] == 0 and r['drained'] and 1 <= r['timers'] <= COLD_RETRY_MAX_TIMERS and r['minDelay'] > 0,
        'settled_twice_pushes_once': lambda r: r['pushes'] == 1 and r['timers'] == 0,
        'settled_twice_while_waiting_pushes_once': lambda r: r['pushes'] == 1 and r['drained'],
        'reopens_after_take': lambda r: r['pushes'] == 2,
        'no_pending_does_nothing': lambda r: r['pushes'] == 0 and r['timers'] == 0,
        'privacy_reset_stops_retry': lambda r: r['pushes'] == 0 and r['drained'] and r['timers'] <= r['firstTimers'],
    }
    for name, ok in expectations.items():
        row = rows.get(name)
        if row is None:
            out.append('C9 冷启动重试缺场景 %s' % name)
        elif 'error' in row:
            out.append('C9 冷启动重试 %s 抛错：%s' % (name, row['error']))
        elif not ok(row):
            out.append('C9 冷启动重试 %s 不符合预期：%s' % (name, {k: v for k, v in row.items() if k != 'name'}))
    return out


def check_tree(root):
    out = []
    root = Path(root)
    items = {}
    for path in ets_files(production_folders(root)):
        items[rel(root, path)] = path.read_text(encoding='utf-8')
    for name in (LOGIC_INDEX, MAIN_INDEX, LIST, SUITE, CATALOG_TEST, *EXPECTED):
        text = text_of(root, name)
        if text is not None:
            items[name] = text
    facts = parse_all(sorted(items.items()))
    for name, data in sorted(facts.items()):
        if data['incomplete']:
            out.append('C0 %s 解析不完整：%s' % (name, data['incomplete']))
    required = (HAPTICS, MOTION, PRESSABLE, MOMENTS, POLICY)
    missing = [n for n in required if n not in facts]
    for name in missing:
        out.append('C0 缺文件 %s' % name)
    production = {rel(root, p) for p in ets_files(production_folders(root))}

    # C1：vibrator 只在 CouliHaptics.ets
    for name in sorted(production):
        data = facts[name]
        offending = [i for i in data['imports'] if i['module'] == '@ohos.vibrator' or
                     (i['module'].startswith('@kit.') and any(n['imported'] == 'vibrator' for n in i['names']))]
        if name == HAPTICS:
            if any(i['module'] != '@kit.SensorServiceKit' for i in offending):
                out.append('C1 CouliHaptics.ets 的 vibrator 应来自 @kit.SensorServiceKit')
        elif offending:
            out.append('C1 %s 导入了 vibrator（只许 CouliHaptics.ets）' % name)
    if HAPTICS in facts and not imports_name(facts[HAPTICS], 'vibrator', {'@kit.SensorServiceKit'}):
        out.append('C1 CouliHaptics.ets 未从 @kit.SensorServiceKit 导入 vibrator')

    # C2：权限
    module_text = text_of(root, MODULE)
    if module_text is None:
        out.append('C2 缺 %s' % MODULE)
    else:
        module = load_json5(module_text)
        out += check_permissions(permissions_of(module), MODULE)
        for entry in module.get('module', {}).get('requestPermissions', []):
            if entry.get('name') == VIBRATE and set(entry) != {'name'}:
                out.append('C2 VIBRATE 应只写 name 一项（手写一行，D10-1153），实际键 %s' % sorted(entry))
    for path in sorted(root.rglob('module.json5')):
        name = rel(root, path)
        if name == MODULE or SKIP_DIRS & set(path.parts) or '/ohosTest/' in '/' + name:
            continue
        if VIBRATE in permissions_of(load_json5(path.read_text(encoding='utf-8'))):
            out.append('C2 %s 不应声明 VIBRATE（只在 entry）' % name)

    # C3：0 个调用点、唯一入口
    scope_folders = [root / 'entry/src/main', root / 'common/designsystem/src/main'] + [d / 'src/main' for d in module_dirs(root, 'features')]
    allowed = {HAPTICS, MOMENTS}
    for path in ets_files(scope_folders):
        name = rel(root, path)
        if name in allowed:
            continue
        for ref in facts[name]['refs']:
            if ref['text'].startswith('CouliHaptics.'):
                out.append('C3 %s:%d 调了 %s（本单 0 个调用点）' % (name, ref['line'], ref['text']))
    for name in sorted(production):
        if name != HAPTICS and any(n['imported'] == 'HapticPlan' for i in facts[name]['imports'] for n in i['names']):
            out.append('C3 %s 导入了 HapticPlan（统一入口只有 CouliHaptics）' % name)
    if HAPTICS in facts:
        cls = facts[HAPTICS]['classes'].get('CouliHaptics')
        if cls is None or not cls['exported']:
            out.append('C3 CouliHaptics.ets 缺 export class CouliHaptics')
        else:
            public = {n: m for n, m in cls['methods'].items() if not m['private']}
            if set(public) != set(HAPTIC_METHODS):
                out.append('C3 CouliHaptics 公开方法应恰为 %s，实际 %s' % (HAPTIC_METHODS, sorted(public)))
            for n, m in public.items():
                if not m['static'] or m['params']:
                    out.append('C3 CouliHaptics.%s 应为静态无参（不暴露可注入的生产 API）' % n)
            for n, p in cls['properties'].items():
                if not p['private']:
                    out.append('C3 CouliHaptics.%s 不应公开（单例 HapticPlan 留在内部）' % n)

    # C4：API 23 版本包裹
    for name in sorted(production):
        data = facts[name]
        hits = [r for r in data['refs'] if r['text'].rsplit('.', 1)[-1] in NEW_APIS]
        hits += [c for c in data['calls'] if c['callee'].rsplit('.', 1)[-1] in NEW_APIS and '.' not in c['callee']]
        hits += [c for c in data['calls'] if c['callee'].rsplit('.', 1)[-1] in NEW_APIS and c['callee'].count('.') > 1]
        for hit in hits:
            label = hit.get('text') or hit.get('callee')
            if not has_version_guard(hit['guards']):
                out.append('C4 %s:%d %s 不在 if (deviceInfo.sdkApiVersion >= 23) 的 then 分支里' % (name, hit['line'], label))
        if hits and not (imports_name(data, 'deviceInfo', {'@kit.BasicServicesKit'}) or
                         any(i['module'] == '@ohos.deviceInfo' for i in data['imports'])):
            out.append('C4 %s 用了 API 23 接口但没导入 deviceInfo' % name)
    if MOTION in facts:
        used = {r['text'].rsplit('.', 1)[-1] for r in facts[MOTION]['refs']}
        for api in ('isAnimationReduceEnabledSync', 'onAnimationReduceStateChange'):
            if api not in used:
                out.append('C4 CouliMotion.ets 没用 %s' % api)

    # C5：CouliPressable
    if PRESSABLE in facts:
        data = facts[PRESSABLE]
        struct = data['structs'].get('CouliPressable')
        if struct is None or not struct['exported']:
            out.append('C5 缺 export struct CouliPressable')
        else:
            if 'ComponentV2' not in struct['decorators']:
                out.append('C5 CouliPressable 应为 @ComponentV2')
            for prop in ('kind', 'onTap'):
                if prop not in struct['props']:
                    out.append('C5 CouliPressable 缺属性 %s' % prop)
            chains = [c for c in data['chains'] if c['enclosing'].startswith('CouliPressable')]
            clicks = [c for c in chains if 'onClick' in c['names']]
            if not clicks:
                out.append('C5 CouliPressable 没有 .onClick')
            for chain in clicks:
                if not ({'stateStyles', 'clickEffect'} & set(chain['names'])):
                    out.append('C5 CouliPressable:%d .onClick 同链无 stateStyles / clickEffect' % chain['line'])
            effect_args = [a for c in chains for a in c['args'].get('clickEffect', [])]
            if not any('ClickEffectLevel.LIGHT' in a for a in effect_args):
                out.append('C5 BOUNCE 应为 clickEffect({ level: ClickEffectLevel.LIGHT })')
            state_args = [a for c in chains for a in c['args'].get('stateStyles', [])]
            if not any('pressed' in a and 'CouliColors.backgroundMuted' in a for a in state_args):
                out.append('C5 HIGHLIGHT 应为 stateStyles 的 pressed 背景 CouliColors.backgroundMuted')
            if not any(c['callee'] == 'MotionPolicy.press' and c['enclosing'].startswith('CouliPressable') for c in data['calls']):
                out.append('C5 CouliPressable 没经 MotionPolicy.press 退化')
            # v3（评审 r1 S2-3）：点击转发、kind 生效。
            for chain in clicks:
                if 'this.onTap' not in chain['clickCalls']:
                    out.append('C5 CouliPressable:%d .onClick 没有调用 this.onTap（点击丢失）' % chain['line'])
            press_calls = [c for c in data['calls'] if c['callee'] == 'MotionPolicy.press' and c['enclosing'].startswith('CouliPressable')]
            for call in press_calls:
                if len(call['args']) != 2 or call['args'][1] != 'this.kind':
                    out.append('C5 CouliPressable:%d MotionPolicy.press 第二实参应为 this.kind（kind 要生效）' % call['line'])
                elif 'reduced' not in call['args'][0]:
                    out.append('C5 CouliPressable:%d MotionPolicy.press 第一实参应读减弱动态' % call['line'])
            press_methods = [n for n, body in struct['methods'].items() if n != 'build' and 'MotionPolicy.press(' in body]
            for chain in chains:
                wanted = 'BOUNCE' if 'clickEffect' in chain['names'] else ('HIGHLIGHT' if 'stateStyles' in chain['names'] else None)
                if wanted is None:
                    continue
                conds = [g for g in chain['guards'] if g['kind'] == 'if' and 'PressKind.' in g['cond']]
                side = None
                if len(conds) == 1 and '||' not in conds[0]['cond'] and '&&' not in conds[0]['cond']:
                    cond = conds[0]['cond']
                    reads_press = 'MotionPolicy.press(' in cond or any('this.%s(' % n in cond for n in press_methods)
                    for literal, then_side in (('=== PressKind.BOUNCE', 'BOUNCE'), ('!== PressKind.HIGHLIGHT', 'BOUNCE'),
                                               ('=== PressKind.HIGHLIGHT', 'HIGHLIGHT'), ('!== PressKind.BOUNCE', 'HIGHLIGHT')):
                        if literal in cond and reads_press:
                            other = 'HIGHLIGHT' if then_side == 'BOUNCE' else 'BOUNCE'
                            side = then_side if conds[0]['branch'] == 'then' else other
                if side != wanted:
                    out.append('C5 CouliPressable:%d %s 应只在 %s 分支（条件为 press 结果与 PressKind 的单一比较），实际分支 %s' % (
                        chain['line'], chain['names'][0] if chain['names'] else '?', wanted, side))

    # C6：动效常量与纯逻辑
    for name, label in ((MOTION, 'CouliMotion'), (POLICY, 'MotionPolicy')):
        if name not in facts:
            continue
        data = facts[name]
        for number in data['numbers']:
            if number['value'] > 400 and not number['raw'].lower().startswith('0x'):
                out.append('C6 %s:%d 字面量 %s 超过 400' % (label, number['line'], number['raw']))
        for value in data['strings']:
            if value['value'].startswith('motion.') or value['value'].startswith('--motion'):
                out.append('C6 %s:%d 读 motion 令牌（D10-838）' % (label, value['line']))
        for imported in data['imports']:
            if 'CouliThemeTokens' in imported['module'] or imported['module'].startswith('generated') or \
                    any('Tokens' in n['imported'] for n in imported['names']):
                out.append('C6 %s:%d 导入令牌（D10-838）' % (label, imported['line']))
    if MOTION in facts:
        cls = facts[MOTION]['classes'].get('CouliMotion')
        if cls is None or not cls['exported']:
            out.append('C6 CouliMotion.ets 缺 export class CouliMotion')
        else:
            for prop in ('durationMicro', 'durationEnter', 'curve'):
                if prop not in cls['properties'] or not cls['properties'][prop]['static']:
                    out.append('C6 CouliMotion 缺静态成员 %s' % prop)
            for method in ('reduced', 'attach', 'run', 'appear', 'numeric', 'spring', 'responsive'):
                if method not in cls['methods'] or not cls['methods'][method]['static']:
                    out.append('C6 CouliMotion 缺静态方法 %s' % method)
    for name, label in ((MOMENTS, 'HapticMoments'), (POLICY, 'MotionPolicy')):
        if name not in facts:
            continue
        data = facts[name]
        for imported in data['imports']:
            if imported['module'].startswith(('@kit.', '@ohos.', '@hms.')):
                out.append('C6 %s 不许导入 %s（进 Logic.ets）' % (label, imported['module']))
        if any(c['callee'] in ('$r', '$rawfile') for c in data['calls']):
            out.append('C6 %s 不许用 $r' % label)

    # C7：目录 L1 / L2
    fixture = json.loads((ROOT / KINDS_FIXTURE).read_text(encoding='utf-8'))  # 判据随检查脚本走，不读被查的树
    expected_kind = {n: 'KIND_L1' for n in fixture['L1']}
    expected_kind.update({n: 'KIND_L2' for n in fixture['L2']})
    notes = {}
    if MANIFEST not in facts:
        out.append('C7 缺 %s' % MANIFEST)
    else:
        data = facts[MANIFEST]
        for const, value in (('KIND_L1', KIND_L1), ('KIND_L2', KIND_L2)):
            got = data['consts'].get(const)
            if got is None or got['value'] != value:
                out.append('C7 %s 应为 %r，实际 %r' % (const, value, got['value'] if got else None))
        for stale in ('KIND_SYSTEM', 'KIND_CUSTOM'):
            if stale in data['consts']:
                out.append('C7 旧常量 %s 还在' % stale)
        seen = {}
        for call in data['calls']:
            if call['callee'] == 'c' and len(call['args']) >= 4:
                name = strip_quotes(call['args'][0])
                seen[name] = call['args'][2]
                notes[name] = strip_quotes(call['args'][3])
        if set(seen) != set(expected_kind):
            out.append('C7 目录组件与分类表不一致：多 %s，少 %s' % (sorted(set(seen) - set(expected_kind)), sorted(set(expected_kind) - set(seen))))
        for name, kind in sorted(seen.items()):
            if name in expected_kind and kind != expected_kind[name]:
                out.append('C7 %s 应为 %s，实际 %s' % (name, expected_kind[name], kind))
        for name, must, must_not in (('CouliButton', '基于系统 Button', None), ('EmptyState', '页顶提示条', '外观不符'),
                                     ('AgentConsentSheet', '待 FU-HM-DIALOG', 'bindSheet'), ('AuthSheet', '待 FU-HM-DIALOG', 'bindSheet'),
                                     ('JumpTip', '待 FU-HM-DIALOG', 'openCustomDialog')):
            note = notes.get(name, '')
            if must not in note:
                out.append('C7 %s 的说明应含「%s」（§2.5 说明照实）' % (name, must))
            if must_not and must_not in note:
                out.append('C7 %s 的说明不应再写「%s」' % (name, must_not))
    inventory_text = text_of(root, INVENTORY)
    if inventory_text is None:
        out.append('C7 缺 %s' % INVENTORY)
    else:
        lines = [l for l in inventory_text.splitlines() if l and not l.startswith('#')]
        rows = list(csv.DictReader(io.StringIO('\n'.join(lines)), delimiter='\t'))
        seen_inventory = set()
        for row in rows:
            component = row['component']
            seen_inventory.add(component)
            wanted = KIND_L1 if expected_kind.get(component) == 'KIND_L1' else KIND_L2
            if component not in expected_kind:
                out.append('C7 inventory 有分类表外的组件 %s' % component)
            elif row['kinds'] != wanted:
                out.append('C7 inventory %s 第 3 列应为 %r，实际 %r' % (component, wanted, row['kinds']))
        if seen_inventory != set(expected_kind):
            out.append('C7 inventory 缺组件 %s' % sorted(set(expected_kind) - seen_inventory))
    stale_files = [n for n in EXPECTED + [CATALOG_TEST] if n in facts]
    for name in stale_files:
        if any(s['value'] in OLD_KINDS for s in facts[name]['strings']):
            out.append('C7 %s 还留旧的 KIND 值' % name)
    if CATALOG_TEST in facts:
        values = {s['value'] for s in facts[CATALOG_TEST]['strings']}
        if not {KIND_L1, KIND_L2} <= values:
            out.append('C7 %s 未钉新两值' % CATALOG_TEST)
    for name in STUBS:
        text = text_of(root, name)
        if text is not None and any("'%s'" % old in text for old in OLD_KINDS):
            out.append('C7 %s 还留旧的 KIND 值' % name)

    # C8：FeelLab
    if MANIFEST in facts and 'FeelLab' not in notes:
        out.append('C8 目录缺 FeelLab')
    catalog = {n: d for n, d in facts.items() if n.startswith(CATALOG_DIR + '/')}
    catalog_refs = {r['text'] for d in catalog.values() for r in d['refs']}
    for method in HAPTIC_METHODS:
        if 'CouliHaptics.' + method not in catalog_refs:
            out.append('C8 FeelLab 缺触感按钮 CouliHaptics.%s' % method)
    for wanted in ('PressKind.BOUNCE', 'PressKind.HIGHLIGHT', 'CouliMotion.reduced'):
        if wanted not in catalog_refs:
            out.append('C8 FeelLab 缺 %s' % wanted)
    for path in ets_files(release_folders(root)):
        if 'FeelLab' in path.read_text(encoding='utf-8'):
            out.append('C8 %s 含 FeelLab（只许 staging）' % rel(root, path))

    # C9：冷启动直达
    if STAGING_BV not in facts:
        out.append('C9 缺 %s' % STAGING_BV)
    else:
        data = facts[STAGING_BV]
        cls = data['classes'].get('BuildVariant', {'methods': {}})
        pushers = sorted({t['enclosing'] for t in data['tracked'] if not t['compared'] and t['enclosing'].startswith('BuildVariant.')})
        if not pushers:
            out.append('C9 staging BuildVariant 没有推 CATALOG_ROUTE 的冷启动路径')
        for pusher in pushers:
            method = pusher.split('.')[1]
            body = cls['methods'].get(method, {}).get('body', '')
            for needle, why in (('CatalogLaunch', '要看有没有待打开的组件'), ('presentationReady', '要等界面就绪'),
                                ('privacyState', '不绕过隐私门')):
                if needle not in body:
                    out.append('C9 %s 缺 %s（%s）' % (method, needle, why))
            settled = cls['methods'].get('environmentSettled', {}).get('body', '')
            if method != 'environmentSettled' and method not in settled:
                out.append('C9 %s 没有从 environmentSettled 调用' % method)
            outcome = eval_cold_start(body)
            if outcome.get('incomplete'):
                out.append('C9 %s 无法执行：%s' % (method, outcome['incomplete']))
            for row in outcome.get('results', []):
                wanted = row['pending'] and row['ready'] and row['privacy'] != 'not_decided'
                label = 'pending=%s ready=%s privacy=%s' % (row['pending'], row['ready'], row['privacy'])
                if 'error' in row:
                    out.append('C9 %s %s 抛错：%s' % (method, label, row['error']))
                elif row['pushed'] != wanted:
                    out.append('C9 %s %s 应%s推目录，实际%s推（D10-1163 ②）' % (method, label, '' if wanted else '不', '' if row['pushed'] else '没'))
        if pushers:
            launch_text = text_of(root, CATALOG_LAUNCH)
            if launch_text is None:
                out.append('C9 缺 %s' % CATALOG_LAUNCH)
            else:
                out += check_cold_retry(eval_cold_retry(launch_text, cls, data['consts']))
    for path in ets_files(release_folders(root)):
        text = path.read_text(encoding='utf-8')
        for needle in ('CatalogLaunch', 'CATALOG_ROUTE', 'couli.ds02.component'):
            if needle in text:
                out.append('C9 %s 含 %s（直达只在 staging）' % (rel(root, path), needle))

    # C10：登记
    list_text = text_of(root, LIST)
    if LIST not in facts or list_text is None:
        out.append('C10 缺 %s' % LIST)
    else:
        if not any(i['module'] == './FeelKit.test' for i in facts[LIST]['imports']):
            out.append('C10 List.test.ets 未导入 ./FeelKit.test')
        if not any(c['callee'] == 'feelKitTest' for c in facts[LIST]['calls']):
            out.append('C10 List.test.ets 未调用 feelKitTest')
    for index, table in ((LOGIC_INDEX, LOGIC_EXPORTS), (MAIN_INDEX, INDEX_EXPORTS)):
        exported = {}
        if index in facts:
            for item in facts[index]['exportsFrom']:
                exported.setdefault(item['module'].rsplit('/', 1)[-1], set()).update(item['names'])
        for module, names in table.items():
            lacking = names - exported.get(module, set())
            if lacking:
                out.append('C10 %s 未导出 %s（来自 %s）' % (index, sorted(lacking), module))
    if LOGIC_INDEX in facts:
        for item in facts[LOGIC_INDEX]['exportsFrom']:
            if item['module'].rsplit('/', 1)[-1] in KIT_COMPONENTS:
                out.append('C10 Logic.ets 不许导出 %s（带 @kit）' % item['module'])
    attaches = [(n, c) for n in sorted(production) for c in facts[n]['calls'] if c['callee'] == 'CouliMotion.attach']
    if len(attaches) != 1 or attaches[0][0] != ENTRY or not attaches[0][1]['enclosing'].endswith('loadRoot'):
        out.append('C10 CouliMotion.attach() 应恰 1 处，在 EntryAbility.loadRoot，实际 %s' % [(n, c['line']) for n, c in attaches])
    elif ENTRY in facts:
        calls = facts[ENTRY]['calls']
        attach_line = attaches[0][1]['line']
        install = [c['line'] for c in calls if c['callee'] == 'CouliTheme.install']
        load = [c['line'] for c in calls if c['callee'].endswith('.loadContent')]
        if not install or not load or not (install[0] < attach_line < load[0]):
            out.append('C10 CouliMotion.attach() 应在 CouliTheme.install 之后、loadContent 之前（实际行 %d）' % attach_line)
    verify_text = text_of(root, VERIFY) or ''
    commands = [l for l in verify_text.splitlines() if not l.lstrip().startswith('#')]
    for needle in ('tools/ci/feelkit/check_feel_kit.py" --self-test', 'tools/ci/feelkit/check_feel_kit.py" ||',
                   'tools/ci/feelkit/run-logic.cjs', 'tools/ci/feelkit/check-arkts.cjs" --real',
                   'tools/ci/feelkit/check_feel_kit.py" --hap "', 'tools/ci/feelkit/check_feel_kit.py" --hap-staging'):
        if not any(needle in l for l in commands):
            out.append('C10 verify.sh 缺一步：%s' % needle)
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


def check_hap(path, staging):
    out = []
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if n.endswith('module.json')]
        if not names:
            return ['C2 制品里没有 module.json']
        module = json.loads(z.read(names[0]).decode('utf-8'))
    out += check_permissions(permissions_of(module), str(path))
    hit = hap_contains(path, 'FeelLab')
    if staging and not hit:
        out.append('C8 %s 应含 FeelLab' % path)
    if not staging and hit:
        out.append('C8 %s 不应含 FeelLab（%s）' % (path, hit))
    return out


# ---------------------------------------------------------------- 自测：合成合规件 + 错误实现（REFERENCE_ONLY，不算产品通过）

REFERENCE = {
    MOMENTS: """export enum HapticMoment { SELECTION, SUCCESS, WARNING, FAILURE, THRESHOLD }

export const HAPTIC_EFFECT: Map<HapticMoment, string> = new Map<HapticMoment, string>([
  [HapticMoment.SELECTION, 'haptic.clock.timer'],
  [HapticMoment.SUCCESS, 'haptic.notice.success'],
  [HapticMoment.WARNING, 'haptic.notice.warning'],
  [HapticMoment.FAILURE, 'haptic.notice.fail'],
  [HapticMoment.THRESHOLD, 'haptic.effect.sharp']
]);

export interface HapticPort {
  supported(id: string): boolean;
  vibrate(id: string): void;
}

export class HapticPlan {
  private port: HapticPort;

  constructor(port: HapticPort) {
    this.port = port;
  }

  emit(moment: HapticMoment): void {
    const id: string | undefined = HAPTIC_EFFECT.get(moment);
    if (id === undefined) {
      return;
    }
    try {
      if (this.port.supported(id)) {
        this.port.vibrate(id);
      }
    } catch (e) {
      return;
    }
  }
}
""",
    POLICY: """export enum MotionKind { MICRO, ENTER }

export enum PressKind { BOUNCE, HIGHLIGHT }

export class MotionSpec {
  durationMs: number;
  zeroTranslate: boolean;
  fadeMs: number;

  constructor(durationMs: number, zeroTranslate: boolean, fadeMs: number) {
    this.durationMs = durationMs;
    this.zeroTranslate = zeroTranslate;
    this.fadeMs = fadeMs;
  }
}

export class MotionPolicy {
  static resolve(reduced: boolean, kind: MotionKind): MotionSpec {
    if (reduced) {
      return new MotionSpec(0, true, 150);
    }
    const duration: number = kind === MotionKind.MICRO ? 150 : 250;
    return new MotionSpec(duration, false, duration);
  }

  static press(reduced: boolean, kind: PressKind): PressKind {
    return reduced ? PressKind.HIGHLIGHT : kind;
  }
}
""",
    HAPTICS: """import { vibrator } from '@kit.SensorServiceKit';
import { HapticMoment, HapticPlan, HapticPort } from '../logic/HapticMoments';

class SystemHapticPort implements HapticPort {
  private cache: Map<string, boolean> = new Map<string, boolean>();

  supported(id: string): boolean {
    const known: boolean | undefined = this.cache.get(id);
    if (known !== undefined) {
      return known;
    }
    let result: boolean = false;
    try {
      result = vibrator.isSupportEffectSync(id);
    } catch (e) {
      result = false;
    }
    this.cache.set(id, result);
    return result;
  }

  vibrate(id: string): void {
    vibrator.startVibration({ type: 'preset', effectId: id, count: 1 }, { usage: 'touch' }).catch((): void => {
    });
  }
}

export class CouliHaptics {
  private static plan: HapticPlan = new HapticPlan(new SystemHapticPort());

  static selection(): void {
    CouliHaptics.plan.emit(HapticMoment.SELECTION);
  }

  static success(): void {
    CouliHaptics.plan.emit(HapticMoment.SUCCESS);
  }

  static warning(): void {
    CouliHaptics.plan.emit(HapticMoment.WARNING);
  }

  static failure(): void {
    CouliHaptics.plan.emit(HapticMoment.FAILURE);
  }

  static threshold(): void {
    CouliHaptics.plan.emit(HapticMoment.THRESHOLD);
  }
}
""",
    MOTION: """import { curves } from '@kit.ArkUI';
import { accessibility } from '@kit.AccessibilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';

export class CouliMotion {
  static readonly durationMicro: number = 150;
  static readonly durationEnter: number = 250;
  static readonly curve: Curve = Curve.Friction;
  private static reduceOn: boolean = false;
  private static attached: boolean = false;

  static spring(): ICurve {
    return curves.springMotion();
  }

  static responsive(): ICurve {
    return curves.responsiveSpringMotion();
  }

  static appear(): TransitionEffect {
    if (CouliMotion.reduced()) {
      return TransitionEffect.OPACITY.animation({ duration: CouliMotion.durationMicro, curve: CouliMotion.curve });
    }
    return TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 8 }));
  }

  static numeric(): NumericTextTransition {
    return new NumericTextTransition();
  }

  static run(uiContext: UIContext, duration: number, change: () => void): void {
    if (CouliMotion.reduced()) {
      change();
      return;
    }
    uiContext.animateTo({ duration: duration, curve: CouliMotion.curve }, change);
  }

  static reduced(): boolean {
    return CouliMotion.reduceOn;
  }

  private static readAnimationReduce(): boolean {
    try {
      if (deviceInfo.sdkApiVersion >= 23) {
        return accessibility.isAnimationReduceEnabledSync();
      }
    } catch (e) {
      return false;
    }
    return false;
  }

  static attach(): void {
    CouliMotion.reduceOn = CouliMotion.readAnimationReduce();
    if (CouliMotion.attached) {
      return;
    }
    CouliMotion.attached = true;
    try {
      if (deviceInfo.sdkApiVersion >= 23) {
        accessibility.onAnimationReduceStateChange((on: boolean): void => {
          CouliMotion.reduceOn = on;
        });
      }
    } catch (e) {
      CouliMotion.reduceOn = false;
    }
  }
}
""",
    PRESSABLE: """import { CouliColors } from '../CouliColors';
import { CouliMotion } from './CouliMotion';
import { MotionPolicy, PressKind } from '../logic/MotionPolicy';

@Builder
function emptyContent() {
}

@ComponentV2
export struct CouliPressable {
  @Param kind: PressKind = PressKind.HIGHLIGHT;
  @Event onTap: () => void = (): void => {
  };
  @BuilderParam content: () => void = emptyContent;

  build() {
    if (MotionPolicy.press(CouliMotion.reduced(), this.kind) === PressKind.BOUNCE) {
      Stack() {
        this.content()
      }
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .onClick((): void => {
        this.onTap();
      })
    } else {
      Stack() {
        this.content()
      }
      .stateStyles({
        pressed: { .backgroundColor(CouliColors.backgroundMuted) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => {
        this.onTap();
      })
    }
  }
}
""",
    LOGIC_INDEX: """export { HapticMoment, HAPTIC_EFFECT, HapticPlan, HapticPort } from './src/main/ets/logic/HapticMoments';
export { MotionPolicy, MotionKind, MotionSpec, PressKind } from './src/main/ets/logic/MotionPolicy';
""",
    MAIN_INDEX: """export { CouliHaptics } from './src/main/ets/components/CouliHaptics';
export { CouliMotion } from './src/main/ets/components/CouliMotion';
export { CouliPressable } from './src/main/ets/components/CouliPressable';
export { PressKind } from './src/main/ets/logic/MotionPolicy';
""",
    MODULE: """{
  // 注释
  "module": {
    "name": "entry",
    "requestPermissions": [
      { "name": "ohos.permission.INTERNET" },
      { "name": "ohos.permission.VIBRATE" }
    ]
  }
}
""",
    ENTRY: """import { CouliTheme, CouliMotion } from 'designsystem';

class EntryAbility {
  loadRoot(windowStage: object): void {
    CouliTheme.install(this.context, BuildVariant.themeNeutralPreset());
    CouliMotion.attach();
    windowStage.loadContent('pages/RootPage');
  }
}
""",
    STAGING_BV: """import { CATALOG_ROUTE } from '../catalog/ComponentCatalog';
import { CatalogLaunch } from '../catalog/CatalogLaunch';

const CATALOG_RETRY_MS: number = 200;
const CATALOG_RETRY_LIMIT: number = 75;

export class BuildVariant {
  private static catalogRetries: number = 0;

  static environmentSettled(): void {
    BuildVariant.catalogRetries = 0;
    BuildVariant.openPendingCatalog();
  }

  private static openPendingCatalog(): void {
    if (!CatalogLaunch.shared.hasPending() || AppRouting.shared.privacyState === PrivacyState.NOT_DECIDED) {
      return;
    }
    if (!AppRouting.shared.presentationReady) {
      BuildVariant.retryPendingCatalog();
      return;
    }
    CatalogLaunch.shared.markOpening();
    AppRouting.shared.push(CATALOG_ROUTE);
  }

  private static retryPendingCatalog(): void {
    if (BuildVariant.catalogRetries >= CATALOG_RETRY_LIMIT) {
      return;
    }
    BuildVariant.catalogRetries++;
    setTimeout((): void => BuildVariant.openPendingCatalog(), CATALOG_RETRY_MS);
  }

  static routeName(name: string): boolean {
    return name === CATALOG_ROUTE;
  }
}
""",
    CATALOG_LAUNCH: """import { catalogComponent } from './CatalogManifest';

export class CatalogLaunch {
  static readonly shared: CatalogLaunch = new CatalogLaunch();
  private pending: string = '';
  private opening: boolean = false;

  request(value: Object | undefined): void {
    if (typeof value === 'string' && catalogComponent(value) !== undefined) {
      this.pending = value;
    }
  }

  take(): string {
    const name: string = this.pending;
    this.pending = '';
    this.opening = false;
    return name;
  }

  hasPending(): boolean {
    return this.pending.length > 0 && !this.opening;
  }

  markOpening(): void {
    this.opening = true;
  }
}
""",
    CATALOG_DIR + '/FeelLab.ets': """import { CouliHaptics, CouliMotion, CouliPressable, PressKind } from 'designsystem';

export function feelLabActions(): void {
  CouliHaptics.selection();
  CouliHaptics.success();
  CouliHaptics.warning();
  CouliHaptics.failure();
  CouliHaptics.threshold();
  const kinds: PressKind[] = [PressKind.BOUNCE, PressKind.HIGHLIGHT];
  const reduced: boolean = CouliMotion.reduced();
}
""",
    CATALOG_TEST: """const ok = (kind: string): boolean => kind === 'L1 系统控件' || kind === 'L2 业务组件';
""",
    EXPECTED[0]: "export const X: string = 'L1 系统控件';\n",
    EXPECTED[1]: "export const X: string = 'L2 业务组件';\n",
    STUBS[0]: "const kind = 'L2 业务组件';\n",
    STUBS[1]: "const kind = 'L2 业务组件';\n",
    LIST: """import feelKitTest from './FeelKit.test';

export default function testsuite() {
  feelKitTest();
}
""",
    VERIFY: """#!/usr/bin/env bash
python3 "$ROOT/tools/ci/feelkit/check_feel_kit.py" --self-test || fail
python3 "$ROOT/tools/ci/feelkit/check_feel_kit.py" || fail
node "$ROOT/tools/ci/feelkit/run-logic.cjs" || fail
node "$ROOT/tools/ci/feelkit/check-arkts.cjs" --real || fail
python3 "$ROOT/tools/ci/feelkit/check_feel_kit.py" --hap "$OUT_DIR/Release.hap" || fail
python3 "$ROOT/tools/ci/feelkit/check_feel_kit.py" --hap-staging "$OUT_DIR/$cfg.hap" || fail
""",
    'features/home/src/main/ets/HomePage.ets': "export const HOME: string = 'home';\n",
    'entry/src/release/ets/variant/BuildVariant.ets': 'export class BuildVariant {\n  static environmentSettled(): void {\n  }\n}\n',
}

NOTES = {
    'CouliButton': '基于系统 Button（品牌色由令牌）；组件库 L2 样式',
    'EmptyState': '系统 ExceptionPrompt 是页顶提示条，整页空态无系统等价件，保留 L2',
    'AgentConsentSheet': '现为居中自定义弹窗，待 FU-HM-DIALOG / SHEET 换系统容器',
    'AuthSheet': '现为居中自定义弹窗，待 FU-HM-DIALOG / SHEET 换系统容器',
    'JumpTip': '现为页面内自绘，待 FU-HM-DIALOG / SHEET 换系统容器',
}


def reference_tree(target):
    fixture = json.loads((ROOT / KINDS_FIXTURE).read_text(encoding='utf-8'))
    manifest = ["export const KIND_L1: string = 'L1 系统控件';", "export const KIND_L2: string = 'L2 业务组件';", 'export const CATALOG_COMPONENTS = [']
    inventory = ['# 注释', 'component\tsection\tkinds\tvariants\tstates']
    for kind, constant, label in (('L1', 'KIND_L1', KIND_L1), ('L2', 'KIND_L2', KIND_L2)):
        for name in fixture[kind]:
            manifest.append("  c('%s', GROUP, %s, '%s', [m(['a'], ['b'])])," % (name, constant, NOTES.get(name, '说明')))
            inventory.append('%s\t§x\t%s\ta\tb' % (name, label))
    manifest.append('];')
    files = dict(REFERENCE)
    files[MANIFEST] = '\n'.join(manifest) + '\n'
    files[INVENTORY] = '\n'.join(inventory) + '\n'
    for name, text in files.items():
        path = target / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
    (target / SUITE).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / SUITE, target / SUITE)


GUARD = 'if (deviceInfo.sdkApiVersion >= 23) {\n        return accessibility.isAnimationReduceEnabledSync();\n      }'

# (名字, 文件, 旧串, 新串, 期望命中的违反前缀)；旧串在文件里必须恰好一次。
HOST_MUTANTS = [
    ('别处导入 vibrator', 'features/home/src/main/ets/HomePage.ets', "export const HOME", "import { vibrator } from '@kit.SensorServiceKit';\nexport const HOME", 'C1'),
    ('别处默认导入 @ohos.vibrator', 'features/home/src/main/ets/HomePage.ets', "export const HOME", "import vibrator from '@ohos.vibrator';\nexport const HOME", 'C1'),
    ('CouliHaptics 没导入 vibrator', HAPTICS, "import { vibrator } from '@kit.SensorServiceKit';", "import { vibrator } from './fake';", 'C1'),
    ('VIBRATE 没声明', MODULE, '      { "name": "ohos.permission.VIBRATE" }\n', '', 'C2'),
    ('多声明一项权限', MODULE, '{ "name": "ohos.permission.VIBRATE" }', '{ "name": "ohos.permission.VIBRATE" },\n      { "name": "ohos.permission.CAMERA" }', 'C2'),
    ('VIBRATE 带多余字段', MODULE, '{ "name": "ohos.permission.VIBRATE" }', '{ "name": "ohos.permission.VIBRATE", "reason": "$string:x" }', 'C2'),
    ('页面调触感', 'features/home/src/main/ets/HomePage.ets', "export const HOME: string = 'home';", "export const HOME: string = 'home';\nexport function f(): void { CouliHaptics.success(); }", 'C3'),
    ('按压件自己震', PRESSABLE, "        this.onTap();\n      })\n    } else {", "        CouliHaptics.selection();\n        this.onTap();\n      })\n    } else {", 'C3'),
    ('页面自建 HapticPlan', 'features/home/src/main/ets/HomePage.ets', "export const HOME", "import { HapticPlan } from 'designsystem/Logic';\nexport const HOME", 'C3'),
    ('暴露可注入 API', HAPTICS, "  static selection(): void {", "  static setPort(port: HapticPort): void {\n  }\n\n  static selection(): void {", 'C3'),
    ('入口带参数', HAPTICS, "  static warning(): void {", "  static warning(extra: number): void {", 'C3'),
    ('单例公开', HAPTICS, "private static plan", "static plan", 'C3'),
    ('读取去掉版本判断', MOTION, GUARD, 'return accessibility.isAnimationReduceEnabledSync();', 'C4'),
    ('读取用间接变量', MOTION, GUARD, 'const ok: boolean = deviceInfo.sdkApiVersion >= 23;\n      if (ok) {\n        return accessibility.isAnimationReduceEnabledSync();\n      }', 'C4'),
    ('读取放进 else 分支', MOTION, GUARD, 'if (deviceInfo.sdkApiVersion < 23) {\n        return false;\n      } else {\n        return accessibility.isAnimationReduceEnabledSync();\n      }', 'C4'),
    ('复合条件', MOTION, GUARD, 'if (deviceInfo.sdkApiVersion >= 23 && CouliMotion.attached) {\n        return accessibility.isAnimationReduceEnabledSync();\n      }', 'C4'),
    ('门槛写成 22', MOTION, GUARD, 'if (deviceInfo.sdkApiVersion >= 22) {\n        return accessibility.isAnimationReduceEnabledSync();\n      }', 'C4'),
    ('只靠 try 不判版本的订阅', MOTION, "      if (deviceInfo.sdkApiVersion >= 23) {\n        accessibility.onAnimationReduceStateChange((on: boolean): void => {\n          CouliMotion.reduceOn = on;\n        });\n      }", "      accessibility.onAnimationReduceStateChange((on: boolean): void => {\n        CouliMotion.reduceOn = on;\n      });", 'C4'),
    ('没导入 deviceInfo', MOTION, "import { deviceInfo } from '@kit.BasicServicesKit';\n", '', 'C4'),
    ('裸 onClick 无反馈', PRESSABLE, "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n", '', 'C5'),
    ('BOUNCE 等级错', PRESSABLE, 'ClickEffectLevel.LIGHT', 'ClickEffectLevel.HEAVY', 'C5'),
    ('HIGHLIGHT 没 pressed 背景', PRESSABLE, 'pressed: { .backgroundColor(CouliColors.backgroundMuted) },\n', '', 'C5'),
    ('不退化', PRESSABLE, 'MotionPolicy.press(CouliMotion.reduced(), this.kind)', 'this.kind', 'C5'),
    ('用 V1 组件', PRESSABLE, '@ComponentV2', '@Component', 'C5'),
    ('时长超 400', MOTION, 'durationEnter: number = 250', 'durationEnter: number = 500', 'C6'),
    ('读 motion 令牌', MOTION, "static readonly curve: Curve = Curve.Friction;", "static readonly token: string = 'motion.duration.fast';\n  static readonly curve: Curve = Curve.Friction;", 'C6'),
    ('纯逻辑带 @kit', POLICY, 'export enum MotionKind', "import { curves } from '@kit.ArkUI';\nexport enum MotionKind", 'C6'),
    ('缺 durationMicro', MOTION, 'static readonly durationMicro: number = 150;\n', '', 'C6'),
    ('KIND 字符串拼错', MANIFEST, "KIND_L2: string = 'L2 业务组件'", "KIND_L2: string = 'L2 业务控件'", 'C7'),
    ('还留旧常量', MANIFEST, "export const CATALOG_COMPONENTS", "export const KIND_SYSTEM: string = '系统控件';\nexport const CATALOG_COMPONENTS", 'C7'),
    ('组件分类错', MANIFEST, "c('CouliButton', GROUP, KIND_L2", "c('CouliButton', GROUP, KIND_L1", 'C7'),
    ('inventory 没同步', INVENTORY, 'CouliButton\t§x\tL2 业务组件', 'CouliButton\t§x\tL1 系统控件', 'C7'),
    ('inventory 仍双值', INVENTORY, 'FilterChip\t§x\tL2 业务组件', 'FilterChip\t§x\tL1 系统控件/L2 业务组件', 'C7'),
    ('Expected 留旧值', EXPECTED[0], "'L1 系统控件'", "'系统控件'", 'C7'),
    ('Ds02Catalog 没改', CATALOG_TEST, "'L2 业务组件'", "'自绘'", 'C7'),
    ('run-unit 留旧值', STUBS[0], "'L2 业务组件'", "'自绘'", 'C7'),
    ('说明还写 bindSheet', MANIFEST, "c('AuthSheet', GROUP, KIND_L2, '现为居中自定义弹窗，待 FU-HM-DIALOG / SHEET 换系统容器'", "c('AuthSheet', GROUP, KIND_L2, '容器 bindSheet，待 FU-HM-DIALOG'", 'C7'),
    ('说明没照实', MANIFEST, '基于系统 Button（品牌色由令牌）；组件库 L2 样式', '系统 Button', 'C7'),
    ('FeelLab 被 Release 带入', 'entry/src/release/ets/variant/BuildVariant.ets', 'export class BuildVariant {', "const NAME: string = 'FeelLab';\nexport class BuildVariant {", 'C8'),
    ('FeelLab 不在目录', MANIFEST, "  c('FeelLab', GROUP, KIND_L2, '说明', [m(['a'], ['b'])]),\n", '', 'C8'),
    ('样例缺一个触感', CATALOG_DIR + '/FeelLab.ets', '  CouliHaptics.threshold();\n', '', 'C8'),
    ('样例缺按压', CATALOG_DIR + '/FeelLab.ets', 'PressKind.BOUNCE, PressKind.HIGHLIGHT', 'PressKind.HIGHLIGHT', 'C8'),
    ('没有冷启动直达', STAGING_BV, '    AppRouting.shared.push(CATALOG_ROUTE);\n', '', 'C9'),
    ('冷启动绕过隐私', STAGING_BV, " || AppRouting.shared.privacyState === PrivacyState.NOT_DECIDED", '', 'C9'),
    ('冷启动只认 CONSENTED', STAGING_BV, 'privacyState === PrivacyState.NOT_DECIDED', 'privacyState !== PrivacyState.CONSENTED', 'C9'),
    ('冷启动隐私判断写反', STAGING_BV, 'privacyState === PrivacyState.NOT_DECIDED', 'privacyState !== PrivacyState.NOT_DECIDED', 'C9'),
    ('冷启动不看待打开组件', STAGING_BV, '!CatalogLaunch.shared.hasPending() || ', 'CatalogLaunch.shared === undefined || ', 'C9'),
    ('直达带进 Release', 'entry/src/release/ets/variant/BuildVariant.ets', 'export class BuildVariant {', "const KEY: string = 'couli.ds02.component';\nexport class BuildVariant {", 'C9'),
    ('冷启动不等就绪', STAGING_BV, "    if (!AppRouting.shared.presentationReady) {\n      BuildVariant.retryPendingCatalog();\n      return;\n    }\n", '', 'C9'),
    ('去重试上限', STAGING_BV, "    if (BuildVariant.catalogRetries >= CATALOG_RETRY_LIMIT) {\n      return;\n    }\n", '', 'C9'),
    ('NOT_DECIDED 进重试', STAGING_BV, "if (!CatalogLaunch.shared.hasPending() || AppRouting.shared.privacyState === PrivacyState.NOT_DECIDED) {\n      return;\n    }\n    if (!AppRouting.shared.presentationReady) {", "if (!CatalogLaunch.shared.hasPending()) {\n      return;\n    }\n    if (!AppRouting.shared.presentationReady || AppRouting.shared.privacyState === PrivacyState.NOT_DECIDED) {", 'C9'),
    ('去 markOpening', STAGING_BV, '    CatalogLaunch.shared.markOpening();\n', '', 'C9'),
    ('不重试', STAGING_BV, '      BuildVariant.retryPendingCatalog();\n', '', 'C9'),
    ('重试零延时', STAGING_BV, 'CATALOG_RETRY_MS: number = 200', 'CATALOG_RETRY_MS: number = 0', 'C9'),
    ('take 不清 opening', CATALOG_LAUNCH, "    this.pending = '';\n    this.opening = false;\n", "    this.pending = '';\n", 'C9'),
    ('高亮分支不转发点击', PRESSABLE, "        normal: { .backgroundColor(Color.Transparent) }\n      })\n      .onClick((): void => {\n        this.onTap();\n", "        normal: { .backgroundColor(Color.Transparent) }\n      })\n      .onClick((): void => {\n", 'C5'),
    ('回弹分支不转发点击', PRESSABLE, "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .onClick((): void => {\n        this.onTap();\n", "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .onClick((): void => {\n", 'C5'),
    ('转发被注释掉', PRESSABLE, "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .onClick((): void => {\n        this.onTap();\n", "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .onClick((): void => {\n        // this.onTap();\n", 'C5'),
    ('忽略 kind 一律 BOUNCE', PRESSABLE, 'MotionPolicy.press(CouliMotion.reduced(), this.kind)', 'MotionPolicy.press(CouliMotion.reduced(), PressKind.BOUNCE)', 'C5'),
    ('press 不读减弱动态', PRESSABLE, 'MotionPolicy.press(CouliMotion.reduced(), this.kind)', 'MotionPolicy.press(false, this.kind)', 'C5'),
    ('分支条件恒真', PRESSABLE, '=== PressKind.BOUNCE) {', '=== PressKind.BOUNCE || this.kind === this.kind) {', 'C5'),
    ('两个分支反了', PRESSABLE, '=== PressKind.BOUNCE) {', '=== PressKind.HIGHLIGHT) {', 'C5'),
    ('没挂 environmentSettled', STAGING_BV, '    BuildVariant.openPendingCatalog();\n', '', 'C9'),
    ('List 没登记', LIST, '  feelKitTest();\n', '', 'C10'),
    ('Logic.ets 没导出', LOGIC_INDEX, 'export { MotionPolicy, MotionKind, MotionSpec, PressKind }', 'export { MotionPolicy, MotionKind, MotionSpec }', 'C10'),
    ('Logic.ets 带 @kit 文件', LOGIC_INDEX, 'export { MotionPolicy,', "export { CouliHaptics } from './src/main/ets/components/CouliHaptics';\nexport { MotionPolicy,", 'C10'),
    ('Index 没导出 PressKind', MAIN_INDEX, "export { PressKind } from './src/main/ets/logic/MotionPolicy';\n", '', 'C10'),
    ('Index 没导出', MAIN_INDEX, "export { CouliMotion } from './src/main/ets/components/CouliMotion';\n", '', 'C10'),
    ('没 attach', ENTRY, '    CouliMotion.attach();\n', '', 'C10'),
    ('attach 在主题之前', ENTRY, "    CouliTheme.install(this.context, BuildVariant.themeNeutralPreset());\n    CouliMotion.attach();\n", "    CouliMotion.attach();\n    CouliTheme.install(this.context, BuildVariant.themeNeutralPreset());\n", 'C10'),
    ('verify 缺一步', VERIFY, 'node "$ROOT/tools/ci/feelkit/run-logic.cjs" || fail\n', '', 'C10'),
    ('verify 只在注释里', VERIFY, 'python3 "$ROOT/tools/ci/feelkit/check_feel_kit.py" --self-test || fail', '# python3 "$ROOT/tools/ci/feelkit/check_feel_kit.py" --self-test || fail', 'C10'),
]

# 书 §3.3 的行为变异：打在合成合规件上，run-logic 必须至少一条红。
LOGIC_MUTANTS = [
    ('映射错 id', MOMENTS, "'haptic.notice.fail'", "'haptic.notice.failure'"),
    ('SELECTION 用 soft', MOMENTS, "'haptic.clock.timer'", "'haptic.effect.soft'"),
    ('两时刻同一 id', MOMENTS, "'haptic.notice.warning'", "'haptic.notice.fail'"),
    ('不支持时仍振动', MOMENTS, 'if (this.port.supported(id)) {', 'this.port.supported(id);\n      {'),
    ('端口抛错外溢', MOMENTS, '    } catch (e) {\n      return;\n    }', '    } catch (e) {\n      throw e;\n    }'),
    ('连发去重', MOMENTS, '  emit(moment: HapticMoment): void {\n', '  private last: HapticMoment | undefined = undefined;\n\n  emit(moment: HapticMoment): void {\n    if (this.last === moment) {\n      return;\n    }\n    this.last = moment;\n'),
    ('减弱动态时长不归零', POLICY, 'return new MotionSpec(0, true, 150);', 'return new MotionSpec(150, true, 150);'),
    ('减弱动态仍位移', POLICY, 'return new MotionSpec(0, true, 150);', 'return new MotionSpec(0, false, 150);'),
    ('减弱淡入归零（策略）', POLICY, 'return new MotionSpec(0, true, 150);', 'return new MotionSpec(0, true, 0);'),
    ('减弱淡入过长（策略）', POLICY, 'return new MotionSpec(0, true, 150);', 'return new MotionSpec(0, true, 300);'),
    ('不减弱淡入不跟时长', POLICY, 'return new MotionSpec(duration, false, duration);', 'return new MotionSpec(duration, false, 150);'),
    ('减弱动态不生效', POLICY, 'if (reduced) {', 'if (!reduced && false) {'),
    ('时长对调', POLICY, 'kind === MotionKind.MICRO ? 150 : 250', 'kind === MotionKind.MICRO ? 250 : 150'),
    ('减弱淡入没带时长', MOTION, 'return TransitionEffect.OPACITY.animation({ duration: CouliMotion.durationMicro, curve: CouliMotion.curve });', 'return TransitionEffect.OPACITY;'),
    ('减弱淡入 0 时长', MOTION, 'TransitionEffect.OPACITY.animation({ duration: CouliMotion.durationMicro,', 'TransitionEffect.OPACITY.animation({ duration: 0,'),
    ('减弱淡入过长', MOTION, 'TransitionEffect.OPACITY.animation({ duration: CouliMotion.durationMicro,', 'TransitionEffect.OPACITY.animation({ duration: 400,'),
    ('减弱取消淡入', MOTION, 'return TransitionEffect.OPACITY.animation({ duration: CouliMotion.durationMicro, curve: CouliMotion.curve });', 'return TransitionEffect.IDENTITY;'),
    ('Press 不退化', POLICY, 'return reduced ? PressKind.HIGHLIGHT : kind;', 'return kind;'),
    ('Press 全退化', POLICY, 'return reduced ? PressKind.HIGHLIGHT : kind;', 'return PressKind.HIGHLIGHT;'),
    ('usage 不是 touch', HAPTICS, "{ usage: 'touch' }", "{ usage: 'notification' }"),
    ('不走 preset', HAPTICS, "type: 'preset', effectId: id, count: 1", "type: 'preset', effectId: 'haptic.clock.timer', count: 1"),
    ('count 多', HAPTICS, 'count: 1', 'count: 2'),
    ('不缓存', HAPTICS, '    this.cache.set(id, result);\n', ''),
    ('查询抛错当成支持', HAPTICS, '    } catch (e) {\n      result = false;\n    }', '    } catch (e) {\n      result = true;\n    }'),
    ('reject 没接', HAPTICS, ".catch((): void => {\n    });", ';'),
    ('入口映射错', HAPTICS, 'emit(HapticMoment.WARNING)', 'emit(HapticMoment.FAILURE)'),
    ('appear 减弱仍位移', MOTION, '    if (CouliMotion.reduced()) {\n      return TransitionEffect.OPACITY.animation({ duration: CouliMotion.durationMicro, curve: CouliMotion.curve });\n    }\n', ''),
    ('appear 不淡入', MOTION, 'TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 8 }))', 'TransitionEffect.translate({ y: 8 })'),
    ('run 减弱仍动画', MOTION, '    if (CouliMotion.reduced()) {\n      change();\n      return;\n    }\n', ''),
    ('run 用错曲线', MOTION, '{ duration: duration, curve: CouliMotion.curve }', '{ duration: duration, curve: Curve.Linear }'),
    ('读取不判版本（行为）', MOTION, GUARD, 'return accessibility.isAnimationReduceEnabledSync();'),
    ('订阅多次', MOTION, '    if (CouliMotion.attached) {\n      return;\n    }\n', ''),
    ('开关不写回', MOTION, '          CouliMotion.reduceOn = on;\n', ''),
    ('订阅抛错外溢', MOTION, '    } catch (e) {\n      CouliMotion.reduceOn = false;\n    }', '    } catch (e) {\n      throw e;\n    }'),
    ('曲线不是 Friction', MOTION, 'Curve = Curve.Friction', 'Curve = Curve.Linear'),
    ('时长改值', MOTION, 'durationMicro: number = 150', 'durationMicro: number = 200'),
]


def apply_mutant(root, name, rel_path, old, new):
    path = root / rel_path
    text = path.read_text(encoding='utf-8')
    if text.count(old) != 1:
        raise SystemExit('自测定位串不是恰好一次：%s（%d 次）' % (name, text.count(old)))
    path.write_text(text.replace(old, new), encoding='utf-8')


def run_logic(root, expect_red):
    command = ['node', str(RUN_LOGIC), '--root', str(root)] + (['--expect-red'] if expect_red else [])
    return subprocess.run(command, capture_output=True, text=True, timeout=120)


def self_test():
    failures = 0
    work = Path(tempfile.mkdtemp(prefix='feelkit-selftest-'))
    try:
        clean = work / 'clean'
        reference_tree(clean)
        violations = check_tree(clean)
        if violations:
            print('合成合规件应 0 违反：')
            for v in violations:
                print('  ' + v)
            return 1
        print('REFERENCE_ONLY 合成合规件 0 违反')
        result = run_logic(clean, False)
        if result.returncode != 0:
            print('合成合规件 run-logic 应全绿：\n' + result.stdout + result.stderr)
            return 1
        print('REFERENCE_ONLY ' + result.stdout.strip().splitlines()[-1].split(';')[0])
        for name, rel_path, old, new, rule in HOST_MUTANTS:
            tree = work / 'mutant'
            shutil.rmtree(tree, ignore_errors=True)
            shutil.copytree(clean, tree)
            apply_mutant(tree, name, rel_path, old, new)
            violations = check_tree(tree)
            hits = [v for v in violations if v.startswith(rule + ' ')]
            if hits:
                print('KILLED [%s] %s' % (rule, name))
            else:
                failures += 1
                print('SURVIVED [%s] %s：%s' % (rule, name, violations))
        for name, rel_path, old, new in LOGIC_MUTANTS:
            tree = work / 'mutant'
            shutil.rmtree(tree, ignore_errors=True)
            shutil.copytree(clean, tree)
            apply_mutant(tree, name, rel_path, old, new)
            result = run_logic(tree, True)
            if result.returncode == 0:
                print('KILLED [logic] %s' % name)
            else:
                failures += 1
                print('SURVIVED [logic] %s\n%s' % (name, result.stdout[-400:]))
        failures += self_test_hap(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    total = len(HOST_MUTANTS) + len(LOGIC_MUTANTS) + 4
    print('self-test: %d 个错误实现，%d 个未拦' % (total, failures))
    return 1 if failures else 0


def self_test_hap(work):
    failures = 0
    good = json.dumps({'module': {'requestPermissions': [{'name': 'ohos.permission.INTERNET'}, {'name': VIBRATE}]}})
    bad = json.dumps({'module': {'requestPermissions': [{'name': 'ohos.permission.INTERNET'}]}})

    def make(name, module, payload):
        path = work / name
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('module.json', module)
            z.writestr('ets/modules.abc', payload)
        return path

    clean_release = make('release.hap', good, b'nothing')
    clean_staging = make('staging.hap', good, 'FeelLab'.encode('utf-16-le'))
    if check_hap(clean_release, False) or check_hap(clean_staging, True):
        print('SURVIVED hap 干净包应 0 违反')
        failures += 1
    for name, path, staging, rule in (('制品缺 VIBRATE', make('a.hap', bad, b'x'), False, 'C2'),
                                      ('Release 带 FeelLab', make('b.hap', good, b'FeelLab'), False, 'C8'),
                                      ('Staging 缺 FeelLab', make('c.hap', good, b'x'), True, 'C8'),
                                      ('Staging 缺 VIBRATE', make('d.hap', bad, b'FeelLab'), True, 'C2')):
        if any(v.startswith(rule + ' ') for v in check_hap(path, staging)):
            print('KILLED [hap] %s' % name)
        else:
            failures += 1
            print('SURVIVED [hap] %s' % name)
    return failures


def main(argv):
    args = argv[1:]
    if '--self-test' in args:
        return self_test()
    for flag, staging in (('--hap', False), ('--hap-staging', True)):
        if flag in args:
            violations = check_hap(Path(args[args.index(flag) + 1]), staging)
            for v in violations:
                print(v)
            print('FEELKIT hap (%s): %d 项违反' % ('staging' if staging else 'release', len(violations)))
            return 1 if violations else 0
    root = Path(args[args.index('--root') + 1]).resolve() if '--root' in args else ROOT
    violations = check_tree(root)
    for v in violations:
        print(v)
    print('FEELKIT host: %d 项违反; root=%s' % (len(violations), root))
    return 1 if violations else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
