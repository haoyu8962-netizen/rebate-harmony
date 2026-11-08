#!/usr/bin/env python3
"""FU-HM-REALNAME-API：实名提交接 POST /v1/me/realname 的宿主检查（任务书 §3.2；D10-887 / D10-1002 / D10-1033）。

键规则、40901、哨兵由 core 的 Realname*.test.ets 跑；这里守本机单测管不到的接线与字节。

  V1 specs/realname-submit-vectors.json 与 iOS 原件逐字节相同：41 行、sha256 2b3f8720…（D10-887 ⑥：三端照抄，鸿蒙差异在测试里映射）。
  C1 向量 contractCommit 等于 contract.lock 的 rebate_platform.commit。
  W1 AppWallet.deps() 恰一处 d.realname = new RealNameRemote(…)，第一个闭包是 AppMe.legalPrivacyVersion()（D10-1033 ②：legal 优先）。
  W2 release BuildVariant 的 walletContract() 仍恒 return null（劳务不可用；实名真实接口不经它，D10-1002 前提）。
  R1 RealNameRemote.ets 含 recordConsent / submitRealname / id_verification / realname_sheet，且两个请求都接 owner 与 sendAllowed。
  N1 RealNameController.ets、RealNameRemote.ets 不含 hilog / console / d.log（姓名、身份证号不打印）。
  N2 视图层（features/wallet/**、entry 的 WalletPages.ets）不引用 RealNameRemote / RealNamePort / submitRealname / recordConsent（只经控制器）。
  T1 core 的 List.test.ets 导入并调用 8 个 Realname 套件。

用法：check_realname.py [--root <树>]   检查（缺省本仓库；有违反退出 1）
      check_realname.py --self-test     合成参考件应 0 违反；再逐个打错误实现，每个必须命中指定项
"""
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile

LOCK = 'contract.lock'
VECTORS = 'specs/realname-submit-vectors.json'
APP_WALLET = 'entry/src/main/ets/wallet/AppWallet.ets'
RELEASE_VARIANT = 'entry/src/release/ets/variant/BuildVariant.ets'
CONTROLLER = 'common/core/src/main/ets/wallet/RealNameController.ets'
REMOTE = 'common/core/src/main/ets/wallet/RealNameRemote.ets'
VIEW_TREE = 'features/wallet/src/main/ets'
PAGES = 'entry/src/main/ets/wallet/WalletPages.ets'
CORE_LIST = 'common/core/src/test/List.test.ets'

# iOS 75eb599 原件（安卓副本同值）；iOS 合入前与 rebate-ios main 再核，以 main 为准同步。
VECTOR_SHA256 = '2b3f872080677d36e3965bf57a5af30c9e7e39c5c1212ff34e6b30ce22b85cf9'
VECTOR_LINES = 41
SUITES = ('RealnameVector', 'RealnameRequest', 'RealnameBusy', 'RealnameMatrix', 'RealnameFlow', 'RealnameWiring',
          'RealnameFundsNoFundWrite', 'RealnamePrivacy')
REMOTE_MARKS = ("'recordConsent'", "'submitRealname'", "'id_verification'", "'realname_sheet'")
VIEW_FORBIDDEN = re.compile(r'\b(RealNameRemote|RealNamePort|submitRealname|recordConsent)\b')
LOG_FORBIDDEN = re.compile(r'\b(hilog|console)\b|\.log\s*\(')


class Expect:
    def __init__(self, vector_sha, vector_lines):
        self.vector_sha = vector_sha
        self.vector_lines = vector_lines


REAL = Expect(VECTOR_SHA256, VECTOR_LINES)


def strip_comments(text):
    """注释换成空格，字符串保留（偏移不变）。"""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif c == '/' and i + 1 < n and text[i + 1] == '*':
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if text[k] != '\n':
                    out[k] = ' '
            i = j
        elif c in '\'"`':
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == '\\' else 1
            i = j + 1
        else:
            i += 1
    return ''.join(out)


def read(root, rel):
    with open(os.path.join(root, rel), encoding='utf-8') as f:
        return f.read()


def read_or_none(root, rel, v, rule):
    try:
        return read(root, rel)
    except (OSError, UnicodeDecodeError):
        v.append('%s 读不了 %s' % (rule, rel))
        return None


def check_vectors(root, expect, v):
    try:
        with open(os.path.join(root, VECTORS), 'rb') as f:
            data = f.read()
    except OSError:
        v.append('V1 缺 ' + VECTORS)
        return None
    if hashlib.sha256(data).hexdigest() != expect.vector_sha or data.count(b'\n') != expect.vector_lines:
        v.append('V1 %s 与 iOS 原件不一致（应 %d 行、sha256 %s）' % (VECTORS, expect.vector_lines, expect.vector_sha))
    try:
        return json.loads(data.decode('utf-8')).get('contractCommit')
    except ValueError:
        v.append('V1 %s 不是合法 JSON' % VECTORS)
        return None


def check_contract(root, vec_commit, v):
    try:
        lock_commit = json.loads(read(root, LOCK))['rebate_platform']['commit']
    except (OSError, ValueError, KeyError, TypeError):
        v.append('C1 读不了 contract.lock 的 rebate_platform.commit')
        return
    if vec_commit != lock_commit:
        v.append('C1 向量 contractCommit（%s）与 contract.lock（%s）不一致' % (vec_commit, lock_commit))


def check_wiring(root, v):
    src = read_or_none(root, APP_WALLET, v, 'W1')
    if src is not None:
        code = strip_comments(src)
        hits = [m.start() for m in re.finditer(r'd\.realname\s*=\s*new\s+RealNameRemote\s*\(', code)]
        if len(hits) != 1:
            v.append('W1 AppWallet 应恰一处 d.realname = new RealNameRemote(…)，现 %d 处' % len(hits))
        else:
            head = code[hits[0]:hits[0] + 200]
            first = re.search(r'\(\s*this\.api\s*,\s*\(\)[^=]*=>\s*AppMe\.legalPrivacyVersion\(\)', head)
            if first is None:
                v.append('W1 RealNameRemote 的第一个闭包应是 AppMe.legalPrivacyVersion()（legal 优先，D10-1033 ②）')
    release = read_or_none(root, RELEASE_VARIANT, v, 'W2')
    if release is not None:
        code = strip_comments(release)
        if re.search(r'static\s+walletContract\(\)\s*:\s*WalletContractPort\s*\|\s*null\s*\{\s*return\s+null\s*;\s*\}', code) is None:
            v.append('W2 release BuildVariant.walletContract() 应恒 return null（劳务不可用，D10-1002 前提）')


def check_remote(root, v):
    src = read_or_none(root, REMOTE, v, 'R1')
    if src is None:
        return
    code = strip_comments(src)
    for mark in REMOTE_MARKS:
        if mark not in code:
            v.append('R1 RealNameRemote.ets 缺 ' + mark)
    if code.count('request.owner = owner') != 2 or code.count('request.sendAllowed = sendAllowed') != 2:
        v.append('R1 RealNameRemote 的两个请求都要接 owner 与 sendAllowed')


def check_logging(root, v):
    for rel in (CONTROLLER, REMOTE):
        src = read_or_none(root, rel, v, 'N1')
        if src is None:
            continue
        for m in LOG_FORBIDDEN.finditer(strip_comments(src)):
            line = src.count('\n', 0, m.start()) + 1
            v.append('N1 %s:%d 不许打印（%s）' % (rel, line, m.group(0).strip()))


def view_files(root):
    out = [PAGES]
    base = os.path.join(root, VIEW_TREE)
    for d, _, files in os.walk(base):
        for f in files:
            if f.endswith('.ets'):
                out.append(os.path.relpath(os.path.join(d, f), root))
    return sorted(out)


def check_views(root, v):
    for rel in view_files(root):
        src = read_or_none(root, rel, v, 'N2')
        if src is None:
            continue
        m = VIEW_FORBIDDEN.search(strip_comments(src))
        if m is not None:
            v.append('N2 %s 不许引用 %s（视图层只经 RealNameController）' % (rel, m.group(0)))


def check_list(root, v):
    src = read_or_none(root, CORE_LIST, v, 'T1')
    if src is None:
        return
    code = strip_comments(src)
    for suite in SUITES:
        fn = suite[0].lower() + suite[1:] + 'Test'
        if re.search(r"import\s+%s\s+from\s+'\./%s\.test'" % (fn, suite), code) is None or re.search(r'\b%s\(\)' % fn, code) is None:
            v.append('T1 List.test.ets 没有登记 ' + suite)


def check(root, expect=REAL):
    v = []
    vec_commit = check_vectors(root, expect, v)
    check_contract(root, vec_commit, v)
    check_wiring(root, v)
    check_remote(root, v)
    check_logging(root, v)
    check_views(root, v)
    check_list(root, v)
    return v


# ------------------------------------------------------------------ 自测：合成参考件 + 错误实现

REF_COMMIT = 'a' * 40
REF_VECTORS = json.dumps({'version': 1, 'contractCommit': REF_COMMIT}) + '\n'
REF_APP_WALLET = """export class AppWallet {
  deps(): WalletDeps {
    d.contract = BuildVariant.walletContract();
    d.realname = new RealNameRemote(this.api, (): number | null => AppMe.legalPrivacyVersion(), (): number | null => 1, d.clock);
    return d;
  }
}
"""
REF_RELEASE = """export class BuildVariant {
  /** 注释里的 return 1 不算。 */
  static walletContract(): WalletContractPort | null {
    return null;
  }
}
"""
REF_REMOTE = """export class RealNameRemote {
  recordConsent(owner: () => boolean, sendAllowed: () => boolean): Promise<ApiResult> {
    body['type'] = 'id_verification';
    body['channel'] = 'realname_sheet';
    const request: ApiRequest = new ApiRequest('recordConsent', {}, '', JSON.stringify(body));
    request.owner = owner;
    request.sendAllowed = sendAllowed;
    return this.api.request(request);
  }

  submitRealname(name: string, idNo: string): Promise<ApiResult> {
    const request: ApiRequest = new ApiRequest('submitRealname', {}, '', JSON.stringify(body));
    request.owner = owner;
    request.sendAllowed = sendAllowed;
    return this.api.request(request);
  }
}
"""
REF_CONTROLLER = """// 注释里的 hilog 不算。
export class RealNameController {
  agreeAndSubmit(): boolean {
    return true;
  }
}
"""
REF_VIEW = """// 视图层只调 RealNameController。
struct RealNameView {
  build() {
    Text(this.config.controller.canSubmit ? 'a' : 'b')
  }
}
"""
REF_LIST = '\n'.join("import %s%sTest from './%s.test';" % (s[0].lower(), s[1:], s) for s in SUITES) + \
    '\nexport default function testsuite() {\n' + \
    '\n'.join('  %s%sTest();' % (s[0].lower(), s[1:]) for s in SUITES) + '\n}\n'
REF_FILES = {
    LOCK: json.dumps({'rebate_platform': {'repo': '../rebate-platform', 'commit': REF_COMMIT}}, indent=2) + '\n',
    VECTORS: REF_VECTORS,
    APP_WALLET: REF_APP_WALLET,
    RELEASE_VARIANT: REF_RELEASE,
    REMOTE: REF_REMOTE,
    CONTROLLER: REF_CONTROLLER,
    VIEW_TREE + '/RealNameView.ets': REF_VIEW,
    PAGES: REF_VIEW,
    CORE_LIST: REF_LIST,
}

# (名字, 文件, 旧, 新, 必须命中的规则)
MUTANTS = (
    ('向量被改', VECTORS, '"version": 1', '"version": 2', 'V1'),
    ('向量 contractCommit 与锁不符', LOCK, REF_COMMIT, 'b' * 40, 'C1'),
    ('AppWallet 没接真实接口', APP_WALLET, 'd.realname = new RealNameRemote(', 'const unused = (', 'W1'),
    ('AppWallet 接了两处', APP_WALLET, '    return d;\n', '    d.realname = new RealNameRemote(this.api, a, b);\n    return d;\n', 'W1'),
    ('回落版本排在前面', APP_WALLET, 'AppMe.legalPrivacyVersion()', 'AppMe.other()', 'W1'),
    ('Release walletContract 接真实实现（劳务变可用）', RELEASE_VARIANT, 'return null;', 'return new RemoteWallet();', 'W2'),
    ('RealNameRemote 缺同意上报', REMOTE, "'recordConsent'", "'someOtherOp'", 'R1'),
    ('channel 写错', REMOTE, "'realname_sheet'", "'realname_page'", 'R1'),
    ('提交不接发送闸门', REMOTE, "    request.sendAllowed = sendAllowed;\n    return this.api.request(request);\n  }\n}\n",
     "    return this.api.request(request);\n  }\n}\n", 'R1'),
    ('RealNameRemote 打日志', REMOTE, '    return this.api.request(request);\n  }\n\n', "    hilog.info(0, 'x', '%{public}s', name);\n    return this.api.request(request);\n  }\n\n", 'N1'),
    ('RealNameController console', CONTROLLER, '    return true;\n', '    console.info(idNo);\n    return true;\n', 'N1'),
    ('RealNameController 走 d.log', CONTROLLER, '    return true;\n', "    this.d.log('x');\n    return true;\n", 'N1'),
    ('视图层直接调接口', VIEW_TREE + '/RealNameView.ets', "Text(this.config.controller.canSubmit ? 'a' : 'b')",
     "Text(this.port.submitRealname ? 'a' : 'b')", 'N2'),
    ('WalletPages 引用 RealNameRemote', PAGES, 'struct RealNameView {', 'import { RealNameRemote } from "core";\nstruct RealNameView {', 'N2'),
    ('List 少登记一个套件', CORE_LIST, '  realnameFlowTest();\n', '', 'T1'),
    ('List 少导入', CORE_LIST, "import realnamePrivacyTest from './RealnamePrivacy.test';\n", '', 'T1'),
)


def write_tree(base, files):
    for rel, text in files.items():
        p = os.path.join(base, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w', encoding='utf-8') as f:
            f.write(text)


def reference_expect(base):
    with open(os.path.join(base, VECTORS), 'rb') as f:
        data = f.read()
    return Expect(hashlib.sha256(data).hexdigest(), data.count(b'\n'))


def self_test():
    bad = 0
    with tempfile.TemporaryDirectory(prefix='realname-host-') as tmp:
        ref = os.path.join(tmp, 'ref')
        write_tree(ref, REF_FILES)
        expect = reference_expect(ref)
        clean = check(ref, expect)
        if clean:
            bad += 1
            print('参考件应 0 违反：')
            for line in clean:
                print('  ' + line)
        for name, rel, old, new, rule in MUTANTS:
            tree = os.path.join(tmp, 'mut')
            shutil.rmtree(tree, ignore_errors=True)
            shutil.copytree(ref, tree)
            text = REF_FILES[rel]
            if old not in text:
                bad += 1
                print('自测样例失效（没有要替换的文本）：' + name)
                continue
            write_tree(tree, {rel: text.replace(old, new, 1)})
            hits = check(tree, expect)
            if not any(h.startswith(rule + ' ') for h in hits):
                bad += 1
                print('没拦下：%s（应命中 %s，实得 %s）' % (name, rule, hits))
    print('check_realname --self-test：%d 个错误实现，%s' % (len(MUTANTS), '全部拦下' if bad == 0 else '%d 处失败' % bad))
    return 1 if bad else 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
    if '--root' in argv:
        root = argv[argv.index('--root') + 1]
    violations = check(root)
    if violations:
        print('realname 宿主检查：%d 处违反' % len(violations))
        for line in violations:
            print('  ' + line)
        return 1
    print('realname 宿主检查：通过（向量 / 锁 / 接线 / 不打印 / 视图层 / 登记）')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
