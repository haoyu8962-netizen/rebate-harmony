#!/usr/bin/env python3
"""TOKENS-PIPE-harmony 测试作者 v1：令牌管线宿主检查（只用 Python 3 标准库 + node 执行生成的令牌数据文件）。

依据：NATIVE/TOKENS-PIPE/brief-harmony.md §0.5、§3、§4-2、§6（D10-693 九条照推荐：§6-1 A、§6-2 加 colorsDark / shadowsDark、
§6-3 A 组件尺寸只留 DesignTokens.component、§6-4 设备测试按键比对、§6-5 entry base 由生成器出、§6-6 删 CouliShadow.mask / argb、
§6-7 两处副本都删）；gen.py 放宽到 8 位色只认 #RRGGBBAA。

所有令牌只从锁定快照 contracts/snapshot/design/design-tokens.json 这一条链路生成。本检查拿快照当独立判据（不调用生成器），逐叶核对：
  T1  仓库里没有令牌旁路副本：任何位置都没有 design-tokens.v*.json，也没有改了名的令牌 JSON（含 tokens + darkThemePhase 的 .json），
      只许锁定快照本身
  T2  代码 / 脚本 / 配置里不再引用 design-tokens.v*.json（副本不能变成悬空引用；D10-693 ⑦）
  T3  版本与指纹唯一：快照 sha256 / metadata.version 等于钉值（0.5.1 / 97d2bf83…）；DesignTokens.version、CouliThemeTokens.version 等于
      快照版本；两份 Ds02Expected.ets 头注写快照 sha256、不再写 v0.4.0
  T4  gen_theme.py 不再提副本：不含 specs/design-tokens、design-tokens.v、「仍锁 v0.3.0」、版本钉 "0.4.0"
  T5  资源逐项：designsystem base / dark 的每个 color_* = argb(快照 value / dark)，与快照颜色一一对应（不多不少不重名）；
      shadow_card / shadow_floating = 颜色 × 不透明度（两套，且等于 DS-02 起的现值，0 像素变化）；不得有别的资源；
      entry base / dark 的 start_window_background = argb(background.canvas 的 value / dark)
  T6  DesignTokens（node 真执行生成物）：有 colorsDark / shadowsDark；colors / colorsDark 逐键等于快照原串（CSS 顺序、大小写不动，
      双向）；shadows / shadowsDark 逐层六个字段；component（含 1.5）、radius（含 tag / avatar）、spacing、fontSize、lineHeight、
      fontWeight、touchTarget、focus 逐叶
  T7  CouliThemeTokens（同上真执行）：colors 每项 light / dark = argb(快照)；shadows 两套逐层；不再有 component（组件尺寸只一份，§6-3 A）
  T8  designsystem src/main 去掉注释后没有十六进制色字面量（#RRGGBB / #RRGGBBAA / 0xAARRGGBB / rgba(…)），白名单只有生成物
      theme/CouliThemeTokens.ets；CouliMetrics.ets 连注释也不写色值（§1.4）。即：没有手抄深色表、没有手算遮罩色
  T9  CouliShadow.mask / argb（手算遮罩）已删，全仓无引用（§6-6）
  T10 designsystem 不读 CouliThemeTokens.component（§6-3 A：CouliComponentMetrics 与四处 helper 统一读 DesignTokens.component）；
      CouliComponentMetrics 的每个字段都读 DesignTokens（不写死数值）
  T11 designsystem（src/main 与模块根 .ets）不再出现 v0.3.0 / v0.4.0 / 「令牌源副本」的说法
  T12 contract.lock design_tokens.commit 是 f088f04 或其后代（按 verify.sh 的规则找 couli，只读 git）；lock 里快照哈希 = 快照 sha256
  T13 接线：verify.sh 在 gen.py --check 之后、lint.py 之前跑本检查（--self-test 与本仓库）、生成器单测、run-logic、check-arkts；
      两个 Hypium 套件存在并在各自 List.test.ets 注册
  T14 lint.py 的 HM-LINT-11 说明与提示改成「锁定快照」，不再写「令牌源副本」
  T15 Ds02ResourcesDevice 按键比对（不按下标），5 个新键（platform.tag.* ×4、overlay.on-image）按资源名取值

钉值（0.5.1 / f088f04 / 97d2bf83… / 阴影资源现值）：DSX-122 升 v0.6.0 时换值。

用法：
  python3 tools/ci/tokens/check_tokens_pipe.py              本仓库（违反即退出 1）
  python3 tools/ci/tokens/check_tokens_pipe.py --self-test  合成的合规参照件必须全过、每个错误实现必须被对应条目打红（REFERENCE_ONLY，
                                                            不算产品通过）
  python3 tools/ci/tokens/check_tokens_pipe.py --root <目录> 查别的目录（不核 couli 血缘以外的东西照查）
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
EVAL = Path(__file__).with_name('eval-tokens.cjs')

SNAPSHOT = 'contracts/snapshot/design/design-tokens.json'
LOCK = 'contract.lock'
DESIGN_TOKENS = 'common/generated/src/main/ets/DesignTokens.ets'
THEME_TOKENS = 'common/designsystem/src/main/ets/theme/CouliThemeTokens.ets'
DS_MAIN = 'common/designsystem/src/main'
DS_RES = 'common/designsystem/src/main/resources/%s/element/color.json'
ENTRY_RES = 'entry/src/main/resources/%s/element/color.json'
DS02_EXPECTED = ['common/designsystem/src/test/Ds02Expected.ets', 'entry/src/ohosTest/ets/test/Ds02Expected.ets']
GEN_THEME = 'tools/codegen/gen_theme.py'
GEN = 'tools/codegen/gen.py'
LINT = 'tools/ci/lint.py'
VERIFY = 'tools/ci/verify.sh'
METRICS = 'common/designsystem/src/main/ets/CouliMetrics.ets'
DEVICE_TEST = 'entry/src/ohosTest/ets/test/Ds02ResourcesDevice.test.ets'
GEN_SUITE = 'common/generated/src/test/TokensPipe.test.ets'
GEN_LIST = 'common/generated/src/test/List.test.ets'
DS_SUITE = 'common/designsystem/src/test/TokensPipeTheme.test.ets'
DS_LIST = 'common/designsystem/src/test/List.test.ets'
PENDING_KEYS = ['platform.tag.taobao', 'platform.tag.tmall', 'platform.tag.jd', 'platform.tag.pdd', 'overlay.on-image']

# 钉值：DSX-122 升 v0.6.0 时换值（同时换本检查、test_tokens.py 与两份 Hypium 套件里的钉值）。
PINS = {
    'version': '0.5.1',
    'commit': 'f088f0473230d1e70232b8a246b92ef53d723929',
    'sha256': '97d2bf83ada062959987f348bc695c63fabc4adb3647f03e5c0895e2548e491c',
    # DS-02 起的阴影资源现值（浅, 深）；本单主判据「所有像素 0 变化」，生成器改写后这两个资源一个字节都不能变。
    'shadow_res': {'shadow_card': ('#0F28251F', '#4C000000'), 'shadow_floating': ('#1F28251F', '#73000000')},
}
COULI_FIXED = '/Users/zhixing/我的项目/couli'
SKIP_DIRS = {'.git', 'build', 'oh_modules', 'node_modules', '.hvigor', '.preview', '.idea', '__pycache__'}
CODE_EXT = ('.py', '.ets', '.ts', '.cjs', '.js', '.mjs', '.sh', '.json', '.json5')
# 本检查与生成器单测在反例 / 毒化夹具里要写出副本的名字，不算引用。
SELF_FILES = {'tools/ci/tokens/check_tokens_pipe.py', 'tools/codegen/test_tokens.py', 'tools/ci/tokens/mutants.py'}


class Violation(Exception):
    pass


# ---------------------------------------------------------------- 共用工具（test_tokens.py 也用）

def leaves(node, prefix=''):
    """令牌叶子（带 type 的对象），路径用点连接、保留连字符。"""
    for key, value in node.items():
        path = prefix + key
        if isinstance(value, dict) and 'type' in value:
            yield path, value
        elif isinstance(value, dict):
            yield from leaves(value, path + '.')


def argb(css):
    """CSS #RRGGBB / #RRGGBBAA → 鸿蒙 #RRGGBB / #AARRGGBB（大写，只换位一次）。"""
    value = css.upper()
    return '#' + value[7:9] + value[1:7] if len(value) == 9 else value


def resource_name(path):
    return 'color_' + path.replace('.', '_').replace('-', '_')


def shadow_resource(layers):
    """阴影资源 = 第一层颜色 × 不透明度（round(opacity × 255)，与 DS-02 起的生成值同一算法）。"""
    layer = layers[0]
    return '#%02X%s' % (round(float(layer['opacity']) * 255), str(layer['color']).upper()[1:])


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def unwrap(value):
    """eval-tokens.cjs 的输出 → Python：Map → 有序 [(键, 值)]，类实例 → dict（去掉 $class）。"""
    if isinstance(value, dict) and '$map' in value:
        return [(k, unwrap(v)) for k, v in value['$map']]
    if isinstance(value, dict):
        return {k: unwrap(v) for k, v in value.items() if k != '$class'}
    if isinstance(value, list):
        return [unwrap(v) for v in value]
    return value


def eval_class(path, class_name):
    """node 真执行生成的令牌数据文件，返回该类全部静态字段。"""
    result = subprocess.run(['node', str(EVAL), str(path), class_name], capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise Violation('node 执行 %s 失败：%s' % (path, (result.stderr or result.stdout).strip()))
    return {k: unwrap(v) for k, v in json.loads(result.stdout)['fields'].items()}


def strip_comments(text):
    """去掉 // 与 /* */ 注释，字符串（'…' "…" `…`）原样保留。"""
    out = []
    i, n = 0, len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in '\'"`':
            quote = c
            out.append(c)
            i += 1
        elif text.startswith('//', i):
            j = text.find('\n', i)
            i = n if j < 0 else j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            out.append(' ')
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def layer_tuple(layer):
    return tuple((f, layer[f]) for f in ('x', 'y', 'blur', 'spread', 'color', 'opacity'))


def walk_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            yield os.path.relpath(full, root).replace(os.sep, '/'), full


def read(root, rel):
    p = Path(root) / rel
    return p.read_text(encoding='utf-8') if p.is_file() else None


# ---------------------------------------------------------------- couli 血缘（只读 git）

def is_git_repo(path):
    return bool(path) and os.path.isdir(path) and subprocess.run(
        ['git', '-C', path, 'rev-parse', '--git-dir'], capture_output=True).returncode == 0


def resolve_couli(root, rel):
    """与 verify.sh resolve_upstream 同序：COULI_DIR → 仓库根/rel → 主检出/rel → 本机固定位置。"""
    override = os.environ.get('COULI_DIR')
    if override:
        return override if is_git_repo(override) else None
    common = subprocess.run(['git', '-C', str(root), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True)
    main_root = common.stdout.strip()[:-len('/.git')] if common.returncode == 0 and common.stdout.strip().endswith('/.git') else ''
    for cand in [os.path.join(str(root), rel), os.path.join(main_root, rel) if main_root else '', COULI_FIXED]:
        if is_git_repo(cand):
            return os.path.abspath(cand)
    return None


def couli_lineage(root, rel, commit, pinned):
    """返回 None 表示 commit 是 pinned 或其后代；否则返回原因。"""
    couli = resolve_couli(root, rel)
    if couli is None:
        return '取不到 couli 仓库（设 COULI_DIR），无法核对锁定提交是 f088f04 或其后代'
    if subprocess.run(['git', '-C', couli, 'cat-file', '-e', commit + '^{commit}'], capture_output=True).returncode != 0:
        return 'couli（%s）里没有锁定提交 %s' % (couli, commit[:12])
    if subprocess.run(['git', '-C', couli, 'merge-base', '--is-ancestor', pinned, commit], capture_output=True).returncode != 0:
        return '锁定提交 %s 不是 %s 或其后代' % (commit[:12], pinned[:12])
    return None


# ---------------------------------------------------------------- 检查

def check(root, pins=PINS, lineage=couli_lineage):
    root = Path(root)
    v = []

    def bad(code, msg):
        v.append(code + ' ' + msg)

    snap_path = root / SNAPSHOT
    if not snap_path.is_file():
        bad('T3', '缺锁定快照 ' + SNAPSHOT)
        return v
    snap_bytes = snap_path.read_bytes()
    snap = json.loads(snap_bytes.decode('utf-8'))
    snap_sha = sha256(snap_bytes)
    version = snap.get('metadata', {}).get('version')
    tokens = snap['tokens']
    colors = list(leaves(tokens.get('color', {})))
    shadows = list(tokens.get('shadow', {}).items())

    # T1 旁路副本
    for rel, full in walk_files(root):
        name = rel.rsplit('/', 1)[-1]
        if re.fullmatch(r'design-tokens\.v.*\.json', name):
            bad('T1', '令牌旁路副本仍在：' + rel)
        elif rel != SNAPSHOT and name.endswith('.json') and os.path.getsize(full) < 4 * 1024 * 1024:
            try:
                text = Path(full).read_text(encoding='utf-8')
            except (UnicodeDecodeError, OSError):
                continue
            if '"darkThemePhase"' in text and '"tokens"' in text:
                bad('T1', '改名的令牌副本：' + rel + '（只许 ' + SNAPSHOT + '）')

    # T2 悬空引用
    for rel, full in walk_files(root):
        if rel in SELF_FILES or not rel.endswith(CODE_EXT) or rel == SNAPSHOT:
            continue
        try:
            text = Path(full).read_text(encoding='utf-8')
        except (UnicodeDecodeError, OSError):
            continue
        for m in re.finditer(r'design-tokens\.v\d', text):
            line = text.count('\n', 0, m.start()) + 1
            bad('T2', '%s:%d 仍引用令牌旁路副本 design-tokens.v*.json' % (rel, line))
            break

    # T3 版本与指纹
    if snap_sha != pins['sha256']:
        bad('T3', '快照 sha256 %s ≠ 钉值 %s（锁定 f088f04 / v0.5.1；DSX-122 升 v0.6.0 时换值）' % (snap_sha[:12], pins['sha256'][:12]))
    if version != pins['version']:
        bad('T3', '快照 metadata.version %r ≠ %r' % (version, pins['version']))
    design = theme = None
    try:
        design = eval_class(root / DESIGN_TOKENS, 'DesignTokens')
    except Violation as e:
        bad('T6', str(e))
    try:
        theme = eval_class(root / THEME_TOKENS, 'CouliThemeTokens')
    except Violation as e:
        bad('T7', str(e))
    if design is not None and design.get('version') != version:
        bad('T3', 'DesignTokens.version %r ≠ 快照 %r' % (design.get('version'), version))
    if theme is not None and theme.get('version') != version:
        bad('T3', 'CouliThemeTokens.version %r ≠ 快照 %r' % (theme.get('version'), version))
    for rel in DS02_EXPECTED:
        text = read(root, rel)
        if text is None:
            bad('T3', '缺 ' + rel)
            continue
        head = '\n'.join(text.split('\n')[:4])
        if snap_sha not in head:
            bad('T3', rel + ' 头注没写快照 sha256 ' + snap_sha[:12] + '…（ds02 期望须从快照派生）')
        if 'v0.4.0' in head:
            bad('T3', rel + ' 头注仍写 v0.4.0')

    # T4 gen_theme.py
    gt = read(root, GEN_THEME) or ''
    for needle in ('specs/design-tokens', 'design-tokens.v', '仍锁 v0.3.0', '"0.4.0"', "'0.4.0'"):
        if needle in gt:
            bad('T4', GEN_THEME + ' 仍含「' + needle + '」（来源须是锁定快照，不钉版本）')

    # T5 资源
    for mode, field, index in (('base', 'value', 0), ('dark', 'dark', 1)):
        rel = DS_RES % mode
        text = read(root, rel)
        if text is None:
            bad('T5', '缺 ' + rel)
            continue
        rows = json.loads(text).get('color', [])
        names = [r.get('name') for r in rows]
        if len(set(names)) != len(names):
            bad('T5', rel + ' 有重名资源')
        actual = {r.get('name'): str(r.get('value')) for r in rows}
        want = {}
        for key, leaf in colors:
            if field not in leaf:
                bad('T5', '快照 color.%s 缺 %s（不得回落浅色）' % (key, field))
                continue
            want[resource_name(key)] = argb(leaf[field])
        for name, layers_key in (('shadow_card', 'card'), ('shadow_floating', 'floating')):
            leaf = tokens.get('shadow', {}).get(layers_key)
            if leaf is None or not leaf.get('value'):
                bad('T5', '快照缺 shadow.' + layers_key)
                continue
            if field == 'dark' and 'dark' not in leaf:
                bad('T5', '快照 shadow.%s 缺 dark' % layers_key)
                continue
            want[name] = shadow_resource(leaf[field])
            pinned = pins['shadow_res'].get(name)
            if pinned is not None and want[name] != pinned[index]:
                bad('T5', '快照算出的 %s %s 与 DS-02 现值 %s 不同（像素会变，停下报编排）' % (mode, name, pinned[index]))
        for name in sorted(set(want) | set(actual)):
            if name not in actual:
                bad('T5', '%s 缺资源 %s' % (rel, name))
            elif name not in want:
                bad('T5', '%s 有快照之外的资源 %s=%s' % (rel, name, actual[name]))
            elif actual[name].upper() != want[name] or actual[name] != actual[name].upper():
                bad('T5', '%s %s=%s，应为 %s（argb(快照 %s)，八位只换位一次）' % (rel, name, actual[name], want[name], field))
    canvas = dict(colors).get('background.canvas')
    for mode, field in (('base', 'value'), ('dark', 'dark')):
        rel = ENTRY_RES % mode
        text = read(root, rel)
        if text is None or canvas is None or field not in canvas:
            bad('T5', '缺 ' + rel + ' 或快照缺 background.canvas.' + field)
            continue
        rows = json.loads(text).get('color', [])
        if [r.get('name') for r in rows] != ['start_window_background']:
            bad('T5', rel + ' 只应有 start_window_background 一项')
        elif rows[0].get('value') != argb(canvas[field]):
            bad('T5', '%s start_window_background=%s，应为 %s（background.canvas 的 %s）' % (
                rel, rows[0].get('value'), argb(canvas[field]), field))

    # T6 DesignTokens
    if design is not None:
        def table(name):
            value = design.get(name)
            if not isinstance(value, list):
                bad('T6', 'DesignTokens 缺 ' + name)
                return None
            return value

        def compare_map(name, actual, expected):
            if actual is None:
                return
            a, e = dict(actual), dict(expected)
            if len(a) != len(actual):
                bad('T6', 'DesignTokens.%s 有重复键' % name)
            for k in sorted(set(a) | set(e)):
                if k not in a:
                    bad('T6', 'DesignTokens.%s 缺 %s' % (name, k))
                elif k not in e:
                    bad('T6', 'DesignTokens.%s 多出快照没有的 %s' % (name, k))
                elif type(a[k]) is not type(e[k]) and not (isinstance(a[k], (int, float)) and isinstance(e[k], (int, float))):
                    bad('T6', 'DesignTokens.%s[%s] 类型不对：%r ≠ %r' % (name, k, a[k], e[k]))
                elif a[k] != e[k]:
                    bad('T6', 'DesignTokens.%s[%s]=%r ≠ 快照 %r' % (name, k, a[k], e[k]))

        compare_map('colors', table('colors'), [(k, leaf['value']) for k, leaf in colors])
        compare_map('colorsDark', table('colorsDark'), [(k, leaf.get('dark')) for k, leaf in colors])
        for name, node in (('spacing', tokens.get('space', {})), ('radius', tokens.get('radius', {})),
                           ('fontSize', tokens.get('font', {}).get('size', {})),
                           ('lineHeight', tokens.get('font', {}).get('line-height', {})),
                           ('fontWeight', tokens.get('font', {}).get('weight', {})),
                           ('touchTarget', tokens.get('interaction', {}).get('target', {})),
                           ('focus', tokens.get('focus', {}))):
            compare_map(name, table(name), [(k, leaf['value']) for k, leaf in node.items()])
        compare_map('component', table('component'), [(k, leaf['value']) for k, leaf in leaves(tokens.get('component', {}))])
        for name, pick in (('shadows', lambda leaf: leaf['value']), ('shadowsDark', lambda leaf: leaf.get('dark', leaf['value']))):
            actual = table(name)
            if actual is None:
                continue
            a = dict(actual)
            for k in sorted(set(a) | {k for k, _ in shadows}):
                leaf = dict(shadows).get(k)
                if k not in a:
                    bad('T6', 'DesignTokens.%s 缺 %s' % (name, k))
                elif leaf is None:
                    bad('T6', 'DesignTokens.%s 多出 %s' % (name, k))
                elif [layer_tuple(x) for x in a[k]] != [layer_tuple(x) for x in pick(leaf)]:
                    bad('T6', 'DesignTokens.%s[%s] 与快照逐层不等' % (name, k))

    # T7 CouliThemeTokens
    if theme is not None:
        rows = theme.get('colors') or []
        got = {r['key']: r for r in rows}
        if len(got) != len(rows):
            bad('T7', 'CouliThemeTokens.colors 有重复键')
        for k in sorted(set(got) | {k for k, _ in colors}):
            leaf = dict(colors).get(k)
            if k not in got:
                bad('T7', 'CouliThemeTokens.colors 缺 ' + k)
            elif leaf is None:
                bad('T7', 'CouliThemeTokens.colors 多出 ' + k)
            else:
                if got[k]['light'] != argb(leaf['value']):
                    bad('T7', 'CouliThemeTokens %s light=%s ≠ %s' % (k, got[k]['light'], argb(leaf['value'])))
                if 'dark' in leaf and got[k]['dark'] != argb(leaf['dark']):
                    bad('T7', 'CouliThemeTokens %s dark=%s ≠ %s' % (k, got[k]['dark'], argb(leaf['dark'])))
        srows = {r['key']: r for r in theme.get('shadows') or []}
        for k, leaf in shadows:
            r = srows.get(k)
            if r is None:
                bad('T7', 'CouliThemeTokens.shadows 缺 ' + k)
                continue
            if [layer_tuple(x) for x in r['light']] != [layer_tuple(x) for x in leaf['value']]:
                bad('T7', 'CouliThemeTokens.shadows %s light 与快照不等' % k)
            if [layer_tuple(x) for x in r['dark']] != [layer_tuple(x) for x in leaf.get('dark', leaf['value'])]:
                bad('T7', 'CouliThemeTokens.shadows %s dark 与快照不等' % k)
        if set(srows) != {k for k, _ in shadows}:
            bad('T7', 'CouliThemeTokens.shadows 键与快照不等')
        if 'component' in theme:
            bad('T7', 'CouliThemeTokens 仍输出 component（组件尺寸只留 DesignTokens.component 一份，§6-3 A）')

    # T8 / T10 / T11 designsystem 源码
    ds_files = []
    for rel, full in walk_files(root / 'common/designsystem'):
        rel = 'common/designsystem/' + rel
        if rel.endswith('.ets') and (rel.startswith(DS_MAIN + '/') or rel.count('/') == 2):
            ds_files.append(rel)
    for rel in ds_files:
        text = read(root, rel)
        code = strip_comments(text)
        if rel != THEME_TOKENS:
            for pattern, label in ((r'#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?(?![0-9A-Za-z_])', '十六进制色'),
                                   (r'0[xX][0-9A-Fa-f]{8}(?![0-9A-Fa-f])', '0xAARRGGBB 数值色'),
                                   (r'\brgba?\s*\(', 'rgba()')):
                for m in re.finditer(pattern, code):
                    bad('T8', '%s 写死%s「%s」（颜色只从生成物 / 资源取，手抄深色表与手算遮罩都不许）' % (rel, label, m.group(0)))
            if 'CouliThemeTokens.component' in code:
                bad('T10', rel + ' 仍读 CouliThemeTokens.component（统一读 DesignTokens.component，§6-3 A）')
            for needle in ('v0.3.0', 'v0.4.0', '令牌源副本'):
                if needle in text:
                    bad('T11', rel + ' 仍写「' + needle + '」')
        if rel == METRICS:
            body = code.split('class CouliComponentMetrics', 1)[1].split('\n}', 1)[0] if 'class CouliComponentMetrics' in code else ''
            for m in re.finditer(r'static\s+readonly\s+(\w+)\s*:\s*number\s*=([^;]*);', body):
                if 'DesignTokens.' not in m.group(2):
                    bad('T10', METRICS + ' CouliComponentMetrics.%s 不读 DesignTokens（写死或读别的表：%s）' % (m.group(1), m.group(2).strip()[:60]))
            for m in re.finditer(r'#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?(?![0-9A-Za-z_])', text):
                bad('T8', METRICS + ' 注释里写死色值「' + m.group(0) + '」（§1.4：不写色值）')
            if re.search(r'\bstatic\s+(mask|argb)\s*\(', code):
                bad('T9', METRICS + ' 仍有 CouliShadow.mask / argb（手算遮罩，§6-6 删除）')

    # T9 全仓引用
    for top in ('common', 'entry', 'features'):
        for rel, full in walk_files(root / top):
            if not rel.endswith('.ets'):
                continue
            code = strip_comments(Path(full).read_text(encoding='utf-8'))
            if re.search(r'CouliShadow\s*\.\s*(mask|argb)\b', code):
                bad('T9', top + '/' + rel + ' 仍调用 CouliShadow.mask / argb')

    # T12 锁
    lock_text = read(root, LOCK)
    if lock_text is None:
        bad('T12', '缺 ' + LOCK)
    else:
        lock = json.loads(lock_text)
        dt = lock.get('design_tokens', {})
        commit = str(dt.get('commit', ''))
        why = lineage(root, str(dt.get('repo', '../couli')), commit, pins['commit'])
        if why:
            bad('T12', 'contract.lock design_tokens.commit：' + why)
        if lock.get('files', {}).get('design/design-tokens.json') != snap_sha:
            bad('T12', 'contract.lock 里 design/design-tokens.json 的哈希 ≠ 快照 sha256（跑 tools/contracts/sync.sh）')

    # T13 接线
    verify = read(root, VERIFY) or ''
    order = []
    for needle in ('tools/codegen/gen.py" --check', 'tools/ci/tokens/check_tokens_pipe.py" --self-test',
                   'tools/ci/tokens/check_tokens_pipe.py" ||', 'tools/codegen/test_tokens.py"', 'tools/ci/tokens/run-logic.cjs" --self-test',
                   'tools/ci/tokens/run-logic.cjs" ||', 'tools/ci/tokens/check-arkts.cjs" --real', 'tools/ci/lint.py" ||'):
        at = verify.find(needle)
        if at < 0:
            bad('T13', VERIFY + ' 缺一步：' + needle)
        order.append(at)
    found = [x for x in order if x >= 0]
    if len(found) == len(order) and not (order[0] < min(order[1:-1]) and max(order[1:-1]) < order[-1]):
        bad('T13', VERIFY + '：令牌管线各步须在 gen.py --check 之后、lint.py 之前')
    for suite, lst, call in ((GEN_SUITE, GEN_LIST, 'tokensPipeTest'), (DS_SUITE, DS_LIST, 'tokensPipeThemeTest')):
        if read(root, suite) is None:
            bad('T13', '缺 Hypium 套件 ' + suite)
        if not re.search(r'^\s*' + call + r'\(\);', strip_comments(read(root, lst) or ''), flags=re.M):
            bad('T13', lst + ' 没注册 ' + call + '()')

    # T14 lint 文案
    lint = read(root, LINT) or ''
    seg = lint[lint.find('HM-LINT-11'):] if 'HM-LINT-11' in lint else ''
    if '令牌源副本' in lint:
        bad('T14', LINT + ' HM-LINT-11 仍写「令牌源副本」')
    if '锁定快照' not in seg:
        bad('T14', LINT + ' HM-LINT-11 说明 / 提示没改成「锁定快照」')

    # T15 设备测试按键比对
    dev = read(root, DEVICE_TEST)
    if dev is None:
        bad('T15', '缺 ' + DEVICE_TEST)
    else:
        code = strip_comments(dev)
        if re.search(r'values\s*\[\s*index\s*\]', code) or re.search(r'expect\(\s*values\.length\s*\)', code):
            bad('T15', DEVICE_TEST + ' 仍按下标比对（#24 / D10-693 ④：改按键比对）')
        for key in PENDING_KEYS:
            if "'" + key + "'" not in code:
                bad('T15', DEVICE_TEST + ' 没覆盖新键 ' + key + '（按资源名取值）')
        if 'couliColorResourceName(' not in code or 'couliColorResource(' not in code:
            bad('T15', DEVICE_TEST + ' 新键须经 couliColorResource(couliColorResourceName(key)) 取产品资源')
    return v


# ---------------------------------------------------------------- 自测：合成的合规参照件 + 错误实现

def _snapshot_fixture():
    def c(value, dark):
        return {'type': 'color', 'value': value, 'dark': dark}

    def d(value, kind='dimension'):
        return {'type': kind, 'value': value}

    return {
        'metadata': {'name': '凑狸', 'version': '9.9.9', 'modes': ['light', 'dark'], 'darkThemePhase': 'MVP'},
        'tokens': {
            'color': {'text': {'primary': c('#28251F', '#F2EEE6')},
                      'background': {'canvas': c('#F2EEE6', '#171513')},
                      'overlay': {'scrim': c('#28251F66', '#0000008C'), 'on-image': c('#0000008C', '#0000008C')}},
            'font': {'size': {'body': d(17, 'fontSize')}, 'line-height': {'body': d(25.5, 'lineHeight')},
                     'weight': {'bold': d(700, 'fontWeight')}},
            'space': {'0': d(0), '4': d(16)},
            'radius': {'tag': d(4), 'card': d(16)},
            'shadow': {'none': {'type': 'shadow', 'value': []},
                       'card': {'type': 'shadow', 'value': [{'x': 0, 'y': 2, 'blur': 8, 'spread': 0, 'color': '#28251F', 'opacity': 0.06}],
                                'dark': [{'x': 0, 'y': 2, 'blur': 8, 'spread': 0, 'color': '#000000', 'opacity': 0.3}]},
                       'floating': {'type': 'shadow',
                                    'value': [{'x': 0, 'y': 8, 'blur': 24, 'spread': 0, 'color': '#28251F', 'opacity': 0.12}],
                                    'dark': [{'x': 0, 'y': 8, 'blur': 24, 'spread': 0, 'color': '#000000', 'opacity': 0.45}]}},
            'focus': {'width': d(2), 'offset': d(2)},
            'interaction': {'target': {'harmony': d(48)}},
            'component': {'checkbox': {'size': d(18), 'max-scale': d(1.5, 'number')}},
        },
    }


def _num(v):
    return str(int(v)) if float(v).is_integer() else repr(v)


def _layers(cls, layers):
    return '[' + ', '.join('new %s(%s, %s, %s, %s, %s, %s)' % (cls, _num(l['x']), _num(l['y']), _num(l['blur']), _num(l['spread']),
                                                              json.dumps(l['color']), _num(l['opacity'])) for l in layers) + ']'


def _design_tokens_ets(snap):
    t = snap['tokens']
    out = ['export class ShadowLayerToken {', '  readonly x: number; readonly y: number; readonly blur: number; readonly spread: number;',
           '  readonly color: string; readonly opacity: number;',
           '  constructor(x: number, y: number, blur: number, spread: number, color: string, opacity: number) {',
           '    this.x = x; this.y = y; this.blur = blur; this.spread = spread; this.color = color; this.opacity = opacity;', '  }', '}',
           'export class DesignTokens {', '  static readonly version: string = %s;' % json.dumps(snap['metadata']['version'])]

    def table(name, typ, pairs):
        out.append('  static readonly %s: Map<string, %s> = new Map<string, %s>([%s]);' % (
            name, typ, typ, ', '.join('[%s, %s]' % (json.dumps(k), v) for k, v in pairs)))

    cs = list(leaves(t['color']))
    table('colors', 'string', [(k, json.dumps(l['value'])) for k, l in cs])
    table('colorsDark', 'string', [(k, json.dumps(l['dark'])) for k, l in cs])
    for name, node in (('spacing', t['space']), ('radius', t['radius']), ('fontSize', t['font']['size']),
                       ('lineHeight', t['font']['line-height']), ('fontWeight', t['font']['weight']),
                       ('touchTarget', t['interaction']['target']), ('focus', t['focus'])):
        table(name, 'number', [(k, _num(l['value'])) for k, l in node.items()])
    table('component', 'number', [(k, _num(l['value'])) for k, l in leaves(t['component'])])
    table('shadows', 'ShadowLayerToken[]', [(k, _layers('ShadowLayerToken', l['value'])) for k, l in t['shadow'].items()])
    table('shadowsDark', 'ShadowLayerToken[]', [(k, _layers('ShadowLayerToken', l.get('dark', l['value']))) for k, l in t['shadow'].items()])
    out.append('}')
    return '\n'.join(out) + '\n'


def _theme_tokens_ets(snap, header='// 生成物，禁止手改；来源 contracts/snapshot/design/design-tokens.json（gen.py 生成）'):
    t = snap['tokens']
    out = [header,
           'export class ThemeShadowLayer {', '  readonly x: number; readonly y: number; readonly blur: number; readonly spread: number;',
           '  readonly color: string; readonly opacity: number;',
           '  constructor(x: number, y: number, blur: number, spread: number, color: string, opacity: number) {',
           '    this.x = x; this.y = y; this.blur = blur; this.spread = spread; this.color = color; this.opacity = opacity;', '  }', '}',
           'export class ThemeColorToken {', '  readonly key: string; readonly light: string; readonly dark: string;',
           '  constructor(key: string, light: string, dark: string) { this.key = key; this.light = light; this.dark = dark; }', '}',
           'export class ThemeShadowToken {', '  readonly key: string; readonly light: ThemeShadowLayer[]; readonly dark: ThemeShadowLayer[];',
           '  constructor(key: string, light: ThemeShadowLayer[], dark: ThemeShadowLayer[]) {',
           '    this.key = key; this.light = light; this.dark = dark;', '  }', '}',
           'export class CouliThemeTokens {', '  static readonly version: string = %s;' % json.dumps(snap['metadata']['version']),
           '  static readonly colors: ThemeColorToken[] = [']
    for k, l in leaves(t['color']):
        out.append('    new ThemeColorToken(%s, %s, %s),' % (json.dumps(k), json.dumps(argb(l['value'])), json.dumps(argb(l['dark']))))
    out.append('  ];')
    out.append('  static readonly shadows: ThemeShadowToken[] = [')
    for k, l in t['shadow'].items():
        out.append('    new ThemeShadowToken(%s, %s, %s),' % (json.dumps(k), _layers('ThemeShadowLayer', l['value']),
                                                            _layers('ThemeShadowLayer', l.get('dark', l['value']))))
    out += ['  ];', '}']
    return '\n'.join(out) + '\n'


def _color_json(rows):
    return json.dumps({'color': [{'name': n, 'value': v} for n, v in rows]}, indent=2, ensure_ascii=False) + '\n'


GOOD_VERIFY = '''step "gen.py --check"
python3 "$ROOT/tools/codegen/gen.py" --check || fail_fast "gen.py --check" "x"
step "令牌管线"
python3 "$ROOT/tools/ci/tokens/check_tokens_pipe.py" --self-test || fail_fast "a" "b"
python3 "$ROOT/tools/ci/tokens/check_tokens_pipe.py" || fail_fast "a" "b"
python3 "$ROOT/tools/codegen/test_tokens.py" || fail_fast "a" "b"
node "$ROOT/tools/ci/tokens/run-logic.cjs" --self-test || fail_fast "a" "b"
node "$ROOT/tools/ci/tokens/run-logic.cjs" || fail_fast "a" "b"
node "$ROOT/tools/ci/tokens/check-arkts.cjs" --real || fail_fast "a" "b"
step "lint.py（项目规则）"
python3 "$ROOT/tools/ci/lint.py" || fail_fast "lint.py" "见上方输出"
'''

GOOD_DEVICE = '''import { CouliColors, couliColorResource, couliColorResourceName } from 'designsystem';
const PENDING: string[] = ['platform.tag.taobao', 'platform.tag.tmall', 'platform.tag.jd', 'platform.tag.pdd', 'overlay.on-image'];
export function pending(): ResourceColor[] {
  return PENDING.map((key: string) => couliColorResource(couliColorResourceName(key)) as ResourceColor);
}
export function byKey(values: Map<string, ResourceColor>, key: string): ResourceColor | undefined { return values.get(key); }
'''

GOOD_METRICS = '''import { DesignTokens } from 'generated';
/** 焦点环取 focus.ring 的浅 / 深两套值（来自锁定快照生成物），不在注释里写色值。 */
export class CouliComponentMetrics {
  static readonly checkboxMaxScale: number = DesignTokens.component.get('checkbox.max-scale') ?? 0;
}
export class CouliShadow {
  static readonly card: number = 1;
}
'''


def build_fixture(root):
    root = Path(root)
    snap = _snapshot_fixture()
    raw = json.dumps(snap, ensure_ascii=False, indent=2).encode('utf-8')
    sha = sha256(raw)
    files = {
        SNAPSHOT: raw.decode('utf-8'),
        LOCK: json.dumps({'design_tokens': {'repo': '../couli', 'commit': 'c' * 40, 'path': 'design/tokens/design-tokens.json'},
                          'files': {'design/design-tokens.json': sha}}, indent=2) + '\n',
        DESIGN_TOKENS: _design_tokens_ets(snap),
        THEME_TOKENS: _theme_tokens_ets(snap),
        GEN_THEME: '"""主题生成器：来源 contracts/snapshot/design/design-tokens.json（锁定快照）。"""\nimport json\n',
        GEN: 'import gen_theme\n',
        'tools/codegen/ds02_test_data.py': 'SOURCE = "contracts/snapshot/design/design-tokens.json"\n',
        LINT: '    HM-LINT-11 theme-drift  与锁定快照不一致（gen_theme.py --check）\n',
        VERIFY: GOOD_VERIFY,
        METRICS: GOOD_METRICS,
        'common/designsystem/src/main/ets/components/Controls.ets':
            "import { DesignTokens } from 'generated';\n// 底 #E9E2D9（注释里的色值不算）\n"
            "function c(key: string): number { return DesignTokens.component.get(key) ?? 0; }\n"
            "const url: string = 'https://example.invalid/#anchor';\n",
        'common/designsystem/Index.ets': "// DS：浅 / 深两套主题（锁定快照生成）\nexport { CouliShadow } from './src/main/ets/CouliMetrics';\n",
        GEN_SUITE: 'export default function tokensPipeTest() {}\n',
        GEN_LIST: "import tokensPipeTest from './TokensPipe.test';\nexport default function testsuite() {\n  tokensPipeTest();\n}\n",
        DS_SUITE: 'export default function tokensPipeThemeTest() {}\n',
        DS_LIST: "import tokensPipeThemeTest from './TokensPipeTheme.test';\nexport default function testsuite() {\n  tokensPipeThemeTest();\n}\n",
        DEVICE_TEST: GOOD_DEVICE,
        'entry/src/main/ets/Page.ets': "import { CouliShadow } from 'designsystem';\nconst s: number = CouliShadow.card;\n",
    }
    cs = list(leaves(snap['tokens']['color']))
    sh = snap['tokens']['shadow']
    for mode, field in (('base', 'value'), ('dark', 'dark')):
        rows = [(resource_name(k), argb(l[field])) for k, l in cs]
        rows += [('shadow_card', shadow_resource(sh['card'][field])), ('shadow_floating', shadow_resource(sh['floating'][field]))]
        files[DS_RES % mode] = _color_json(rows)
        files[ENTRY_RES % mode] = _color_json([('start_window_background', argb(snap['tokens']['color']['background']['canvas'][field]))])
    for rel in DS02_EXPECTED:
        files[rel] = '// 生成物，禁止手改；tools/codegen/gen.py；仅测试数据。\n// 快照 SHA256: %s\nexport const X: number = 1;\n' % sha
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding='utf-8')
    pins = {'version': '9.9.9', 'commit': 'c' * 40, 'sha256': sha,
            'shadow_res': {'shadow_card': ('#0F28251F', '#4C000000'), 'shadow_floating': ('#1F28251F', '#73000000')}}
    return pins


def _replace(rel, old, new):
    def apply(root):
        p = Path(root) / rel
        text = p.read_text(encoding='utf-8')
        if old not in text:
            raise AssertionError('变异原文不在夹具里：%s %r' % (rel, old))
        p.write_text(text.replace(old, new, 1), encoding='utf-8')
    return apply


def _write(rel, text):
    def apply(root):
        p = Path(root) / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding='utf-8')
    return apply


def _delete(rel):
    return lambda root: (Path(root) / rel).unlink()


def _json_edit(rel, fn):
    def apply(root):
        p = Path(root) / rel
        data = json.loads(p.read_text(encoding='utf-8'))
        fn(data)
        p.write_text(_color_json([(r['name'], r['value']) for r in data['color']]), encoding='utf-8')
    return apply


def _set_row(name, value):
    def fn(data):
        hit = [r for r in data['color'] if r['name'] == name]
        assert hit, name
        hit[0]['value'] = value
    return fn


MUTANTS = [
    ('specs 副本还在', 'T1', _write('specs/design-tokens.v0.4.0.json', '{"metadata": {"version": "0.4.0"}}')),
    ('ds02 夹具副本还在', 'T1', _write('tools/ci/ds02/fixtures/design-tokens.v0.4.0.json', '{}')),
    ('改名副本', 'T1', _write('tools/ci/ds02/fixtures/palette.json', '{"metadata": {"darkThemePhase": "MVP"}, "tokens": {}}')),
    ('ds02_test_data 仍读夹具副本', 'T2', _write('tools/codegen/ds02_test_data.py', 'SOURCE = "fixtures/design-tokens.v0.4.0.json"\n')),
    ('test_host 悬空引用', 'T2', _write('tools/ci/ds02/test_host.py', "FIX = 'design-tokens.v0.4.0.json'\n")),
    ('DesignTokens 版本不一致', 'T3', _replace(DESIGN_TOKENS, '"9.9.9"', '"0.3.0"')),
    ('CouliThemeTokens 版本不一致', 'T3', _replace(THEME_TOKENS, '"9.9.9"', '"0.4.0"')),
    ('Ds02Expected 头注仍是副本 sha', 'T3', _replace(DS02_EXPECTED[1], '// 快照 SHA256: ', '// v0.4.0 原件 SHA256: 11539dc0')),
    ('gen_theme 仍读 specs 副本', 'T4', _write(GEN_THEME, 'SOURCE = os.path.join("specs", "design-tokens.v0.4.0.json")\n')),
    ('gen_theme 头注仍说仍锁 v0.3.0', 'T4', _write(GEN_THEME, '"""contract.lock 仍锁 v0.3.0"""\n')),
    ('gen_theme 钉 0.4.0', 'T4', _write(GEN_THEME, 'if version != "0.4.0": raise\n')),
    ('资源仍是 RGBA（没换位）', 'T5', _json_edit(DS_RES % 'base', _set_row('color_overlay_scrim', '#28251F66'))),
    ('深色资源回落浅色', 'T5', _json_edit(DS_RES % 'dark', _set_row('color_text_primary', '#28251F'))),
    ('深色资源少一项', 'T5', _json_edit(DS_RES % 'dark', lambda d: d['color'].pop(0))),
    ('资源多一项', 'T5', _json_edit(DS_RES % 'base', lambda d: d['color'].append({'name': 'color_extra', 'value': '#000000'}))),
    ('手算深色遮罩阴影', 'T5', _json_edit(DS_RES % 'dark', _set_row('shadow_card', '#66000000'))),
    ('entry base 仍手写且与令牌不同', 'T5', _json_edit(ENTRY_RES % 'base', _set_row('start_window_background', '#F2EEE7'))),
    ('entry dark 取了浅色', 'T5', _json_edit(ENTRY_RES % 'dark', _set_row('start_window_background', '#F2EEE6'))),
    ('DesignTokens 存成 ARGB', 'T6', _replace(DESIGN_TOKENS, '["overlay.scrim", "#28251F66"]', '["overlay.scrim", "#6628251F"]')),
    ('DesignTokens 改了大小写', 'T6', _replace(DESIGN_TOKENS, '["text.primary", "#28251F"]', '["text.primary", "#28251f"]')),
    ('没有 colorsDark', 'T6', _replace(DESIGN_TOKENS, 'static readonly colorsDark', 'static readonly colorsNight')),
    ('colorsDark 回落浅色', 'T6', _replace(DESIGN_TOKENS, '["background.canvas", "#171513"]', '["background.canvas", "#F2EEE6"]')),
    ('shadowsDark 缺键', 'T6', _replace(
        DESIGN_TOKENS, 'static readonly shadowsDark: Map<string, ShadowLayerToken[]> = new Map<string, ShadowLayerToken[]>([["none", []], ',
        'static readonly shadowsDark: Map<string, ShadowLayerToken[]> = new Map<string, ShadowLayerToken[]>([')),
    ('shadowsDark 取了浅色', 'T6', _replace(DESIGN_TOKENS, '"#000000", 0.3)', '"#28251F", 0.06)')),
    ('component 被 int() 截断', 'T6', _replace(DESIGN_TOKENS, '["checkbox.max-scale", 1.5]',
                                            '["checkbox.max-scale", 1]')),
    ('radius 少 tag', 'T6', _replace(DESIGN_TOKENS, '["tag", 4], ', '')),
    ('CouliThemeTokens 仍有 component', 'T7', _replace(THEME_TOKENS, '  static readonly colors',
                                                     '  static readonly component: Map<string, number> = new Map<string, number>();\n'
                                                     '  static readonly colors')),
    ('CouliThemeTokens 深色没换位', 'T7', _replace(THEME_TOKENS, '"#6628251F", "#8C000000"', '"#6628251F", "#0000008C"')),
    ('CouliThemeTokens 换位两次', 'T7', _replace(THEME_TOKENS, '"#6628251F", "#8C000000"', '"#1F662825", "#8C000000"')),
    ('手抄深色表', 'T8', _write('common/designsystem/src/main/ets/theme/DarkTable.ets',
                              "export const DARK: Map<string, string> = new Map([['text.primary', '#F2EEE6']]);\n")),
    ('手算遮罩色', 'T8', _write('common/designsystem/src/main/ets/components/Mask.ets',
                             "export const MASK: number = 0x6628251F;\n")),
    ('rgba 遮罩', 'T8', _write('common/designsystem/src/main/ets/components/Mask.ets', "export const MASK: string = 'rgba(40, 37, 31, 0.4)';\n")),
    ('CouliMetrics 注释写死色值', 'T8', _replace(METRICS, '不在注释里写色值', '浅 #26735B、深 #5DBB97')),
    ('CouliShadow.mask 还在', 'T9', _replace(METRICS, '  static readonly card: number = 1;',
                                            '  static readonly card: number = 1;\n  static mask(baseHex: string): string { return baseHex; }')),
    ('页面调用 CouliShadow.mask', 'T9', _replace('entry/src/main/ets/Page.ets', 'CouliShadow.card', "CouliShadow.mask('x').length")),
    ('CouliComponentMetrics 读旧表', 'T10', _replace(METRICS, 'DesignTokens.component.get', 'CouliThemeTokens.component.get')),
    ('CouliComponentMetrics 写死数值', 'T10', _replace(METRICS, "DesignTokens.component.get('checkbox.max-scale') ?? 0", '1.5')),
    ('helper 读旧表', 'T10', _replace('common/designsystem/src/main/ets/components/Controls.ets', 'DesignTokens.component',
                                     'CouliThemeTokens.component')),
    ('注释仍写 v0.4.0', 'T11', _replace('common/designsystem/Index.ets', '锁定快照生成', '令牌 v0.4.0 生成数据')),
    ('锁不是 f088f04 后代', 'T12', None),
    ('lock 哈希未刷新', 'T12', _replace(LOCK, '"design/design-tokens.json": "', '"design/design-tokens.json": "0')),
    ('verify 没挂本检查', 'T13', _replace(VERIFY, 'python3 "$ROOT/tools/ci/tokens/check_tokens_pipe.py" ||', '# removed ||')),
    ('verify 顺序错（令牌步在 lint 之后）', 'T13', _write(VERIFY, GOOD_VERIFY.split('step "令牌管线"')[0] + GOOD_VERIFY.split('step "lint.py（项目规则）"')[1]
                                                   + 'step "令牌管线"' + GOOD_VERIFY.split('step "令牌管线"')[1].split('step "lint.py')[0])),
    ('designsystem 套件未注册', 'T13', _replace(DS_LIST, '  tokensPipeThemeTest();\n', '  // tokensPipeThemeTest();\n')),
    ('generated 套件缺失', 'T13', _delete(GEN_SUITE)),
    ('lint 文案仍写令牌源副本', 'T14', _write(LINT, '    HM-LINT-11 theme-drift  与令牌源副本 specs 不一致\n')),
    ('设备测试按下标', 'T15', _write(DEVICE_TEST, GOOD_DEVICE + 'function f(values: number[], index: number): number { return values[index]; }\n')),
    ('设备测试漏新键', 'T15', _replace(DEVICE_TEST, "'overlay.on-image'", "'overlay.scrim'")),
]


def self_test():
    failures = []
    tmp = tempfile.mkdtemp(prefix='tokens-pipe-selftest-')
    try:
        good = os.path.join(tmp, 'good')
        pins = build_fixture(good)
        ok_lineage = lambda root, rel, commit, pinned: None
        v = check(good, pins, ok_lineage)
        if v:
            failures.append('合规参照件不应有违反：\n  ' + '\n  '.join(v))
        print('REFERENCE_ONLY 合规参照件：违反 %d' % len(v))
        for i, (name, code, apply) in enumerate(MUTANTS):
            d = os.path.join(tmp, 'm%d' % i)
            shutil.copytree(good, d)
            lineage = ok_lineage
            try:
                if apply is None:
                    lineage = lambda root, rel, commit, pinned: '锁定提交不是 f088f04 或其后代（合成）'
                else:
                    apply(d)
            except AssertionError as e:
                failures.append('变异体「%s」没套上：%s' % (name, e))
                continue
            mv = check(d, pins, lineage)
            codes = {x.split(' ', 1)[0] for x in mv}
            if code not in codes:
                failures.append('变异体「%s」没被 %s 打红（实际 %s）' % (name, code, sorted(codes) or '全绿'))
            else:
                print('REFERENCE_ONLY 变异体被杀 %-28s %s：%s' % (name, code, next(x for x in mv if x.startswith(code + ' '))[:110]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if failures:
        print('check_tokens_pipe.py --self-test 失败：', file=sys.stderr)
        for f in failures:
            print('  ' + f, file=sys.stderr)
        return 1
    print('check_tokens_pipe.py --self-test：合规参照件全过，%d 个错误实现全部打红（REFERENCE_ONLY，不算产品通过）' % len(MUTANTS))
    return 0


def main(argv):
    args = argv[1:]
    if args == ['--self-test']:
        return self_test()
    root = ROOT
    if args[:1] == ['--root'] and len(args) == 2:
        root = Path(args[1]).resolve()
    elif args:
        print('用法：check_tokens_pipe.py [--self-test | --root <目录>]', file=sys.stderr)
        return 2
    v = check(root)
    for x in v:
        print(x)
    if v:
        print('check_tokens_pipe.py：%d 处违反（令牌须只从锁定快照一条链路生成）' % len(v), file=sys.stderr)
        return 1
    print('check_tokens_pipe.py：0 处违反（%s，快照 v%s）' % (root, PINS['version']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
