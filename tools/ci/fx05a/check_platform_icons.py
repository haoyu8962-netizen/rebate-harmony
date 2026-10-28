#!/usr/bin/env python3
"""F-X-05a（平台内置图标入包）鸿蒙宿主检查。产品缺件就是红，不 skip；无网络、无三方依赖。

用法：
  check_platform_icons.py                       检查本仓库：V3 资源 / 清单 / README，资源层不反色（V6），
                                                源码守卫（V2 图标读屏隐藏、V6 不着色、缺图不画占位、V5 两档同一入口），
                                                接线（商品卡 / 订单 / 剪贴板传平台编码），F-DS-01 登录钮仍挂起，设备用例名单
  check_platform_icons.py --hap R.hap [--base-hap B.hap]
                                                V7：Release 包内平台图字节 = 源文件、无 dark 替身、无清单 / README 混入；
                                                给了底包就打印资源增量 FX05A_RESOURCE_DELTA
  check_platform_icons.py --self-test           在临时目录造一份合规参照件，再逐个注入错误实现，证明每条检查都会打红
退出码：0 通过；1 有违反；2 用法或环境错误（找不到 couli 仓库等）。

约定（交回 tests-harmony-handback.md §3 写明）：
  资源：common/designsystem/src/main/resources/base/media/{taobao,jd,pinduoduo}.png，逐字节 = couli design/icons/platform/ 原图；
  清单：common/designsystem/platform-icons/manifest.json（机器读），说明：common/designsystem/platform-icons/README.md（人读）；
        两者不在 resources/ 下，不进包。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[3]
FIX = Path(__file__).with_name('fixtures')
SOURCES = json.loads((FIX / 'platform-sources.json').read_text(encoding='utf-8'))
OFFICIAL = {name: row['sha256'] for name, row in SOURCES['files'].items()}
REQUIRED = SOURCES['required_builtin']  # 标识键 → 源文件名（pdd → pinduoduo.png）
MISSING_KEYS = SOURCES['missing_keys']
DS = 'common/designsystem'
MEDIA = DS + '/src/main/resources/base/media'
MANIFEST = DS + '/platform-icons/manifest.json'
README = DS + '/platform-icons/README.md'
# 资源名里出现这些词的媒体文件都算「平台图」，必须登记在清单里（暂缺平台不得有占位文件）。
PLATFORM_WORDS = ['taobao', 'tmall', 'jd', 'pinduoduo', 'pdd', 'wechat', 'alipay', 'wecom', 'vip', 'douyin', 'meituan',
                  'eleme', 'fliggy', 'didi', 'platform']
COULI_BRAND = re.compile(r'couli|logo|startIcon|foreground|background|layered', re.I)


def couli_dir():
    for candidate in [os.environ.get('COULI_DIR'), str(ROOT.parent / 'couli'), '/Users/zhixing/我的项目/couli']:
        if candidate and (Path(candidate) / '.git').exists():
            return Path(candidate)
    return None


def git_blob(couli, commit, path):
    try:
        return subprocess.run(['git', '-C', str(couli), 'show', commit + ':' + path], check=True,
                              capture_output=True).stdout
    except subprocess.CalledProcessError:
        return None


def png_size(data):
    if data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
        return None
    return struct.unpack('>II', data[16:24])


# ---------------------------------------------------------------- 源码词法（去注释、保留字符串）

def strip_comments(code):
    out = []
    i, n = 0, len(code)
    while i < n:
        c = code[i]
        if c in '\'"`':
            j = i + 1
            while j < n and code[j] != c:
                j += 2 if code[j] == '\\' else 1
            out.append(code[i:j + 1])
            i = j + 1
        elif code.startswith('//', i):
            j = code.find('\n', i)
            i = n if j < 0 else j
        elif code.startswith('/*', i):
            j = code.find('*/', i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def matching(code, start, open_char, close_char):
    """code[start] == open_char；返回配对的 close_char 下标（跳过字符串）。"""
    depth = 0
    i, n = start, len(code)
    while i < n:
        c = code[i]
        if c in '\'"`':
            j = i + 1
            while j < n and code[j] != c:
                j += 2 if code[j] == '\\' else 1
            i = j + 1
            continue
        if c == open_char:
            depth += 1
        elif c == close_char:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def struct_body(code, name):
    m = re.search(r'\bstruct\s+' + re.escape(name) + r'\s*\{', code)
    if not m:
        return None
    start = m.end() - 1
    end = matching(code, start, '{', '}')
    return code[start:end + 1] if end > 0 else None


def calls(code, callee):
    """返回 callee(...) 的全部「调用 + 链式属性」文本。"""
    found = []
    for m in re.finditer(r'(?<![\w.])' + re.escape(callee) + r'\s*\(', code):
        end = matching(code, m.end() - 1, '(', ')')
        if end < 0:
            continue
        i = end + 1
        while True:
            k = i
            while k < len(code) and code[k] in ' \t\r\n':
                k += 1
            if k < len(code) and code[k] == '.':
                mm = re.match(r'\.\s*\w+\s*\(', code[k:])
                if not mm:
                    break
                close = matching(code, k + mm.end() - 1, '(', ')')
                if close < 0:
                    break
                i = close + 1
            else:
                break
        found.append(code[m.start():i])
    return found


def read(root, rel):
    p = root / rel
    return strip_comments(p.read_text(encoding='utf-8')) if p.is_file() else None


# ---------------------------------------------------------------- V3：资源、清单、README

def check_assets(root, couli):
    errors = []
    media = root / MEDIA
    manifest_path = root / MANIFEST
    if not manifest_path.is_file():
        return ['A1 缺清单 ' + MANIFEST]
    try:
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    except ValueError as error:
        return ['A1 清单不是合法 JSON：' + str(error)]
    for key in ['schema_version', 'source_repo', 'source_dir', 'source_commit', 'files', 'missing']:
        if key not in manifest:
            errors.append('A1 清单缺字段 ' + key)
    if errors:
        return errors
    if manifest['schema_version'] != 1 or manifest['source_repo'] != 'couli' or \
            manifest['source_dir'] != 'design/icons/platform/':
        errors.append('A1 清单来源字段不对')
    commit = manifest['source_commit']
    if not re.fullmatch(r'[0-9a-f]{40}', str(commit)):
        errors.append('A1 source_commit 必须是 40 位提交号')
    if sorted(manifest['missing']) != sorted(MISSING_KEYS):
        errors.append('A1 missing 应列出暂缺平台 ' + ','.join(MISSING_KEYS))
    entries = manifest['files']
    identity = {}
    keys = {}
    for row in entries:
        for key in ['resource', 'media_name', 'platform_key', 'source_file', 'source_sha256', 'sha256', 'bytes', 'width',
                    'height', 'transform']:
            if key not in row:
                errors.append('A1 清单行缺字段 ' + key + '：' + json.dumps(row, ensure_ascii=False))
        if any(key not in row for key in ['resource', 'source_file', 'sha256', 'transform']):
            continue
        source_file = row['source_file']
        if source_file not in OFFICIAL or COULI_BRAND.search(row['resource']):
            errors.append('A7 清单里有非官方平台素材（凑狸品牌或来历不明）：' + row['resource'])
            continue
        if row.get('source_sha256') != OFFICIAL[source_file]:
            errors.append('A2 source_sha256 与 couli 原图不符：' + source_file)
        rel = row['resource']
        if not re.fullmatch(r'base/media/[a-z0-9_]+\.png', rel) or '..' in rel:
            errors.append('A2 资源路径不合规（只许 base/media/<名>.png，深色不另放）：' + rel)
            continue
        path = root / DS / 'src/main/resources' / rel
        if not path.is_file():
            errors.append('A2 清单登记的资源不存在：' + rel)
            continue
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest != row['sha256']:
            errors.append('A2 资源实际摘要与清单不符（被改动 / 重新压缩）：' + rel)
        size = png_size(data)
        if size is None or [row.get('width'), row.get('height')] != list(size) or row.get('bytes') != len(data):
            errors.append('A2 尺寸 / 字节数与清单不符：' + rel)
        if row['transform'] == 'identity':
            if digest != OFFICIAL[source_file] or size != (224, 224):
                errors.append('A2 identity 资源必须逐字节等于 couli 原图（224×224）：' + rel)
            identity[source_file] = row
            if row.get('media_name') != Path(rel).stem:
                errors.append('A2 media_name 与文件名不一致：' + rel)
            keys[row.get('platform_key')] = source_file
        elif row['transform'] == 'downscale':
            original = SOURCES['files'][source_file]
            if size is None or not (size[0] < original['width'] and size[1] < original['height']) or \
                    size[0] * original['height'] != size[1] * original['width'] or not row.get('rule') or \
                    row.get('derived_from') is None:
                errors.append('A2 派生图只许等比例严格缩小，且写明 rule / derived_from：' + rel)
        else:
            errors.append('A2 不认识的 transform（只许 identity / downscale）：' + rel)
    for row in entries:
        if row.get('transform') == 'downscale' and row.get('derived_from') not in [r['resource'] for r in identity.values()]:
            errors.append('A2 派生图的原件必须同时入包：' + str(row.get('resource')))
    if keys != REQUIRED:
        errors.append('A3 标识键 → 源文件应为 ' + json.dumps(REQUIRED) + '，实际 ' + json.dumps(keys))
    # 平台目录不混入凑狸品牌、暂缺平台不放占位：media 里所有「像平台图」的文件都要在清单里。
    listed = {(root / DS / 'src/main/resources' / row['resource']).resolve() for row in entries if 'resource' in row}
    resources = root / DS / 'src/main/resources'
    for p in sorted(resources.rglob('*')) if resources.is_dir() else []:
        if not p.is_file() or 'media' not in p.parts:
            continue
        stem = p.stem.lower()
        is_platform = any(word in re.split(r'[_\-.]', stem) or stem.startswith(word + '_') for word in PLATFORM_WORDS)
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
        if p.parent.name == 'media' and p.parent.parent.name != 'base' and (is_platform or digest in OFFICIAL.values()):
            errors.append('A6 平台图不得有深色 / 限定词替身（图标原样、不反色）：' + str(p.relative_to(root)))
        elif (is_platform or digest in OFFICIAL.values()) and p.resolve() not in listed:
            errors.append('A5 未登记的平台图或暂缺平台占位：' + str(p.relative_to(root)))
    # 全仓其他模块也不许私带平台图副本（同一张图只在 designsystem 一处）。
    for p in sorted(root.glob('**/resources/**/media/*')):
        if p.is_file() and DS not in str(p.relative_to(root)) and 'ohosTest' not in p.parts:
            if hashlib.sha256(p.read_bytes()).hexdigest() in OFFICIAL.values():
                errors.append('A5 平台图副本放在 designsystem 以外：' + str(p.relative_to(root)))
    # README：来源 commit、每张图的 sha256、暂缺平台、不改像素的规则。
    readme = root / README
    if not readme.is_file():
        errors.append('A4 缺资源说明 ' + README)
    else:
        text = readme.read_text(encoding='utf-8')
        if str(commit) not in text:
            errors.append('A4 README 未写来源 commit')
        for row in entries:
            if row.get('sha256') and row['sha256'] not in text:
                errors.append('A4 README 未写 sha256：' + str(row.get('resource')))
        for key in MISSING_KEYS:
            if key not in text:
                errors.append('A4 README 未列暂缺平台 ' + key)
    # 来源提交真实存在、其中的文件就是这些字节。
    if couli is None:
        errors.append('A8 找不到 couli 仓库（设 COULI_DIR），无法核对 source_commit')
    elif re.fullmatch(r'[0-9a-f]{40}', str(commit)):
        for row in entries:
            if row.get('source_file') in OFFICIAL:
                blob = git_blob(couli, commit, 'design/icons/platform/' + row['source_file'])
                if blob is None or hashlib.sha256(blob).hexdigest() != OFFICIAL[row['source_file']]:
                    errors.append('A8 source_commit 里没有这张原图或字节不同：' + row['source_file'])
    return errors


# ---------------------------------------------------------------- 源码守卫（V2 / V5 / V6 / V1 缺图）

TINT = re.compile(r'\.(fillColor|colorFilter|renderMode|foregroundColor|blendMode|invert|grayscale|brightness|contrast|'
                  r'saturate|sepia|hueRotate)\s*\(|ImageRenderMode\.Template')
PLACEHOLDER = re.compile(r'(?<![\w.])(Rect|Shape|Circle|Ellipse|Path|Polygon|CouliIcon|SymbolGlyph|ImagePlaceholder)\s*\(')


def find_struct(root, name):
    for p in sorted((root / DS / 'src/main/ets').rglob('*.ets')):
        code = strip_comments(p.read_text(encoding='utf-8'))
        body = struct_body(code, name)
        if body is not None:
            return p, body
    return None, None


def params(body):
    return set(re.findall(r'@Param\s+(\w+)\s*:', body))


def method_body(code, name):
    m = re.search(r'\bstatic\s+' + re.escape(name) + r'\s*\([^)]*\)\s*(:\s*\w+\s*)?\{', code)
    if not m:
        return None
    end = matching(code, m.end() - 1, '{', '}')
    return code[m.end() - 1:end + 1] if end > 0 else None


def source_mapping(cls):
    """从 PlatformIconSource 源码解析「编码 → 资源名」。认两种写法：mediaName 里的 switch（case 可连写，接 return 字面量），
    或类里的 Map 字面量 [['键', '名'], …]。返回 (映射, default 返回值)；解析不出返回 (None, None)。"""
    body = method_body(cls, 'mediaName')
    if body is None:
        return None, None
    mapping, pending, fallback = {}, [], None
    token = re.compile(r"""\bcase\s*(['"])(.*?)\1\s*:|\bdefault\s*:|\breturn\s*(['"])(.*?)\3""")
    for m in token.finditer(body):
        if m.group(0).startswith('case'):
            pending.append(m.group(2))
        elif m.group(0).startswith('default'):
            pending.append(None)
        else:
            for key in pending:
                if key is None:
                    fallback = m.group(4)
                else:
                    mapping.setdefault(key, m.group(4))
            pending = []
    if not mapping:
        pairs = re.findall(r"""\[\s*(['"])(.*?)\1\s*,\s*(['"])(.*?)\3\s*\]""", cls)
        mapping = {k: v for _, k, _, v in pairs}
        fallback = ''
    return (mapping or None), fallback


def check_mapping(root):
    """S4（v2）：源码里的编码映射本身必须是 BR-TEXT-24 表（pdd → pinduoduo），不只核清单；builtin / hasBuiltin 由 mediaName 派生。"""
    errors = []
    path = root / DS / 'src/main/ets/components/PlatformIconSource.ets'
    code = read(root, DS + '/src/main/ets/components/PlatformIconSource.ets')
    if code is None:
        return ['S4 缺 ' + str(path.relative_to(root))]
    m = re.search(r'\bclass\s+PlatformIconSource\s*\{', code)
    end = matching(code, m.end() - 1, '{', '}') if m else -1
    if end < 0:
        return ['S4 PlatformIconSource.ets 里找不到 class PlatformIconSource']
    cls = code[m.end() - 1:end + 1]
    mapping, fallback = source_mapping(cls)
    expected = {key: Path(name).stem for key, name in REQUIRED.items()}
    if mapping is None:
        errors.append('S4 无法从 PlatformIconSource.mediaName 解析编码映射（只认 switch-case 或 Map 字面量），按红处理')
    else:
        if mapping != expected:
            errors.append('S4 源码编码映射应为 ' + json.dumps(expected) + '，实际 ' + json.dumps(mapping, ensure_ascii=False))
        if fallback not in ('', None):
            errors.append('S4 未知编码必须返回空串（文字兜底），实际 default 返回 ' + json.dumps(fallback, ensure_ascii=False))
    for name in ['builtin', 'hasBuiltin']:
        body = method_body(cls, name)
        if body is None or 'mediaName(' not in body:
            errors.append('S4 PlatformIconSource.' + name + ' 必须由 mediaName 派生（编码映射只有一处）')
    return errors


def check_source(root):
    errors = check_mapping(root)
    index = read(root, DS + '/Index.ets') or ''
    logic = read(root, DS + '/Logic.ets') or ''
    for name in ['PlatformIcon', 'PlatformIconSize', 'PlatformIconSource', 'PlatformBadge']:
        if not re.search(r'\bexport\s*\{[^}]*\b' + name + r'\b[^}]*\}', index):
            errors.append('S1 designsystem/Index.ets 未导出 ' + name)
    for name in ['PlatformIconSize', 'PlatformIconSource']:
        if not re.search(r'\bexport\s*\{[^}]*\b' + name + r'\b[^}]*\}', logic):
            errors.append('S1 designsystem/Logic.ets 未导出 ' + name + '（APP-11v 与本机单测走无资源入口）')
    _, icon = find_struct(root, 'PlatformIcon')
    if icon is None:
        errors.append('S2 缺组件 struct PlatformIcon')
    else:
        missing = {'platform', 'iconSize', 'remoteUrl'} - params(icon)
        if missing:
            errors.append('S2 PlatformIcon 缺 @Param ' + ','.join(sorted(missing)))
        if 'PlatformIconSource.' not in icon:
            errors.append('S2 PlatformIcon 必须经 PlatformIconSource 取图（编码映射只有一处）')
        images = calls(icon, 'Image')
        if len(images) != 1:
            errors.append('S2 PlatformIcon 应恰有一个 Image，实际 ' + str(len(images)))
        for chain in images:
            if not re.search(r"\.accessibilityLevel\(\s*'no(-hide-descendants)?'\s*\)", chain):
                errors.append('S2 PlatformIcon 的 Image 没有对读屏隐藏（accessibilityLevel no）')
            if TINT.search(chain) or 'CouliColors' in chain:
                errors.append('S2 PlatformIcon 的 Image 被着色 / 滤色 / 反色（官方图必须原样）')
            if not re.search(r'\.width\(\s*this\.iconSize\b', chain) or not re.search(r'\.height\(\s*this\.iconSize\b', chain):
                errors.append('S2 PlatformIcon 的 Image 宽高必须是 this.iconSize（14 / 44 同一张图）')
        if PLACEHOLDER.search(icon):
            errors.append('S2 PlatformIcon 里出现形状 / 占位绘制（缺图不画占位方块）')
    _, badge = find_struct(root, 'PlatformBadge')
    if badge is None:
        errors.append('S3 缺组件 struct PlatformBadge')
    else:
        missing = {'label', 'platform', 'remoteUrl'} - params(badge)
        if missing:
            errors.append('S3 PlatformBadge 缺 @Param ' + ','.join(sorted(missing)))
        uses = calls(badge, 'PlatformIcon')
        if not uses or not all('PlatformIconSize.BADGE' in use for use in uses):
            errors.append('S3 PlatformBadge 的图标必须是 PlatformIcon（PlatformIconSize.BADGE），与 44 档同一入口')
        if calls(badge, 'Image'):
            errors.append('S3 PlatformBadge 不得自己另画 Image（绕过 PlatformIcon）')
        if PLACEHOLDER.search(badge):
            errors.append('S3 PlatformBadge 里出现形状 / 占位绘制（暂缺平台只显示文字）')
        if not re.search(r'\.accessibilityGroup\(\s*true\s*\)', badge):
            errors.append('S3 PlatformBadge 整体必须成组（accessibilityGroup(true)），读屏只读平台名一次')
        if TINT.search(badge):
            errors.append('S3 PlatformBadge 有着色 / 滤色调用，图标不得反色')
    for rel in [DS + '/src/main/resources/dark/element/color.json', DS + '/src/main/resources/base/element/color.json']:
        pass  # 令牌由 DS-02 的 HM-LINT-11 与 Ds02ResourcesDevice 守，这里不重复。
    return errors


# ---------------------------------------------------------------- 接线（V1 在真实页面生效）与 F-DS-01

PRODUCT_DIRS = ['common', 'features', 'entry/src/main', 'entry/src/staging']


def product_files(root):
    for top in PRODUCT_DIRS:
        base = root / top
        if not base.exists():
            continue
        for p in sorted(base.rglob('*.ets')):
            parts = p.relative_to(root).parts
            if 'test' in parts or 'ohosTest' in parts or 'build' in parts or 'oh_modules' in parts:
                continue
            yield p


def check_wiring(root):
    errors = []
    sites = 0
    for p in product_files(root):
        code = strip_comments(p.read_text(encoding='utf-8'))
        rel = str(p.relative_to(root))
        for call in calls(code, 'PlatformBadge'):
            if call.startswith('PlatformBadge') and re.match(r'PlatformBadge\s*\(\s*\{', call):
                sites += 1
                if not re.search(r'\bplatform\s*:', call):
                    errors.append('W1 PlatformBadge 调用没传平台编码 platform：' + rel)
                elif re.search(r"\bplatform\s*:\s*''", call):
                    errors.append('W1 PlatformBadge 的 platform 写死空串：' + rel)
        for call in calls(code, 'ClipboardPromptBar'):
            if re.search(r'\bbadge\s*:', call) and not re.search(r'\bbadgePlatform\s*:', call):
                errors.append('W2 ClipboardPromptBar 传了 badge 却没传 badgePlatform：' + rel)
    if sites == 0:
        errors.append('W1 没找到任何 PlatformBadge 调用（检查器失效）')
    card = read(root, DS + '/src/main/ets/components/ProductCard.ets') or ''
    if not re.search(r'\bplatformCode\s*:\s*string\s*=', card):
        errors.append('W3 ProductCardData 缺 platformCode: string 字段')
    mapper = read(root, DS + '/src/main/ets/format/ProductCardMapper.ets') or ''
    if not re.search(r'\.platformCode\s*=', mapper):
        errors.append('W3 ProductCardMapper 没写 platformCode')
    _, prompt = find_struct(root, 'ClipboardPromptBar')
    if prompt is None or 'badgePlatform' not in params(prompt):
        errors.append('W2 ClipboardPromptBar 缺 @Param badgePlatform')
    orders = read(root, 'features/orders/src/main/ets/OrderViewKit.ets') or ''
    if not re.search(r'\bplatformCode\s*:\s*string', orders):
        errors.append('W4 订单视图模型缺 platformCode（订单列表 / 详情徽标要按编码取图）')
    errors += check_clipboard_badge(root)
    # F-DS-01：登录钮没有微信 / 华为官方图，继续挂起；购物平台图不能被挪去当登录图标。
    login = read(root, DS + '/src/main/ets/components/Login.ets') or ''
    if re.search(r"PlatformIcon|platformMedia|app\.media\.|'(taobao|jd|pinduoduo|pdd)'", login):
        errors.append('L1 登录组件引用了平台购物图（F-DS-01 应继续挂起，等微信 / 华为官方图）')
    return errors


CLIP_DIR = 'entry/src/main/ets/clipboard'
CORE_CLIPBOARD = 'common/core/src/main/ets/clipboard/Clipboard.ets'
CORE_BADGE_ICON = 'common/core/src/main/ets/clipboard/ClipboardBadgeIcon.ets'


def check_clipboard_badge(root):
    """W5（v3，评审 r1 R1-01）：剪贴板提示条徽标的图标键不能直接用识别平台。核心白名单（K01，三端逐字一致）把 tmall.com 识别成
    platform='taobao'、显示名「天猫」，直接拿 platform 取图就是「淘宝图 + 天猫」。要求：
      - 核心白名单 tmall.com 项原样（不靠改三端白名单修）；
      - 派生入口 ClipboardBadgeIcon.of(info)（core 剪贴板目录，core/Index 导出；纯逻辑可在 core Hypium 里测）存在，源码里有 tmall 键
        （BR-TEXT-24 单列、暂缺），按 tmall.com 主机或显示名「天猫」派生，不出现资源名 pinduoduo / *.png（编码 → 资源名只在 PlatformIconSource）；
      - AppClipboard 给 promptBadgePlatform 赋非空值时只能经 ClipboardBadgeIcon.of，不得是 info.platform 之类的原值。
    取值是否正确由纯逻辑 run-clipboard.cjs 与设备用例判定，这里守「派生规则在接线处真的生效」。"""
    errors = []
    core = read(root, CORE_CLIPBOARD) or ''
    if not re.search(r"new\s+ClipboardHostRule\(\s*'tmall\.com'\s*,\s*'taobao'\s*,\s*'天猫'\s*\)", core):
        errors.append('W5 核心白名单 tmall.com 项被改动（K01 三端逐字一致，应为 tmall.com → taobao / 天猫，图标键在鸿蒙接线处派生）')
    source = read(root, CORE_BADGE_ICON)
    index = read(root, 'common/core/Index.ets') or ''
    if source is None:
        errors.append('W5 缺 ' + CORE_BADGE_ICON + '（剪贴板徽标图标键派生入口）')
    elif not re.search(r"\bexport\s*\{[^}]*\bClipboardBadgeIcon\b[^}]*\}\s*from\s*'\./src/main/ets/clipboard/ClipboardBadgeIcon'", index):
        errors.append('W5 core/Index.ets 未导出 ClipboardBadgeIcon')
    else:
        m = re.search(r'\bexport\s+class\s+ClipboardBadgeIcon\s*\{', source)
        end = matching(source, m.end() - 1, '{', '}') if m else -1
        cls = source[m.end() - 1:end + 1] if end > 0 else ''
        body = method_body(cls, 'of') if end > 0 else None
        if body is None:
            errors.append('W5 ClipboardBadgeIcon 缺 static of(info: ClipboardPromptInfo): string')
        else:
            if not re.search(r"""['"]tmall['"]""", cls):
                errors.append('W5 ClipboardBadgeIcon 没有 tmall 图标键（天猫要单列为 tmall，暂缺官方图只显示文字）')
            if not re.search(r"""['"](天猫|tmall\.com)['"]""", cls) or not re.search(r'\.(displayName|display)\b', cls):
                errors.append('W5 ClipboardBadgeIcon.of 没按 tmall.com 主机或显示名「天猫」派生')
            if re.search(r"""['"]pinduoduo['"]|['"]\w+\.png['"]""", source):
                errors.append('W5 ClipboardBadgeIcon 里出现资源名（编码 → 资源名只在 PlatformIconSource 一处）')
    app = read(root, CLIP_DIR + '/AppClipboard.ets')
    if app is None:
        errors.append('W5 缺 ' + CLIP_DIR + '/AppClipboard.ets（检查器失效）')
    else:
        assigns = re.findall(r'\.promptBadgePlatform\s*=\s*([^;\n]+)', app)
        derived = [a for a in assigns if a.strip() not in ("''", '""')]
        if not derived:
            errors.append('W5 AppClipboard 没有给 promptBadgePlatform 赋派生值（检查器失效或接线丢失）')
        for value in derived:
            if not re.match(r'ClipboardBadgeIcon\.of\(', value.strip()):
                errors.append('W5 AppClipboard 的 promptBadgePlatform 必须取 ClipboardBadgeIcon.of(info)，实际 = ' + value.strip())
    return errors


def check_device_list(root):
    errors = []
    listed = [line.strip() for line in (root / 'tools/ci/fx05a/fixtures/device-cases.txt').read_text().splitlines()
              if line.strip() and not line.startswith('#')]
    test = (root / 'entry/src/ohosTest/ets/test/Fx05aUi.test.ets').read_text(encoding='utf-8')
    exported = re.findall(r"'(fx05a_[a-z0-9_]+)'", test.split('FX05A_DEVICE_CASES', 1)[1]) if 'FX05A_DEVICE_CASES' in test else []
    if listed != exported or len(set(listed)) != len(listed):
        errors.append('T1 device-cases.txt 与 Fx05aUi.test.ets 的 FX05A_DEVICE_CASES 不一致')
    for name in listed:
        if "'" + name + "'" not in test.split('FX05A_DEVICE_CASES', 1)[0] and not (
                name.startswith('fx05a_v6_badge_tokens_and_icon_not_inverted_') and
                "'fx05a_v6_badge_tokens_and_icon_not_inverted_'" in test):
            errors.append('T1 名单里的用例在测试文件里没有注册：' + name)
    lst = (root / 'entry/src/ohosTest/ets/test/List.test.ets').read_text(encoding='utf-8')
    if 'fx05aUiTest();' not in lst:
        errors.append('T1 entry List.test.ets 没调用 fx05aUiTest()')
    unit = (root / DS / 'src/test/List.test.ets').read_text(encoding='utf-8') if (root / DS / 'src/test/List.test.ets').is_file() else ''
    for name in ['fx05aPlatformIconTest();', 'fx05aWiringTest();']:
        if name not in unit:
            errors.append('T1 designsystem List.test.ets 没调用 ' + name)
    return errors


def check_repo(root, couli, with_tests=True):
    errors = check_assets(root, couli) + check_source(root) + check_wiring(root)
    if with_tests:
        errors += check_device_list(root)
    return errors


# ---------------------------------------------------------------- V7：Release 包

def check_hap(root, hap, base_hap=None):
    errors = []
    if not (root / MANIFEST).is_file():
        return ['V7 缺清单 ' + MANIFEST + '，无法核对包内平台图']
    manifest = json.loads((root / MANIFEST).read_text(encoding='utf-8'))
    if not manifest.get('files'):
        errors.append('V7 清单没有登记任何平台图')
    with zipfile.ZipFile(hap) as z:
        names = z.namelist()
        for row in manifest['files']:
            entry = 'resources/' + row['resource']
            if entry not in names:
                errors.append('V7 包内缺 ' + entry)
            elif hashlib.sha256(z.read(entry)).hexdigest() != row['sha256']:
                errors.append('V7 包内字节与源文件不同（构建重新压缩？）：' + entry)
        for name in names:
            lower = name.lower()
            if 'platform-icons' in lower or 'platform_icons' in lower or lower.endswith('readme.md'):
                errors.append('V7 清单 / README 混进了包：' + name)
            if name.startswith('resources/') and '/media/' in name and not name.startswith('resources/base/'):
                stem = Path(name).stem.lower()
                if any(word in re.split(r'[_\-.]', stem) for word in PLATFORM_WORDS) or \
                        hashlib.sha256(z.read(name)).hexdigest() in OFFICIAL.values():
                    errors.append('V7 包内有平台图的限定词替身（深色反色？）：' + name)
        platform_bytes = sum(z.getinfo('resources/' + row['resource']).file_size for row in manifest['files']
                             if 'resources/' + row['resource'] in names)
        media_bytes = sum(z.getinfo(n).file_size for n in names if n.startswith('resources/'))
    print('FX05A_HAP platform_png_bytes=' + str(platform_bytes) + ' resources_bytes=' + str(media_bytes) +
          ' hap_bytes=' + str(Path(hap).stat().st_size))
    if base_hap:
        with zipfile.ZipFile(base_hap) as z:
            base_media = sum(z.getinfo(n).file_size for n in z.namelist() if n.startswith('resources/'))
        print('FX05A_RESOURCE_DELTA resources_bytes=' + str(media_bytes - base_media) +
              ' hap_bytes=' + str(Path(hap).stat().st_size - Path(base_hap).stat().st_size))
    return errors


# ---------------------------------------------------------------- 自测：合规参照件 + 错误实现

REF_ICON_SOURCE = """export enum PlatformIconSize { BADGE = 14, GRID = 44 }
export class PlatformIconSource {
  static mediaName(platform: string): string {
    switch (platform) { case 'taobao': return 'taobao'; case 'jd': return 'jd'; case 'pdd': return 'pinduoduo'; default: return ''; }
  }
  static builtin(platform: string): string { const m: string = PlatformIconSource.mediaName(platform); return m.length > 0 ? m + '.png' : ''; }
  static hasBuiltin(platform: string): boolean { return PlatformIconSource.mediaName(platform).length > 0; }
}
"""

REF_BASICS = """import { PlatformIconSource, PlatformIconSize } from './PlatformIconSource';
function platformMedia(name: string): Resource { return $r('app.media.' + name); }
@ComponentV2
export struct PlatformIcon {
  @Param platform: string = '';
  @Param iconSize: PlatformIconSize = PlatformIconSize.BADGE;
  /** F-X-05 预留：本任务一律内置图。 */
  @Param remoteUrl: string = '';
  build() {
    if (PlatformIconSource.hasBuiltin(this.platform)) {
      Image(platformMedia(PlatformIconSource.mediaName(this.platform)))
        .width(this.iconSize)
        .height(this.iconSize)
        .objectFit(ImageFit.Contain)
        .accessibilityLevel('no')
    }
  }
}
@ComponentV2
export struct PlatformBadge {
  @Param label: string = '';
  @Param platform: string = '';
  @Param remoteUrl: string = '';
  build() {
    Row({ space: CouliSpacing.space1 }) {
      if (PlatformIconSource.hasBuiltin(this.platform)) {
        PlatformIcon({ platform: this.platform, iconSize: PlatformIconSize.BADGE, remoteUrl: this.remoteUrl })
      }
      Text(this.label).accessibilityLevel('no')
    }
    .padding({ left: PlatformIconSource.hasBuiltin(this.platform) ? 4 : 8, right: 8 })
    .backgroundColor(CouliColors.sourceBackground)
    .border({ width: 1, color: CouliColors.sourceBorder })
    .accessibilityGroup(true)
    .accessibilityText(this.label)
  }
}
"""


def recompress(data):
    """同像素、不同字节：解出 IDAT 再用另一个压缩级别写回（模拟构建 / 工具重新压缩）。"""
    out = [data[:8]]
    pos = 8
    idat = b''
    chunks = []
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        chunks.append((kind, body))
        if kind == b'IDAT':
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    written = False
    for kind, body in chunks:
        if kind == b'IDAT':
            if written:
                continue
            body = zlib.compress(raw, 1)
            written = True
        out.append(struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff))
    return b''.join(out)


def build_reference(root, couli):
    commit = SOURCES['added_in_commit']
    media = root / MEDIA
    media.mkdir(parents=True)
    (root / DS / 'src/main/resources/dark/media').mkdir(parents=True)
    (root / DS / 'src/main/resources/base/media/couli_logo_mark.svg').write_text('<svg/>')
    rows = []
    for key, source_file in REQUIRED.items():
        data = git_blob(couli, commit, 'design/icons/platform/' + source_file)
        (media / source_file).write_bytes(data)
        rows.append({'resource': 'base/media/' + source_file, 'media_name': Path(source_file).stem, 'platform_key': key,
                     'source_file': source_file, 'source_sha256': OFFICIAL[source_file], 'sha256': OFFICIAL[source_file],
                     'bytes': len(data), 'width': 224, 'height': 224, 'transform': 'identity'})
    manifest = {'schema_version': 1, 'source_repo': 'couli', 'source_dir': 'design/icons/platform/', 'source_commit': commit,
                'files': rows, 'missing': MISSING_KEYS}
    (root / MANIFEST).parent.mkdir(parents=True)
    (root / MANIFEST).write_text(json.dumps(manifest, indent=2))
    (root / README).write_text('来源 couli ' + commit + '\n' + '\n'.join(r['source_file'] + ' ' + r['sha256'] for r in rows) +
                               '\n暂缺：' + ' '.join(MISSING_KEYS) + '\n')
    comp = root / DS / 'src/main/ets/components'
    comp.mkdir(parents=True)
    (comp / 'PlatformIconSource.ets').write_text(REF_ICON_SOURCE)
    (comp / 'Basics.ets').write_text(REF_BASICS)
    (comp / 'ProductCard.ets').write_text("export class ProductCardData { platformLabel: string = ''; platformCode: string = ''; }\n"
                                          "@ComponentV2 struct T { build() { PlatformBadge({ label: this.data.platformLabel, platform: this.data.platformCode }) } }\n")
    (comp / 'Clipboard.ets').write_text("@ComponentV2 export struct ClipboardPromptBar { @Param badge: string = ''; @Param badgePlatform: string = '';\n"
                                        "build() { PlatformBadge({ label: this.badge, platform: this.badgePlatform }) } }\n")
    (comp / 'Login.ets').write_text("@ComponentV2 export struct OAuthButton { @Param placeholderText: string = ''; build() { Text(this.placeholderText) } }\n")
    (root / DS / 'src/main/ets/format').mkdir(parents=True)
    (root / DS / 'src/main/ets/format/ProductCardMapper.ets').write_text("d.platformCode = platform;\n")
    (root / DS / 'Index.ets').write_text("export { PlatformBadge, PlatformIcon } from './src/main/ets/components/Basics';\n"
                                         "export { PlatformIconSource, PlatformIconSize } from './src/main/ets/components/PlatformIconSource';\n")
    (root / DS / 'Logic.ets').write_text("export { PlatformIconSource, PlatformIconSize } from './src/main/ets/components/PlatformIconSource';\n")
    orders = root / 'features/orders/src/main/ets'
    orders.mkdir(parents=True)
    (orders / 'OrderViewKit.ets').write_text("export class OrderCardView { readonly platformName: string; readonly platformCode: string; }\n")
    (orders / 'OrderListView.ets').write_text("// PlatformBadge({ label: x })  注释里的旧写法不算\n"
                                              "@ComponentV2 struct L { build() { PlatformBadge({ label: view.platformName, platform: view.platformCode }) } }\n")
    clip = root / 'entry/src/main/ets/clipboard'
    clip.mkdir(parents=True)
    (clip / 'AppClipboard.ets').write_text("m.promptBadgePlatform = '';\nm.promptBadgePlatform = ClipboardBadgeIcon.of(info);\n")
    core = root / 'common/core/src/main/ets/clipboard'
    core.mkdir(parents=True)
    (core / 'ClipboardBadgeIcon.ets').write_text(
        "import { ClipboardPromptInfo } from './Clipboard';\n"
        "export class ClipboardBadgeIcon {\n"
        "  static of(info: ClipboardPromptInfo): string {\n"
        "    return info.displayName === '天猫' ? 'tmall' : info.platform;\n  }\n}\n")
    (root / 'common/core/Index.ets').write_text("export { ClipboardBadgeIcon } from './src/main/ets/clipboard/ClipboardBadgeIcon';\n")
    (core / 'Clipboard.ets').write_text("const H = [new ClipboardHostRule('taobao.com', 'taobao', '淘宝'),\n"
                                        "  new ClipboardHostRule('tmall.com', 'taobao', '天猫')];\n")
    (clip / 'ClipboardViews.ets').write_text("@ComponentV2 struct V { build() { ClipboardPromptBar({ text: 't', badge: m.promptBadge, badgePlatform: m.promptPlatform }) } }\n")


def edit(root, rel, old, new):
    p = root / rel
    text = p.read_text()
    assert old in text, (rel, old)
    p.write_text(text.replace(old, new, 1))


CLIP = 'entry/src/main/ets/clipboard'


def mutations():
    basics = DS + '/src/main/ets/components/Basics.ets'
    return [
        ('M1 图标读屏未隐藏', 'S2', lambda r: edit(r, basics, "        .accessibilityLevel('no')\n    }\n  }\n}", "\n    }\n  }\n}")),
        ('M2a 缺图平台画占位方块（组件）', 'S3', lambda r: edit(r, basics, "      Text(this.label)",
                                                     "      if (!PlatformIconSource.hasBuiltin(this.platform)) { Rect().width(14).height(14) }\n      Text(this.label)")),
        ('M2b 缺图平台放占位图（资源 tmall.png）', 'A5', lambda r: shutil.copy(r / MEDIA / 'jd.png', r / MEDIA / 'tmall.png')),
        ('M3 pdd 映射错（清单把 pinduoduo 当标识键）', 'A3', lambda r: edit(r, MANIFEST, '"platform_key": "pdd"', '"platform_key": "pinduoduo"')),
        ('M3b pdd 映射错（源码把 pinduoduo 当键，v2）', 'S4', lambda r: edit(r, DS + '/src/main/ets/components/PlatformIconSource.ets',
                                                              "case 'pdd': return 'pinduoduo';", "case 'pinduoduo': return 'pinduoduo';")),
        ('M3c pdd 映射错（源码 pdd → taobao，v2）', 'S4', lambda r: edit(r, DS + '/src/main/ets/components/PlatformIconSource.ets',
                                                           "case 'pdd': return 'pinduoduo';", "case 'pdd': return 'taobao';")),
        ('M3d builtin 自带一张表、不走 mediaName（v2）', 'S4', lambda r: edit(r, DS + '/src/main/ets/components/PlatformIconSource.ets',
            "const m: string = PlatformIconSource.mediaName(platform);", "const m: string = platform === 'pinduoduo' ? 'pinduoduo' : '';")),
        ('M4a 深色反色（Image 加 colorFilter）', 'S2', lambda r: edit(r, basics, "        .objectFit(ImageFit.Contain)",
                                                          "        .objectFit(ImageFit.Contain)\n        .colorFilter(INVERT)")),
        ('M4b 深色反色（dark/media 放替身）', 'A6', lambda r: shutil.copy(r / MEDIA / 'taobao.png',
                                                                 r / DS / 'src/main/resources/dark/media/taobao.png')),
        ('M5 资源被重新压缩', 'A2', lambda r: (r / MEDIA / 'taobao.png').write_bytes(recompress((r / MEDIA / 'taobao.png').read_bytes()))),
        ('M5b 重新压缩后连清单摘要一起改', 'A2', lambda r: (
            (r / MEDIA / 'jd.png').write_bytes(recompress((r / MEDIA / 'jd.png').read_bytes())),
            edit(r, MANIFEST, '"sha256": "' + OFFICIAL['jd.png'] + '"', '"sha256": "' + hashlib.sha256((r / MEDIA / 'jd.png').read_bytes()).hexdigest() + '"'))),
        ('M6 商品卡徽标没传编码', 'W1', lambda r: edit(r, DS + '/src/main/ets/components/ProductCard.ets', ', platform: this.data.platformCode', '')),
        ('M7 凑狸品牌图混进平台清单', 'A7', lambda r: edit(r, MANIFEST, '"files": [', '"files": [{"resource": "base/media/couli_logo_mark.svg", "media_name": "couli_logo_mark", "platform_key": "couli", "source_file": "couli_logo_mark.svg", "source_sha256": "x", "sha256": "x", "bytes": 6, "width": 0, "height": 0, "transform": "identity"},')),
        ('M8 README 缺 sha256', 'A4', lambda r: (r / README).write_text('来源 couli ' + SOURCES['added_in_commit'] + '\n暂缺 ' + ' '.join(MISSING_KEYS))),
        ('M9 14 档自己画 Image、不走 PlatformIcon', 'S3', lambda r: edit(r, basics,
            "        PlatformIcon({ platform: this.platform, iconSize: PlatformIconSize.BADGE, remoteUrl: this.remoteUrl })",
            "        Image(platformMedia(PlatformIconSource.mediaName(this.platform))).width(12).height(12).accessibilityLevel('no')")),
        ('M11 剪贴板徽标直接用识别平台取图（r1 R1-01 的写法，v3）', 'W5', lambda r: edit(r, CLIP + '/AppClipboard.ets',
            'ClipboardBadgeIcon.of(info)', 'info.platform')),
        ('M11b 派生入口没有 tmall 键（天猫仍回 taobao，v3）', 'W5', lambda r: edit(r, CORE_BADGE_ICON,
            "info.displayName === '天猫' ? 'tmall' : info.platform", 'info.platform')),
        ('M11c 改三端白名单 tmall.com → tmall 来修（v3）', 'W5', lambda r: edit(r, 'common/core/src/main/ets/clipboard/Clipboard.ets',
            "'tmall.com', 'taobao', '天猫'", "'tmall.com', 'tmall', '天猫'")),
        ('M11d 派生入口缺失（v3）', 'W5', lambda r: (r / CORE_BADGE_ICON).unlink()),
        ('M11e core/Index 没导出派生入口（v3）', 'W5', lambda r: (r / 'common/core/Index.ets').write_text('')),
        ('M10 登录钮挪用购物平台图', 'L1', lambda r: edit(r, DS + '/src/main/ets/components/Login.ets', 'Text(this.placeholderText)',
                                                      "PlatformIcon({ platform: 'taobao' })")),
    ]


def self_test(couli):
    if couli is None:
        print('自测需要 couli 仓库（设 COULI_DIR）', file=sys.stderr)
        return 2
    failures = []
    with tempfile.TemporaryDirectory(prefix='fx05a-host-') as tmp:
        base = Path(tmp) / 'ref'
        build_reference(base, couli)
        errors = check_repo(base, couli, with_tests=False)
        if errors:
            print('参照件本应全过：\n  ' + '\n  '.join(errors))
            return 1
        print('REFERENCE_ONLY 合规参照件：资源 / 清单 / 源码 / 接线检查全过')
        hap = Path(tmp) / 'ref.hap'
        with zipfile.ZipFile(hap, 'w') as z:
            for name in REQUIRED.values():
                z.write(base / MEDIA / name, 'resources/base/media/' + name)
        hap_errors = check_hap(base, hap)
        if hap_errors:
            failures.append('参照 HAP 本应通过：' + '; '.join(hap_errors))
        bad_hap = Path(tmp) / 'bad.hap'
        with zipfile.ZipFile(bad_hap, 'w') as z:
            z.writestr('resources/base/media/taobao.png', recompress((base / MEDIA / 'taobao.png').read_bytes()))
            z.write(base / MEDIA / 'jd.png', 'resources/base/media/jd.png')
            z.write(base / MEDIA / 'jd.png', 'resources/dark/media/jd.png')
            z.write(base / README, 'resources/rawfile/platform-icons/README.md')
        bad = check_hap(base, bad_hap)
        for code in ['重新压缩', '缺 resources/base/media/pinduoduo.png', '替身', 'README']:
            if not any(code in e for e in bad):
                failures.append('V7 坏包没被拦住：' + code)
        print('REFERENCE_ONLY V7 坏包：' + ' | '.join(bad))
        for name, code, mutate in mutations():
            root = Path(tmp) / ('m' + str(abs(hash(name))))
            shutil.copytree(base, root)
            mutate(root)
            errors = check_repo(root, couli, with_tests=False)
            hit = [e for e in errors if e.startswith(code)]
            if hit:
                print('KILLED ' + name + ' → ' + hit[0])
            else:
                failures.append('未拦住 ' + name + '（期望 ' + code + '），实际：' + '; '.join(errors))
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print('FX05A_HOST_SELF_TEST all mutants killed')
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--hap')
    parser.add_argument('--base-hap')
    parser.add_argument('--root', default=str(ROOT))
    args = parser.parse_args()
    couli = couli_dir()
    if args.self_test:
        return self_test(couli)
    root = Path(args.root)
    errors = check_hap(root, args.hap, args.base_hap) if args.hap else check_repo(root, couli)
    for error in errors:
        print(error)
    print('FX05A_HOST ' + ('FAIL violations=' + str(len(errors)) if errors else 'PASS'))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
