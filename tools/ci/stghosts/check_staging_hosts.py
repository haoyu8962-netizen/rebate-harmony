#!/usr/bin/env python3
"""FU-X-STAGING-HOSTS-harmony 宿主检查（测试作者 v1）。依据 NATIVE/FU-X-STAGING-HOSTS/brief-harmony.md §1 与 D10-598。
只用 Python 3 标准库；不调 git、不联网、不跑 hvigor（制品层面的最终证据仍是 verify 里对真实 .hap 的 release-scan）。

检查项（源码静态）：
  H1 staging 环境端点表（common/core/src/staging/ets/config/EnvironmentCatalog.ets）STAGING 恰为
     new EnvironmentEndpoints('https://api-stg.couliapp.cn', 'https://h5-stg.couliapp.cn', 'https://stream-stg.couliapp.cn')
  H2 任一 -stg.couliapp.cn 主机只许出现在产品的 src/staging 源码集（Debug / Staging 才编译）；src/main、src/release、模块配置、
     hvigorfile、AppScope、资源等一律不得出现（Release 带出）。测试源码集（src/test、src/ohosTest）与 tools/ 不算产品
  H3 LOCAL / TEST 仍是 .invalid 占位（逐字），产品源码里不再有 staging.couli.invalid
  H4 正式不变：AppEnvironment.ets 的 PROD_ENDPOINTS 仍恰为两参数 ('https://api.prod.couli.invalid', 'https://h5.prod.couli.invalid')
     （不设 stream，D10-598「正式环境不设」）；Release 端点表仍只给 PROD_ENDPOINTS
  H5 深链：entry/src/staging BuildVariant.deepLinkConfig() 恰为 new DeepLinkConfig(['couli-debug'], ['l-stg.couliapp.cn'])；
     Release 的同名函数仍 return DeepLinkConfig.EMPTY；hvigorfile 不声明 https 深链（系统级 App Links 另立 FU-X-APPLINKS-STAGING）
  H6 分享域与桥白名单不手写：产品源码不得出现 s-stg.couliapp.cn（share_domains / bridge_origins 由 ops 经 /v1/config 下发）
  H7 注释：staging 端点表删去「真实域名待定」并写明 FU-X-STAGING-HOSTS；staging deepLinkConfig 注释删去「不在这里放任何域名」
检查项（release-scan 规则，合成制品，真跑 tools/ci/release-scan.sh）：
  R1 scan：只含五个主机之一（https:// 形式、裸主机名、UTF-16LE 三种写法）的合成包一律退出 1
  R2 scan：只含正式 / 占位外观的串（couliapp.cn、api.couliapp.cn、s.couliapp.cn、l.couliapp.cn、couliapp.com、*.prod.couli.invalid）退出 0
  R3 scan：local / test 的 .couli.invalid 仍拦（退出 1）
  R4 --self-test：照「实现后 Staging 制品实际含有的串」合成的包（既有全部非地址标记 + debug_only 路由 + local / test / prod 占位 +
     api-stg / stream-stg / h5-stg 基址 + 裸 l-stg 主机，不含 s-stg、不含旧 staging 占位）退出 0
  R4b --self-test：同一合成包去掉全部 -stg 主机后退出 1（Staging 制品必须命中 staging 主机规则）
  R5 tools/ci/release-scan-selftest.sh（失败路径自测）退出 0

用法：
  check_staging_hosts.py               本仓库
  check_staging_hosts.py --root <目录>  换一棵树
  check_staging_hosts.py --self-test   拷出本仓库：已通过则以它为参考，否则先套用内置参考补丁（只证明检查有牙齿）；
                                       参考必须全过，然后每种错误实现各自打红（定位串必须命中，命中的检查项必须是预期那一项）
"""
import ast
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
STG_API = 'https://api-stg.couliapp.cn'
STG_H5 = 'https://h5-stg.couliapp.cn'
STG_STREAM = 'https://stream-stg.couliapp.cn'
STG_LINK = 'l-stg.couliapp.cn'
STG_SHARE = 's-stg.couliapp.cn'
HOSTS = ['api-stg.couliapp.cn', 'stream-stg.couliapp.cn', 'h5-stg.couliapp.cn', STG_LINK, STG_SHARE]
STG_SUFFIX = '-stg.couliapp.cn'
CATALOG = 'common/core/src/staging/ets/config/EnvironmentCatalog.ets'
RELEASE_CATALOG = 'common/core/src/release/ets/config/EnvironmentCatalog.ets'
APP_ENV = 'common/core/src/main/ets/config/AppEnvironment.ets'
BV_STAGING = 'entry/src/staging/ets/variant/BuildVariant.ets'
BV_RELEASE = 'entry/src/release/ets/variant/BuildVariant.ets'
HVIGOR_ENTRY = 'entry/hvigorfile.ts'
SCAN = 'tools/ci/release-scan.sh'
SCAN_SELFTEST = 'tools/ci/release-scan-selftest.sh'
ROUTES = 'contracts/snapshot/contracts/routes.json'
SKIP_DIRS = {'.git', 'build', 'oh_modules', 'node_modules', '.hvigor', '.preview', '.idea', '__pycache__'}
NON_PRODUCT_TOP = {'tools', 'docs', 'specs', 'contracts'}
TEST_PARTS = ('/src/test/', '/src/ohosTest/', '/src/mock/')
TEXT_EXT = {'.ets', '.ts', '.js', '.json', '.json5', '.txt', '.xml', '.html', '.css', '.sh', '.py', '.cjs', '.mjs', '.md'}


def read(root, rel):
    p = root / rel
    return p.read_text(encoding='utf-8') if p.is_file() else ''


def strip_comments(text):
    text = re.sub(r'/\*[\s\S]*?\*/', '', text)
    return re.sub(r'(?m)(^|[^:\'"])//.*$', r'\1', text)


def method_body(text, name):
    m = re.search(r'static\s+' + name + r'\s*\([^)]*\)\s*:\s*\w+\s*\{', text)
    if not m:
        return None
    depth, i = 0, m.end() - 1
    while i < len(text):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[m.end():i]
        i += 1
    return None


def doc_before(text, name):
    m = re.search(r'static\s+' + name + r'\s*\(', text)
    if not m:
        return ''
    head = text[:m.start()]
    k = head.rfind('/**')
    return head[k:] if k >= 0 and '*/' in head[k:] else ''


def product_files(root):
    for dirpath, dirnames, names in os.walk(root):
        rel_dir = Path(dirpath).relative_to(root).as_posix()
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not (rel_dir == '.' and d in NON_PRODUCT_TOP)]
        for n in names:
            rel = (Path(rel_dir) / n).as_posix() if rel_dir != '.' else n
            if Path(n).suffix not in TEXT_EXT:
                continue
            if any(t in '/' + rel for t in TEST_PARTS):
                continue
            yield rel


def check_static(root):
    v = []
    cat = read(root, CATALOG)
    code = strip_comments(cat)
    m = re.search(r'map\.set\(\s*AppEnvironment\.STAGING\s*,\s*new\s+EnvironmentEndpoints\(([^)]*)\)\s*\)', code)
    want = "'%s', '%s', '%s'" % (STG_API, STG_H5, STG_STREAM)
    got = re.sub(r'\s+', ' ', m.group(1)).strip() if m else None
    if got != want:
        v.append('H1 STAGING 端点应恰为 (%s)，实际 %s' % (want, got))
    for env, api, h5 in [('LOCAL', 'https://api.local.couli.invalid', 'https://h5.local.couli.invalid'),
                         ('TEST', 'https://api.test.couli.invalid', 'https://h5.test.couli.invalid')]:
        m = re.search(r'map\.set\(\s*AppEnvironment\.' + env + r'\s*,\s*new\s+EnvironmentEndpoints\(([^)]*)\)\s*\)', code)
        args = [a.strip() for a in m.group(1).split(',')] if m else []
        if args[:2] != ["'%s'" % api, "'%s'" % h5] or any('couli.invalid' not in a and a != "''" for a in args[2:]):
            v.append('H3 %s 应仍为 .invalid 占位 (%s, %s)（stream 可缺省或 .invalid），实际 %s' % (env, api, h5, args))
    if '真实域名待定' in cat or 'FU-X-STAGING-HOSTS' not in cat:
        v.append('H7 staging 端点表注释应删去「真实域名待定」并写明 FU-X-STAGING-HOSTS')
    for rel in product_files(root):
        text = read(root, rel)
        if STG_SUFFIX in text and '/src/staging/' not in '/' + rel:
            v.append('H2 %s 含 -stg.couliapp.cn 主机（只许在 src/staging 源码集；main / release / 配置会被 Release 带出）' % rel)
        if 'staging.couli.invalid' in text:
            v.append('H3 %s 仍含旧占位 staging.couli.invalid' % rel)
        if STG_SHARE in text:
            v.append('H6 %s 手写了分享域 %s（share_domains 由 ops 经 /v1/config 下发）' % (rel, STG_SHARE))
    env = strip_comments(read(root, APP_ENV))
    m = re.search(r'PROD_ENDPOINTS\s*:\s*EnvironmentEndpoints\s*=\s*new\s+EnvironmentEndpoints\(([^)]*)\)', env)
    got = re.sub(r'\s+', ' ', m.group(1)).strip() if m else None
    if got != "'https://api.prod.couli.invalid', 'https://h5.prod.couli.invalid'":
        v.append('H4 PROD_ENDPOINTS 必须仍为两参数 api / h5.prod.couli.invalid（正式不设 stream），实际 %s' % got)
    rel_cat = strip_comments(read(root, RELEASE_CATALOG))
    sets = re.findall(r'map\.set\(\s*AppEnvironment\.(\w+)\s*,\s*([^)]*)\)', rel_cat)
    if sets != [('PROD', 'PROD_ENDPOINTS')]:
        v.append('H4 Release 端点表应只有 map.set(AppEnvironment.PROD, PROD_ENDPOINTS)，实际 %s' % sets)
    bv = read(root, BV_STAGING)
    body = method_body(strip_comments(bv), 'deepLinkConfig')
    if body is None or not re.fullmatch(
            r"\s*return\s+new\s+DeepLinkConfig\(\s*\['couli-debug'\]\s*,\s*\['" + re.escape(STG_LINK) + r"'\]\s*\)\s*;\s*", body):
        v.append("H5 staging BuildVariant.deepLinkConfig() 应恰为 return new DeepLinkConfig(['couli-debug'], ['%s'])，实际 %r"
                 % (STG_LINK, body))
    if '不在这里放任何域名' in doc_before(bv, 'deepLinkConfig'):
        v.append('H7 staging deepLinkConfig 注释仍写「不在这里放任何域名」')
    rbody = method_body(strip_comments(read(root, BV_RELEASE)), 'deepLinkConfig')
    if rbody is None or not re.fullmatch(r'\s*return\s+DeepLinkConfig\.EMPTY\s*;\s*', rbody):
        v.append('H5 Release BuildVariant.deepLinkConfig() 必须仍 return DeepLinkConfig.EMPTY，实际 %r' % rbody)
    hv = strip_comments(read(root, HVIGOR_ENTRY))
    if re.search(r"scheme\s*:\s*'https?'", hv) or 'couliapp' in hv:
        v.append('H5 entry/hvigorfile.ts 声明了 http(s) 深链或 couliapp 主机（系统级 App Links 另立 FU-X-APPLINKS-STAGING）')
    return v


# ---------------------------------------------------------------- release-scan 规则（合成制品）

def scan_markers(root):
    """照 ds02/test_host.py 的取法：从 release-scan.sh 的内嵌 Python 里取 markers 列表（含常量引用）。"""
    script = read(root, SCAN).split("<<'PY'\n", 1)[1].split('\nPY', 1)[0]
    assigns = [n for n in ast.parse(script).body if isinstance(n, ast.Assign)]
    consts = {n.targets[0].id: ast.literal_eval(n.value) for n in assigns
              if isinstance(n.targets[0], ast.Name) and isinstance(n.value, ast.Constant)}
    node = next(n.value for n in assigns if any(isinstance(t, ast.Name) and t.id == 'markers' for t in n.targets))
    return [consts[e.id] if isinstance(e, ast.Name) else ast.literal_eval(e) for e in node.elts]


def make_hap(path, payload, scheme=False, encoding='utf-8'):
    module = {'app': {'bundleName': 'com.couli.hm', 'debug': False, 'buildMode': 'release'}}
    if scheme:
        module['module'] = {'abilities': [{'name': 'EntryAbility',
                                           'skills': [{'uris': [{'scheme': 'couli-debug', 'host': 'r'}]}]}]}
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('module.json', json.dumps(module))
        z.writestr('ets/modules.abc', payload.encode(encoding))


def run_scan(root, work, hap, self_test=False):
    cmd = ['bash', str(root / SCAN)] + (['--self-test'] if self_test else []) + [str(hap)]
    env = dict(os.environ, COULI_SCAN_WORK_DIR=str(work / 'scan-tmp'))
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return r.returncode, r.stdout + r.stderr


def staging_payload(root, with_stg=True):
    markers = [m for m in scan_markers(root) if 'couliapp' not in m and 'couli.invalid' not in m]
    routes = json.loads(read(root, ROUTES))['routes']
    markers += [n for n, r in routes.items() if r.get('debug_only') is True]
    addresses = ['https://api.local.couli.invalid', 'https://h5.local.couli.invalid', 'https://api.test.couli.invalid',
                 'https://h5.test.couli.invalid', 'https://api.prod.couli.invalid', 'https://h5.prod.couli.invalid']
    if with_stg:
        addresses += [STG_API, STG_H5, STG_STREAM, STG_LINK]
    return '\n'.join(markers + addresses)


def check_scan(root):
    v = []
    work = Path(tempfile.mkdtemp(prefix='stghosts-scan-'))
    try:
        try:
            scan_markers(root)
        except Exception as e:  # noqa: BLE001
            return ['R0 读不出 release-scan.sh 的 markers 列表：%r' % (e,)]
        n = 0
        for host in HOSTS:
            for label, text, enc in [('https', 'https://' + host, 'utf-8'), ('bare', '"' + host + '"', 'utf-8'),
                                     ('utf16', host, 'utf-16-le')]:
                n += 1
                hap = work / ('r1-%d.hap' % n)
                make_hap(hap, 'prod.couli.invalid ' + text, encoding=enc)
                code, out = run_scan(root, work, hap)
                if code != 1:
                    v.append('R1 scan 没拦住 %s（%s 写法）：exit %d' % (host, label, code))
        hap = work / 'r2.hap'
        make_hap(hap, '\n'.join(['https://api.prod.couli.invalid', 'https://h5.prod.couli.invalid', 'couliapp.cn',
                                 'https://api.couliapp.cn', 's.couliapp.cn', 'l.couliapp.cn', 'couliapp.com', 'stg.example.invalid']))
        code, out = run_scan(root, work, hap)
        if code != 0:
            v.append('R2 正式 / 占位外观的串被误拦（规则过宽）：exit %d %s' % (code, out.strip().splitlines()[:3]))
        for ph in ['https://api.local.couli.invalid', 'https://api.test.couli.invalid']:
            hap = work / 'r3.hap'
            make_hap(hap, ph)
            code, _ = run_scan(root, work, hap)
            if code != 1:
                v.append('R3 scan 不再拦 %s：exit %d' % (ph, code))
        hap = work / 'r4.hap'
        make_hap(hap, staging_payload(root), scheme=True)
        code, out = run_scan(root, work, hap, self_test=True)
        if code != 0:
            missing = [l.strip() for l in out.splitlines() if '未命中' in l][:5]
            v.append('R4 照实现后 Staging 制品合成的包 --self-test 没过（exit %d；%s）——规则仍要求旧占位 / 手写的分享域等'
                     % (code, missing))
        hap = work / 'r4b.hap'
        make_hap(hap, staging_payload(root, with_stg=False), scheme=True)
        code, _ = run_scan(root, work, hap, self_test=True)
        if code != 1:
            v.append('R4b 去掉全部 -stg 主机后 --self-test 仍 exit %d（Staging 制品必须命中 staging 主机规则）' % code)
        r = subprocess.run(['bash', str(root / SCAN_SELFTEST), str(work / 'selftest')], capture_output=True, text=True)
        if r.returncode != 0:
            v.append('R5 release-scan-selftest.sh 失败：exit %d' % r.returncode)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return v


def check(root):
    return check_static(root) + check_scan(root)


# ---------------------------------------------------------------- 自测

# 底版 e915d9b 上的最小参考补丁（只在本仓库尚未通过时套用；只为证明检查有牙齿，不是给实现方的写法要求）。
REFERENCE_PATCH = [
    (CATALOG, "// 取值是 .invalid 占位，真实域名待定（needs.md N-05）。",
     "// local / test 是 .invalid 占位；staging 是真实主机（FU-X-STAGING-HOSTS）。"),
    (CATALOG, "new EnvironmentEndpoints('https://api.staging.couli.invalid', 'https://h5.staging.couli.invalid')",
     "new EnvironmentEndpoints('%s', '%s', '%s')" % (STG_API, STG_H5, STG_STREAM)),
    (BV_STAGING, "return new DeepLinkConfig(['couli-debug'], []);", "return new DeepLinkConfig(['couli-debug'], ['%s']);" % STG_LINK),
    (BV_STAGING, "正式 scheme 与 l. 子域未定（needs N-05），不在这里放任何域名。",
     "staging 深链主机 l-stg（FU-X-STAGING-HOSTS）；系统级 App Links 另立 FU-X-APPLINKS-STAGING。"),
    (SCAN, '"staging.couli.invalid",', '"-stg.couliapp.cn",'),
]


def _append(rel, line):
    return ('append', rel, line)


# (名称, 预期打红的检查项前缀, 变异)。变异：(文件, 正则, 替换) 至少命中一次；或 append。
MUTANTS = [
    ('staging 仍 .invalid', 'H1', (CATALOG, r"'https://api-stg\.couliapp\.cn'", "'https://api.staging.couli.invalid'")),
    ('stream 没登记进 STAGING', 'H1', (CATALOG, r",\s*'https://stream-stg\.couliapp\.cn'", '')),
    ('主机写进 main 源码集', 'H2', _append(APP_ENV, "export const STAGING_API: string = '%s';\n" % STG_API)),
    ('主机写进 release 源码集', 'H2', _append(BV_RELEASE, "const LINK_HOST: string = '%s';\n" % STG_LINK)),
    ('主机写进 entry 资源', 'H2', _append('entry/src/main/resources/base/element/string.json', '"%s"\n' % STG_H5)),
    ('local 改成真实主机', 'H3', (CATALOG, r"'https://api\.local\.couli\.invalid'", "'https://api.local.couliapp.cn'")),
    ('正式环境被改（PROD 设了 stream）', 'H4',
     (APP_ENV, r"(PROD_ENDPOINTS\s*:\s*EnvironmentEndpoints\s*=\s*new\s+EnvironmentEndpoints\('https://api\.prod\.couli\.invalid',"
               r"\s*'https://h5\.prod\.couli\.invalid')\)", r"\1, 'https://stream.prod.couli.invalid')")),
    ('正式 api 被改', 'H4', (APP_ENV, r"'https://api\.prod\.couli\.invalid'", "'https://api.couliapp.cn'")),
    ('深链主机没加', 'H5', (BV_STAGING, r"'l-stg\.couliapp\.cn'", "'l.example.invalid'")),
    ('Release 也认 l-stg', 'H5', (BV_RELEASE, r'return\s+DeepLinkConfig\.EMPTY\s*;',
                                  "return new DeepLinkConfig([], ['l-stg.couliapp.cn']);")),
    ('手写分享域', 'H6', _append(BV_STAGING, "const SHARE_HOST: string = '%s';\n" % STG_SHARE)),
    ('注释仍写真实域名待定', 'H7', _append(CATALOG, '// 真实域名待定\n')),
    ('release-scan 漏规则', 'R1', (SCAN, r'couliapp', 'couliapp-gone')),
    ('release-scan 规则过宽（整个 couliapp.cn）', 'R2', (SCAN, r'"local\.couli\.invalid",', '"local.couli.invalid", "couliapp.cn",')),
    ('release-scan 不再拦 local', 'R3', (SCAN, r'"local\.couli\.invalid",', '')),
    ('--self-test 仍要求旧 staging 占位', 'R4', (SCAN, r'"local\.couli\.invalid",', '"local.couli.invalid", "staging.couli.invalid",')),
    ('--self-test 要求手写的分享域', 'R4', (SCAN, r'"local\.couli\.invalid",', '"local.couli.invalid", "s-stg.couliapp.cn",')),
]


def copy_tree(src, dst):
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns(*SKIP_DIRS))


def self_test():
    failures = 0
    base = Path(tempfile.mkdtemp(prefix='stghosts-self-'))
    try:
        ref = base / 'ref'
        copy_tree(ROOT, ref)
        if check(ref):
            for rel, old, new in REFERENCE_PATCH:
                p = ref / rel
                text = p.read_text(encoding='utf-8')
                if text.count(old) != 1:
                    print('  FAIL 参考补丁定位串不在 %s：%r（本仓库也没通过，无法建参考）' % (rel, old))
                    return 1
                p.write_text(text.replace(old, new), encoding='utf-8')
            print('  参考：底版 + 内置参考补丁')
        else:
            print('  参考：本仓库（已通过）')
        got = check(ref)
        if got:
            print('  FAIL 参考树没有全过：\n    ' + '\n    '.join(got))
            return 1
        print('  ok   参考树全过')
        for name, want, mut in MUTANTS:
            d = base / 'mut'
            shutil.rmtree(d, ignore_errors=True)
            copy_tree(ref, d)
            if mut[0] == 'append':
                p = d / mut[1]
                p.write_text(p.read_text(encoding='utf-8') + mut[2], encoding='utf-8')
            else:
                rel, pattern, repl = mut
                p = d / rel
                text = p.read_text(encoding='utf-8')
                new, k = re.subn(pattern, repl, text)
                if k == 0:
                    print('  FAIL 变异「%s」定位串没命中 %s' % (name, rel))
                    failures += 1
                    continue
                p.write_text(new, encoding='utf-8')
            got = check(d)
            hit = [g for g in got if g.startswith(want)]
            if hit:
                print('  ok   %s → %s' % (name, hit[0][:110]))
            else:
                print('  FAIL %s 没有被 %s 打红（实际：%s）' % (name, want, [g[:60] for g in got]))
                failures += 1
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print('stghosts 自测：%d 个变异，%d 个失败' % (len(MUTANTS), failures))
    return 1 if failures else 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    root = Path(argv[argv.index('--root') + 1]).resolve() if '--root' in argv else ROOT
    got = check(root)
    for g in got:
        print('  ' + g)
    print('stghosts 宿主检查：%d 项违反' % len(got))
    return 1 if got else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
