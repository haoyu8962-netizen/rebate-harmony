#!/usr/bin/env python3
"""HM-07v-a（首页视觉 a 段）宿主检查：fixture 三端一致、设备用例名单、深色启动参数只在 Debug / Staging（H-V06）、几处必须的接线。

用法：
  check_home_visual.py                     检查本仓库源码（实现落地前预期红）
  check_home_visual.py --hap Release.hap   Release 制品里不得出现 couli_debug_color_mode（H-V06「Release 包必须不含该入口」）
  check_home_visual.py --hap-staging X.hap Staging / Debug 制品里必须有该入口（防止整段被删掉也算过）
  check_home_visual.py --self-test         对临时副本逐个施加错误实现，每个都必须被拦下

静态接线检查只守「不用就一定错」的点（自写网格阈值、搜索行回列表、价值卡身份没接、深色键漏进 Release 源码）；
行为本身由 core / designsystem Hypium 套件与 entry 设备用例判定。
"""
import hashlib
import json
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
COLOR_KEY = 'couli_debug_color_mode'
# Android origin/main d074cc5（iOS origin/main 同一份字节）specs/home-sdui-vectors.json 的两张视觉页，规范化 JSON 的 sha256。
VISUAL_SHA = {
    'main_v3': '64048e8e585a6d64720fcd05a74c0e7e6f1b4ec6a4daceb8669282a80a693652',
    'guest_v3': '2467261a7fd2f7993ee0e04156f032867ecfe1a7ca201ea7eef7b4234b8c6f13',
}
# 鸿蒙 origin/main af9aab2 的向量（去掉两张视觉页后）：已有页与判定向量一条不改。
# D1（本线裁定，HM-07v-a 实现交回）：default_home 两张活动卡同步 Android / iOS 的 subtitle（三端同文件），原值 ad441c0e…f3c9。
REST_SHA = 'c48a750433b61fadee25c302c6e523a0c8aff313062d4fe3ef0579e96b6ded9f'
SUITE = 'entry/src/ohosTest/ets/test/Hm07vHomeUi.test.ets'
CASES = 'tools/ci/hm07v/fixtures/device-cases.txt'


def canon(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def read(root, rel):
    path = root / rel
    return path.read_text(encoding='utf-8') if path.exists() else ''


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def check_fixture(root):
    errors = []
    vectors = json.loads(read(root, 'specs/home-sdui-vectors.json'))
    pages = vectors.get('goldenPages', {})
    for name, want in VISUAL_SHA.items():
        if name not in pages:
            errors.append('F1 goldenPages 缺 ' + name)
        elif hashlib.sha256(canon(pages[name])).hexdigest() != want:
            errors.append('F1 goldenPages.%s 与 Android / iOS 已合并的同名页不逐字一致' % name)
    rest = json.loads(json.dumps(vectors))
    for name in VISUAL_SHA:
        rest.get('goldenPages', {}).pop(name, None)
    if hashlib.sha256(canon(rest)).hexdigest() != REST_SHA:
        errors.append('F2 已有 golden 页或判定向量被改动（本任务只新增 main_v3 / guest_v3）')
    for name in VISUAL_SHA:
        for section in pages.get(name, {}).get('sections', []):
            if section.get('type') in ('product_scroll', 'product_grid', 'feed_infinite'):
                if section.get('id') not in ('scroll', 'grid', 'feed'):
                    errors.append('F3 %s 商品段 id %s 不是三端一致的 scroll / grid / feed' % (name, section.get('id')))
    golden = read(root, 'entry/src/staging/ets/variant/HomeGoldenPages.ets')
    if '"main_v3"' not in golden or '"guest_v3"' not in golden:
        errors.append('F4 staging HomeGoldenPages.ets 没有重新生成（gen.py）')
    return errors


def check_cases(root):
    errors = []
    suite = read(root, SUITE)
    declared = re.findall(r"\bit\('(hm07va_[a-z0-9_]+)'", suite)
    block = suite[suite.find('HM07VA_DEVICE_CASES'):]
    listed = re.findall(r"'(hm07va_[a-z0-9_]+)'", block)
    fixture = [line.strip() for line in read(root, CASES).splitlines() if line.strip() and not line.startswith('#')]
    if not declared:
        errors.append('C1 设备套件没有 hm07va_ 用例')
    if declared != listed or declared != fixture:
        errors.append('C1 用例名单不一致：套件 %d / 导出 %d / 登记 %d' % (len(declared), len(listed), len(fixture)))
    if len(set(declared)) != len(declared):
        errors.append('C1 用例重名')
    registry = read(root, 'tools/ci/ds02/check_device_result.py')
    if 'hm07v/fixtures/device-cases.txt' not in registry:
        errors.append('C2 check_device_result.py 没把 HM-07v-a 用例列为必跑')
    # C4（编排 D10-405 D4，测试 v2）：verify 里 entry 拆成两个设备步——原 entry 步排除本套件、按 main 名单核对；单独步只跑本套件、
    # 按 hm07va 名单核对；device-test.sh 把套件过滤传给 aa test、把名单传给 check_device_result.py。
    verify = read(root, 'tools/ci/verify.sh')
    dispatch = [line.split() for line in verify.splitlines() if line.strip().startswith('run_device_tests entry ')]
    tails = [d[-3:] for d in dispatch]
    # HM-07v-b（测试 b v1，D10-378 test-change）：主步同时排除 b 段套件 Hm07vOverlayUi，b 段另有第三步（check_overlays.py C2 守）。
    # HM-05r 测试 v1（D10-378 test-change）：主步再排除 Hm05rConsentUi，另有第四步 entry-hm05r（check_hm05r.py C2 守）。
    # APP-12v-harmony 测试 v1（D10-378 test-change）：主步再排除 Me12vUi，另有第五步 entry-me12v（check_me_visual.py C2 守）。
    # APP-12w-a-harmony 测试 v1（#24 只换定位串，D10-600 H-S08）：主步再排除 Me12waUi，另有第六步 entry-me12wa（check_settings_visual.py C2 守）。
    # APP-12w-b-harmony 测试 v1（#24 只换定位串，H-P13）：主步再排除 Me12wbUi，另有第七步 entry-me12wb（check_privacy_visual.py C2 守）。
    # APP-12w-c-harmony 测试 v1（#24 只换定位串，H-R16）：主步再排除 Me12wcUi，另有第八步 entry-me12wc（check_risk_visual.py C2 守）。
    if ['entry', 'notClass=Hm07vHomeUi,Hm07vOverlayUi,Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi', 'main'] not in tails \
            or ['entry-hm07va', 'class=Hm07vHomeUi', 'hm07va'] not in tails or len(dispatch) != 9:
        errors.append('C4 verify.sh 没把 entry 拆成设备步（entry notClass=Hm07vHomeUi,Hm07vOverlayUi,Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi main / '
                      'entry-hm07va class=Hm07vHomeUi hm07va / entry-hm07vb / entry-hm05r / entry-me12v / entry-me12wa / entry-me12wb / entry-me12wc / entry-tabbar）')
    device = read(root, 'tools/ci/device-test.sh')
    if '${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"}' not in device or '--set "$DEVICE_SET"' not in device \
            or '[ "$elapsed_seconds" -le 1800 ]' not in device:
        errors.append('C4 device-test.sh 没把套件过滤传给 aa test / 没按步核对必跑名单 / 没有每步 1800 秒门槛')
    # C5（测试 v2，D10-405 D2）：设备用例算首页 minColumn 用的超市百货两件商品必须是 fixture guest_v3 的逐字拷贝。
    m = re.search(r"HM07VA_GUEST_GRID_ITEMS: string =((?:\s*\+?\s*'[^']*')+);", suite)
    try:
        embedded = json.loads(''.join(re.findall(r"'([^']*)'", m.group(1)))) if m else None
        wanted = json.loads(read(root, 'specs/home-sdui-vectors.json'))['goldenPages']['guest_v3']['sectionItems']['grid']['items']
    except (ValueError, KeyError, TypeError):
        embedded, wanted = None, ()
    if embedded is None or canon(embedded) != canon(wanted):
        errors.append('C5 设备用例 HM07VA_GUEST_GRID_ITEMS 与 fixture guest_v3.sectionItems.grid.items 不一致')
    lst = strip_comments(read(root, 'entry/src/ohosTest/ets/test/List.test.ets'))
    calls = re.findall(r'^\s*(\w+)\(\);', lst, flags=re.M)
    if not calls or calls[-1] != 'hm07vHomeUiTest':
        errors.append('C3 List.test.ets 必须最后注册 hm07vHomeUiTest（隐私状态单向）')
    return errors


def source_files(root, parts):
    out = []
    for part in parts:
        base = root / part
        if base.exists():
            out += [p for p in base.rglob('*.ets') if 'oh_modules' not in p.parts and '/build/' not in str(p)]
    return out


def check_color_mode(root):
    errors = []
    staging = [p for p in source_files(root, ['entry/src/staging']) if COLOR_KEY in p.read_text(encoding='utf-8')]
    if not staging:
        errors.append('D1 staging 源码集里没有深色启动参数 %s（H-V06）' % COLOR_KEY)
    leaked = [p for p in source_files(root, ['entry/src/main', 'entry/src/release', 'common/core/src/main',
                                             'common/designsystem/src/main', 'common/generated/src/main',
                                             'common/generated/src/release', 'features'])
              if COLOR_KEY in p.read_text(encoding='utf-8')]
    for p in leaked:
        errors.append('D2 深色启动参数出现在会进 Release 的源码：' + str(p.relative_to(root)))
    scan = read(root, 'tools/ci/release-scan.sh')
    marker_block = scan[scan.find('markers = ['):scan.find('test_only_markers')]
    if '"' + COLOR_KEY + '"' not in marker_block:
        errors.append('D3 release-scan.sh 的 markers 没登记 %s（Release 命中即失败、Staging 自测必须命中）' % COLOR_KEY)
    return errors


def function_body(text, name):
    m = re.search(r'\b' + re.escape(name) + r'\s*\([^)]*\)\s*(:\s*[\w<>\[\] |]+)?\s*\{', text)
    if not m:
        return ''
    depth, i = 0, m.end() - 1
    for j in range(i, len(text)):
        if text[j] == '{':
            depth += 1
        elif text[j] == '}':
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return ''


def check_wiring(root):
    errors = []
    cards = strip_comments(read(root, 'features/home/src/main/ets/HomeCards.ets'))
    if 'ProductGridLayout.columns(' not in cards:
        errors.append('W1 首页网格 / 信息流没用组件库 ProductGridLayout.columns（H11）')
    if re.search(r'\b150\b', cards) or re.search(r'scale\s*>\s*1\.5', cards):
        errors.append('W1 HomeCards.ets 仍有自写网格阈值（150vp / 1.5 倍）')
    if 'HomeIconArt.kind(' not in cards or 'PlatformIcon(' not in cards:
        errors.append('W2 金刚区平台格没按 HomeIconArt.kind 选图、没用 F-X-05a PlatformIcon（G-V01）')
    root_view = strip_comments(read(root, 'features/home/src/main/ets/HomeTabRoot.ets'))
    rows = function_body(root_view, 'rows')
    if re.search(r"new HomeRow\(\s*'search'", root_view) or "'search'" in rows:
        errors.append('W3 搜索行仍是列表里的一行（H-V02 要固定在列表外）')
    if 'HomeNativeRows.of(' not in root_view or 'HomeNativeRows.cardKey(' not in root_view:
        errors.append('W3 首页列表没用 HomeNativeRows.of / cardKey 组原生行与卡片行键')
    # W5（D3 / 编排 D10-405）：内容列限宽走 designsystem ContentColumn 纯函数（本机单测按窗口宽参数化覆盖），不在视图里另写 600。
    if 'ContentColumn.' not in root_view or re.search(r'maxWidth\s*:\s*600\b', root_view):
        errors.append('W5 首页内容列限宽没用 ContentColumn（本机单测覆盖的 w > 600 分支与页面不是同一口径）')
    app_home = strip_comments(read(root, 'entry/src/main/ets/home/AppHome.ets'))
    sync = function_body(app_home, 'syncInner')
    guest = re.search(r'model\.guest\s*=\s*HomeFixedArea\.isGuest\(', sync)
    keep = sync.find('outcome.keep')
    if guest is None:
        errors.append('W4 AppHome.syncInner 没按身份写 model.guest = HomeFixedArea.isGuest(...)（登录后价值卡要立即消失）')
    elif keep >= 0 and guest.start() > keep:
        errors.append('W4 model.guest 写在 outcome.keep 提前返回之后：身份变了但页面保留时价值卡不消失')
    return errors


def check_source(root):
    return check_fixture(root) + check_cases(root) + check_color_mode(root) + check_wiring(root)


def hap_contains(hap, needle):
    data = needle.encode('utf-8')
    with zipfile.ZipFile(hap) as z:
        for info in z.infolist():
            if data in z.read(info):
                return info.filename
            if info.filename.endswith(('.hap', '.har', '.hsp', '.zip')):
                tmp = Path(tempfile.mkdtemp()) / 'inner.zip'
                tmp.write_bytes(z.read(info))
                try:
                    hit = hap_contains(tmp, needle)
                finally:
                    shutil.rmtree(tmp.parent, ignore_errors=True)
                if hit:
                    return info.filename + '!' + hit
    return None


# ---------------------------------------------------------------- 自测：错误实现必须被拦下

def mutate(root, rel, old, new):
    path = root / rel
    text = path.read_text(encoding='utf-8') if path.exists() else ''
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.replace(old, new) if old else text + new, encoding='utf-8')


def good_tree(tmp):
    """参考件：按交回 §3 的接口写一份「正确实现」的最小源码（只为证明检查有牙齿，不算产品通过）。"""
    for rel in ['specs/home-sdui-vectors.json', SUITE, CASES, 'tools/ci/ds02/check_device_result.py',
                'entry/src/ohosTest/ets/test/List.test.ets', 'tools/ci/release-scan.sh', 'tools/ci/verify.sh',
                'tools/ci/device-test.sh',
                'entry/src/staging/ets/variant/HomeGoldenPages.ets']:
        dst = tmp / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / rel, dst)
    mutate(tmp, 'entry/src/staging/ets/variant/BuildVariant.ets', '',
           "const mode: Object | undefined = want.parameters?.['" + COLOR_KEY + "'];\n")
    scan = tmp / 'tools/ci/release-scan.sh'
    text = scan.read_text(encoding='utf-8')
    if '"' + COLOR_KEY + '"' not in text:
        scan.write_text(text.replace('markers = [', 'markers = [\n    "' + COLOR_KEY + '",', 1), encoding='utf-8')
    mutate(tmp, 'features/home/src/main/ets/HomeCards.ets', '',
           'const n: number = ProductGridLayout.columns(2, this.gridWidth, this.fontScale.scale);\n'
           'const k: string = HomeIconArt.kind(cell.icon, failed, PlatformIconSource.hasBuiltin);\nPlatformIcon({})\n')
    mutate(tmp, 'features/home/src/main/ets/HomeTabRoot.ets', '',
           ".constraintSize({ maxWidth: ContentColumn.MAX_WIDTH })\n"
           "private rows(): HomeRow[] {\n  for (const k of HomeNativeRows.of(fixed)) { out.push(new HomeRow(k, k, null, t)); }\n"
           "  const key: string = HomeNativeRows.cardKey(t.key, v.card.id, d);\n  return out;\n}\n")
    mutate(tmp, 'entry/src/main/ets/home/AppHome.ets', '',
           "private syncInner(): void {\n  const read: HomeIdentityRead = this.identity.now();\n"
           "  this.model.guest = HomeFixedArea.isGuest(read.home.level);\n  if (outcome.keep) {\n    return;\n  }\n}\n")


def self_test():
    mutants = [
        ('网格自写阈值', 'features/home/src/main/ets/HomeCards.ets', 'ProductGridLayout.columns(2, this.gridWidth, this.fontScale.scale)',
         'this.gridWidth < 2 * 150 + 12 ? 1 : 2', 'W1'),
        ('金刚区平台格文字胶囊', 'features/home/src/main/ets/HomeCards.ets', 'PlatformIcon({})', 'Text(cell.title)', 'W2'),
        ('搜索行回到列表', 'features/home/src/main/ets/HomeTabRoot.ets', '  return out;',
         "  out.push(new HomeRow('search', 'search', null, t));\n  return out;", 'W3'),
        ('价值卡身份没接', 'entry/src/main/ets/home/AppHome.ets', '  this.model.guest = HomeFixedArea.isGuest(read.home.level);\n', '', 'W4'),
        ('价值卡身份写在提前返回之后', 'entry/src/main/ets/home/AppHome.ets',
         '  this.model.guest = HomeFixedArea.isGuest(read.home.level);\n  if (outcome.keep) {\n    return;\n  }\n',
         '  if (outcome.keep) {\n    return;\n  }\n  this.model.guest = HomeFixedArea.isGuest(read.home.level);\n', 'W4'),
        ('深色入口进 Release 源码', 'entry/src/main/ets/entryability/EntryAbility.ets', '',
         "const m: Object | undefined = want.parameters?.['" + COLOR_KEY + "'];\n", 'D2'),
        ('深色入口没登记 release-scan', 'tools/ci/release-scan.sh', '    "' + COLOR_KEY + '",', '', 'D3'),
        ('深色入口整段没做', 'entry/src/staging/ets/variant/BuildVariant.ets', COLOR_KEY, 'couli_debug_other', 'D1'),
        ('改了已有 golden 页', 'specs/home-sdui-vectors.json', '"title": "新人怎么拿返利", "subtitle": "三步看懂", "action"',
         '"title": "新人怎么拿返利", "subtitle": "x", "action"', 'F2'),
        ('main_v3 不逐字', 'specs/home-sdui-vectors.json', '"title": "林间果 每日坚果 30袋"', '"title": "林间果 每日坚果"', 'F1'),
        ('用例未登记必跑', 'tools/ci/ds02/check_device_result.py', 'hm07v/fixtures/device-cases.txt', 'hm07v/none.txt', 'C2'),
        ('套件没排最后', 'entry/src/ohosTest/ets/test/List.test.ets', '  hm07vHomeUiTest();\n', '', 'C3'),
        ('设备用例商品样例与 fixture 不一致', SUITE, '"price_fen":3200', '"price_fen":3300', 'C5'),
        ('entry 没拆步', 'tools/ci/verify.sh', 'entry-hm07va class=Hm07vHomeUi hm07va', 'entry', 'C4'),
        ('原 entry 步没排除本套件', 'tools/ci/verify.sh', 'entry notClass=Hm07vHomeUi,Hm07vOverlayUi,Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi,TabBarShellUi main',
         'entry "" all',
         'C4'),
        ('套件过滤没传给 aa test', 'tools/ci/device-test.sh', ' ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"}', '', 'C4'),
        ('不按步核对名单', 'tools/ci/device-test.sh', ' --set "$DEVICE_SET"', '', 'C4'),
        ('内容列另写 600', 'features/home/src/main/ets/HomeTabRoot.ets', 'maxWidth: ContentColumn.MAX_WIDTH', 'maxWidth: 600',
         'W5'),
    ]
    tmp = Path(tempfile.mkdtemp(prefix='hm07v-host-'))
    failures = []
    try:
        good_tree(tmp)
        base = check_source(tmp)
        if base:
            failures.append('参考件本应全过：' + '; '.join(base))
        for label, rel, old, new, code in mutants:
            case = Path(tempfile.mkdtemp(prefix='hm07v-mut-'))
            try:
                shutil.copytree(tmp, case, dirs_exist_ok=True)
                before = read(case, rel)
                mutate(case, rel, old, new)
                if old and read(case, rel) == before:
                    failures.append('变异没施加上：' + label)
                    continue
                hits = [e for e in check_source(case) if e.startswith(code)]
                print(('KILLED ' if hits else 'SURVIVED ') + label + ' → ' + (hits[0] if hits else code))
                if not hits:
                    failures.append('没拦下：' + label)
            finally:
                shutil.rmtree(case, ignore_errors=True)
        # 制品检查：含键的假 HAP 必须被认出，不含的放行。
        hap = tmp / 'fake.hap'
        with zipfile.ZipFile(hap, 'w') as z:
            z.writestr('ets/modules.abc', b'xx' + COLOR_KEY.encode() + b'yy')
        clean = tmp / 'clean.hap'
        with zipfile.ZipFile(clean, 'w') as z:
            z.writestr('ets/modules.abc', b'nothing here')
        if hap_contains(hap, COLOR_KEY) is None or hap_contains(clean, COLOR_KEY) is not None:
            failures.append('制品扫描自测失败')
        else:
            print('KILLED Release 制品含深色入口 → hap 扫描命中')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in failures:
        print('SELF-TEST FAIL ' + f, file=sys.stderr)
    return 1 if failures else 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    if '--hap' in argv:
        hap = argv[argv.index('--hap') + 1]
        hit = hap_contains(hap, COLOR_KEY)
        if hit:
            print('HM07VA_RELEASE_HAS_COLOR_MODE ' + hit, file=sys.stderr)
            return 1
        print('HM07VA_HAP_OK Release 不含 ' + COLOR_KEY)
        return 0
    if '--hap-staging' in argv:
        hap = argv[argv.index('--hap-staging') + 1]
        if hap_contains(hap, COLOR_KEY) is None:
            print('HM07VA_STAGING_MISSING_COLOR_MODE', file=sys.stderr)
            return 1
        print('HM07VA_HAP_OK Staging 含 ' + COLOR_KEY)
        return 0
    errors = check_source(ROOT)
    for e in errors:
        print('HM07VA ' + e, file=sys.stderr)
    if errors:
        return 1
    print('HM07VA_HOST_OK fixture / 用例名单 / 深色入口 / 接线')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
