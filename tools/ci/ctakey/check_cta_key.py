#!/usr/bin/env python3
"""FU-X-CTA-KEY-DRIFT-harmony 测试作者 v1：购买按钮 cta 文案键兜底的宿主检查（C 组，brief-harmony §3 C；D10-856 / 857 / 861）。

entry 没有本机单测，五个调用点用的文案函数只能在宿主上核；锁与快照也在这里核（本机单测读不了 contract.lock）。
按钮文字的规则由 designsystem 的 CtaKeyVector.test.ets 逐条跑向量，详情可买判定由 core 的 CtaKeyDetail.test.ets 守。

  L1 contract.lock 的 rebate_platform.commit 是 a89c1ec3a7f4…（D10-857），且等于 specs/cta-key-vectors.json 的 contractCommit。
  L2 四个同名快照（enums/admin、error-codes、openapi、texts.default）的 sha256 等于 iOS 升锁提交 c748676 的值（三端同一锁，逐字节相同）。
  V1 specs/cta-key-vectors.json 与 iOS 原件逐字节相同：95 行、sha256 d93b2905…（D10-861：三端照抄，鸿蒙差异在测试里映射）。
  W1 产品代码里 ProductCardMapper.fromCard / fromCardWithStatus 的调用点恰为登记的五个文件七处（搜索两处、详情一处、剪贴板弹层两处、
     首页一处、AI 卡一处），每处的文案参数都解析到「text(key) 只 return SearchDraftTexts.text(key)」的类：
     SearchView / ProductDetailView 的 this.config.texts 来自 AppSearch 里唯一的 new SearchPageConfig / new ProductPageConfig(…, this.texts)，
     this.texts 是 AppSearchTexts（两个配置类的 texts 是 readonly、只在构造器里赋值）；AppClipboard / AppHome / AppAgent 用本文件的 CardTexts。
  W2 SearchDraftTexts.text 先读契约字典：return DefaultTexts.text(key) ?? …（中间只许 DRAFTS.get / DefaultTexts.fallback）?? ''；
     草稿表 DRAFTS 只由 build() 用字面量 m.set 建、别处不改，且没有 btn.* / cta.* 键、没有向量里的任何 cta 键与 rebate_login_to_view；
     契约 fallbacks 也没有这些键。于是对 cta 键，五个调用点的 texts 等同向量的 contract 模式（A 组跑的就是生产接线的行为）。
  W3 ProductCardMapper.ets 的默认诊断（R3）：至少一处 hilog 调用；每处都是 info / warn / error、恰好 4 个参数、格式串只有一个
     %{public}s、最后一个参数是单个标识符（只格式化 text_key，不拼商品、用户、链接、店铺、价格）；fromCard 与 fromCardWithStatus 的
     最后一个参数都是 (key: string) => void 且有默认值，默认值会走到 hilog（直接调，或经本文件里含 hilog 的函数 / 方法 / 常量）。
  W4 产品代码的调用点都不传第 6 个参数（onCtaFallback）：生产一律走默认诊断，不被换成空函数。
  R1 两个新套件已登记：designsystem 的 List.test.ets 导入并调用 CtaKeyVector.test，core 的 List.test.ets 导入并调用 CtaKeyDetail.test。

用法：check_cta_key.py [--root <树>]   检查（缺省本仓库；有违反退出 1）
      check_cta_key.py --self-test     合成参考件应 0 违反；再逐个打错误实现，每个必须命中指定项
"""
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile

LOCK = 'contract.lock'
VECTORS = 'specs/cta-key-vectors.json'
TEXTS = 'contracts/snapshot/contracts/texts.default.json'
MAPPER = 'common/designsystem/src/main/ets/format/ProductCardMapper.ets'
DRAFT_TEXTS = 'entry/src/main/ets/search/SearchDraftTexts.ets'
APP_SEARCH = 'entry/src/main/ets/search/AppSearch.ets'
SEARCH_VIEW = 'features/search/src/main/ets/SearchView.ets'
DETAIL_VIEW = 'features/product/src/main/ets/ProductDetailView.ets'
APP_CLIPBOARD = 'entry/src/main/ets/clipboard/AppClipboard.ets'
APP_HOME = 'entry/src/main/ets/home/AppHome.ets'
APP_AGENT = 'entry/src/main/ets/agent/AppAgent.ets'
DS_LIST = 'common/designsystem/src/test/List.test.ets'
CORE_LIST = 'common/core/src/test/List.test.ets'
DS_SUITE = 'common/designsystem/src/test/CtaKeyVector.test.ets'
CORE_SUITE = 'common/core/src/test/CtaKeyDetail.test.ets'

# D10-857：三端统一锁到 rebate-platform a89c1ec3a（CT-26t #2450）。
LOCK_COMMIT = 'a89c1ec3a7f4de0b069742af909eba6545358ea3'
# iOS 原件（worktrees/native/FU-X-CTA-KEY-DRIFT-ios/specs/cta-key-vectors.json；安卓副本同值）。
VECTOR_SHA256 = 'd93b2905983bb07a8cca624f3a8af2a9a9b7220e49f34d43886270cb32f4bc40'
VECTOR_LINES = 95
# iOS HomePageApiLockTests.sameNameHashes（tests-ios-handback §5 T2，c748676 实写）；路径与哈希分两行写（gitleaks 误报）。
SAME_NAME = (
    ('contracts/snapshot/contracts/enums/admin.json',
     '15169659cbc717065f12d3c17893972a473b47d6271832e5c4acc026ea00a8ca'),
    ('contracts/snapshot/contracts/error-codes.json',
     '954c14c589f9681d66fa5c8518ad482ee892638a1b6f2adfc2cd8c801dcb2d8f'),
    ('contracts/snapshot/contracts/openapi.json',
     '4b658d0079bc173d5bed9081b122c202032b49247dc4afd45db0d2f2c0787214'),
    ('contracts/snapshot/contracts/texts.default.json',
     '3ddce957d12e696d6276fd676cd0e78a719d337615f8d99d0d511b551d3022db'),
)

# W1：登记的调用点（文件 → 调用次数）。新增调用点必须先核它的文案函数对 cta 键等同 contract 模式，再登记到这里。
CALL_SITES = {
    SEARCH_VIEW: 2,
    DETAIL_VIEW: 1,
    APP_CLIPBOARD: 2,
    APP_HOME: 1,
    APP_AGENT: 1,
}
# 用 this.config.texts 的两个页面 → 它们的配置类（配置只在 AppSearch 里构造）。
CONFIG_PAGES = {SEARCH_VIEW: 'SearchPageConfig', DETAIL_VIEW: 'ProductPageConfig'}
SCAN_TOPS = ('common', 'entry', 'features')
SRC_SETS = ('main', 'release', 'staging')
MAX_ARGS = 5
HILOG_LEVELS = ('info', 'warn', 'error')
ALWAYS_CTA = ('btn.buy', 'rebate_login_to_view')
CTA_PREFIXES = ('btn.', 'cta.')


class Expect:
    def __init__(self, vector_sha, vector_lines, snapshots):
        self.vector_sha = vector_sha
        self.vector_lines = vector_lines
        self.snapshots = snapshots


REAL = Expect(VECTOR_SHA256, VECTOR_LINES, SAME_NAME)


# ------------------------------------------------------------------ 词法（同 lockph：偏移不变）

def scan(text):
    """返回 (code, masked)：code 把注释换成空格；masked 另把字符串内容换成空格（括号配对用）。偏移与原文一致。"""
    code = list(text)
    masked = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                code[k] = masked[k] = ' '
            i = j
        elif c == '/' and i + 1 < n and text[i + 1] == '*':
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if text[k] != '\n':
                    code[k] = masked[k] = ' '
            i = j
        elif c in '\'"`':
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == '\\' else 1
            for k in range(i + 1, min(j, n)):
                if text[k] != '\n':
                    masked[k] = ' '
            i = j + 1
        else:
            i += 1
    return ''.join(code), ''.join(masked)


def match_close(masked, open_idx, o='(', c=')'):
    depth = 0
    for k in range(open_idx, len(masked)):
        if masked[k] == o:
            depth += 1
        elif masked[k] == c:
            depth -= 1
            if depth == 0:
                return k
    return -1


def split_top(code, masked, open_idx, generics=False):
    """open_idx 是 '(' 的位置；按顶层逗号切参数，返回 (参数文本列表, 右括号位置)。generics=True 时 <…> 也算一层（形参列表用）。"""
    close = match_close(masked, open_idx)
    if close < 0:
        return None, -1
    args, depth, start = [], 0, open_idx + 1
    for k in range(open_idx + 1, close):
        ch = masked[k]
        if ch in '([{' or (generics and ch == '<'):
            depth += 1
        elif ch in ')]}' or (generics and ch == '>' and masked[k - 1] != '='):
            depth -= 1
        elif ch == ',' and depth == 0:
            args.append(code[start:k].strip())
            start = k + 1
    tail = code[start:close].strip()
    if tail:
        args.append(tail)
    return args, close


def norm(s):
    return re.sub(r'\s+', ' ', s).strip()


def read(root, rel):
    with open(os.path.join(root, rel), encoding='utf-8') as fh:
        return fh.read()


def sha256(root, rel):
    with open(os.path.join(root, rel), 'rb') as fh:
        return hashlib.sha256(fh.read()).hexdigest()


class Source:
    def __init__(self, root, rel):
        self.rel = rel
        self.text = read(root, rel)
        self.code, self.masked = scan(self.text)

    def block(self, open_brace):
        close = match_close(self.masked, open_brace, '{', '}')
        return None if close < 0 else self.code[open_brace + 1:close]


def class_body(src, name):
    m = re.search(r'\bclass\s+' + re.escape(name) + r'\b[^{]*\{', src.masked)
    if not m:
        return None, None
    open_brace = m.end() - 1
    close = match_close(src.masked, open_brace, '{', '}')
    if close < 0:
        return None, None
    return src.code[open_brace + 1:close], src.masked[open_brace + 1:close]


def delegates_text(src, cls):
    """类 cls 的 text(p: string): string 只 return SearchDraftTexts.text(p)，且本文件从 SearchDraftTexts 导入。"""
    body, masked = class_body(src, cls)
    if body is None:
        return '找不到类 ' + cls
    m = re.search(r'\btext\s*\(\s*(\w+)\s*:\s*string\s*\)\s*:\s*string\s*\{', masked)
    if not m:
        return cls + ' 没有 text(key: string): string'
    close = match_close(masked, m.end() - 1, '{', '}')
    inner = norm(body[m.end():close])
    want = 'return SearchDraftTexts.text(' + m.group(1) + ');'
    if inner != want:
        return cls + '.text 不是只「' + want + '」（现为「' + inner + '」）'
    if not re.search(r"import\s*\{[^}]*\bSearchDraftTexts\b[^}]*\}\s*from\s*'(?:\.\./search|\.)/SearchDraftTexts'", src.code):
        return src.rel + " 没从 entry 的 SearchDraftTexts（'../search/SearchDraftTexts' 或 './SearchDraftTexts'）导入"
    return None


def field_class(src, name):
    """this.<name> 的声明「name: X = new X();」→ X；没有或两边不一致返回 None。"""
    found = re.findall(r'\b' + re.escape(name) + r'\s*:\s*(\w+)\s*=\s*new\s+(\w+)\s*\(\s*\)\s*;', src.code)
    if len(found) != 1 or found[0][0] != found[0][1]:
        return None
    return found[0][0]


def product_files(root):
    out = []
    for top in SCAN_TOPS:
        base = os.path.join(root, top)
        for dirpath, dirnames, names in os.walk(base):
            dirnames.sort()
            rel_dir = os.path.relpath(dirpath, root).replace(os.sep, '/')
            parts = rel_dir.split('/')
            if 'generated' in parts[:2] or 'oh_modules' in parts or 'build' in parts:
                continue
            if 'src' not in parts:
                continue
            at = parts.index('src')
            if at + 1 >= len(parts) or parts[at + 1] not in SRC_SETS:
                continue
            for name in sorted(names):
                if name.endswith('.ets'):
                    out.append(rel_dir + '/' + name)
    return out


def mapper_calls(src):
    """ProductCardMapper.fromCard / fromCardWithStatus 的调用：[(方法名, 参数列表)]。"""
    out = []
    for m in re.finditer(r'\bProductCardMapper\s*\.\s*(fromCardWithStatus|fromCard)\s*\(', src.masked):
        args, _close = split_top(src.code, src.masked, m.end() - 1)
        out.append((m.group(1), args or []))
    return out


def config_wiring(root, sources, page_rel):
    """this.config.texts：页面的配置类只在 AppSearch 里用 this.texts 构造，this.texts 是委托 SearchDraftTexts 的 AppSearchTexts。"""
    cfg = CONFIG_PAGES[page_rel]
    page = sources[page_rel]
    body, masked = class_body(page, cfg)
    if body is None:
        return page_rel + ' 里找不到配置类 ' + cfg
    if not re.search(r'\breadonly\s+texts\s*:', body):
        return cfg + '.texts 不是 readonly'
    m = re.search(r'\bconstructor\s*\(', masked)
    if not m:
        return cfg + ' 没有构造器'
    params, close = split_top(body, masked, m.end() - 1, generics=True)
    if not params or len(params) < 2:
        return cfg + ' 构造器参数不足两个'
    pname = params[1].split(':')[0].strip()
    brace = masked.find('{', close)
    ctor = body[brace + 1:match_close(masked, brace, '{', '}')]
    if not re.search(r'\bthis\.texts\s*=\s*' + re.escape(pname) + r'\s*;', ctor):
        return cfg + ' 构造器没把第二个参数赋给 this.texts'
    news = []
    for rel, src in sources.items():
        for nm in re.finditer(r'\bnew\s+' + cfg + r'\s*\(', src.masked):
            args, _c = split_top(src.code, src.masked, nm.end() - 1)
            news.append((rel, args or []))
    if len(news) != 1 or news[0][0] != APP_SEARCH:
        return 'new ' + cfg + '( 应只在 ' + APP_SEARCH + ' 出现一次（现为 ' + repr([r for r, _a in news]) + '）'
    args = news[0][1]
    if len(args) < 2 or args[1] != 'this.texts':
        return APP_SEARCH + ' 的 new ' + cfg + '( 第二个参数不是 this.texts（现为 ' + repr(args) + '）'
    app = sources[APP_SEARCH]
    cls = field_class(app, 'texts')
    if cls is None:
        return APP_SEARCH + ' 的 texts 字段不是「texts: X = new X();」'
    why = delegates_text(app, cls)
    return None if why is None else APP_SEARCH + '：' + why


def vector_cta_keys(root):
    try:
        data = json.loads(read(root, VECTORS))
    except (OSError, ValueError):
        return set()
    keys = set()
    cards = [data.get('baseCard') or {}] + [c.get('card') or {} for c in data.get('cases', [])]
    for card in cards:
        cta = card.get('cta')
        if isinstance(cta, dict) and isinstance(cta.get('text_key'), str) and cta['text_key']:
            keys.add(cta['text_key'])
    return keys


def is_cta_like(key, cta_keys):
    return key in cta_keys or key.startswith(CTA_PREFIXES)


def literal(text):
    """单引号字符串字面量 → 值（只认 \\' 与 \\\\ 两种转义）。"""
    return text[1:-1].replace("\\'", "'").replace('\\\\', '\\')


def draft_keys(src):
    """DRAFTS = SearchDraftTexts.build()；build() 只许 const m = new Map、m.set('k', 'v')、return m。返回 (键列表, 问题)。"""
    if not re.search(r'\bstatic\s+readonly\s+DRAFTS\s*:\s*Map\s*<\s*string\s*,\s*string\s*>\s*=\s*SearchDraftTexts\.build\(\)\s*;',
                     src.code):
        return [], 'DRAFTS 不是「static readonly DRAFTS: Map<string, string> = SearchDraftTexts.build();」'
    m = re.search(r'\bstatic\s+build\s*\(\s*\)\s*:\s*Map\s*<\s*string\s*,\s*string\s*>\s*\{', src.masked)
    if not m:
        return [], '找不到 private static build(): Map<string, string>'
    body = src.block(m.end() - 1)
    lit = r"'(?:[^'\\\n]|\\.)*'"
    stmt = re.compile(r"\s*(?:const\s+(\w+)\s*:\s*Map\s*<\s*string\s*,\s*string\s*>\s*=\s*new\s+Map\s*<\s*string\s*,\s*string\s*>\s*\(\s*\)\s*;"
                      r"|(\w+)\.set\(\s*(" + lit + r")\s*,\s*(" + lit + r")\s*\)\s*;"
                      r"|return\s+(\w+)\s*;)")
    keys, pos, var = [], 0, None
    while pos < len(body):
        if not body[pos:].strip():
            break
        s = stmt.match(body, pos)
        if not s:
            return keys, 'build() 有解析不了的写法：「' + norm(body[pos:pos + 80]) + '」'
        if s.group(1):
            var = s.group(1)
        elif s.group(2):
            if s.group(2) != var:
                return keys, 'build() 往别的变量 set：' + s.group(2)
            keys.append(literal(s.group(3)))
        pos = s.end()
    return keys, None


def check_w2(root, sources, cta_keys, v):
    src = sources.get(DRAFT_TEXTS)
    if src is None:
        v.append('W2 缺 ' + DRAFT_TEXTS)
        return
    m = re.search(r'\bstatic\s+text\s*\(\s*(\w+)\s*:\s*string\s*\)\s*:\s*string\s*\{', src.masked)
    if not m:
        v.append('W2 SearchDraftTexts 没有 static text(key: string): string')
    else:
        p = m.group(1)
        body = norm(src.block(m.end() - 1) or '')
        rm = re.fullmatch(r'return (.+);', body)
        chain = [norm(x) for x in rm.group(1).split('??')] if rm else []
        allowed = {'SearchDraftTexts.DRAFTS.get(' + p + ')', 'DefaultTexts.fallback(' + p + ')'}
        if (len(chain) < 2 or chain[0] != 'DefaultTexts.text(' + p + ')' or chain[-1] != "''"
                or any(x not in allowed for x in chain[1:-1])):
            v.append('W2 SearchDraftTexts.text 必须先读契约字典：return DefaultTexts.text(' + p + ') ?? …（中间只许 DRAFTS.get / '
                     'DefaultTexts.fallback）?? \'\'（现为「' + body + '」）')
    keys, why = draft_keys(src)
    if why:
        v.append('W2 ' + why)
    bad = sorted(k for k in keys if is_cta_like(k, cta_keys))
    if bad:
        v.append('W2 草稿表有 cta 键（会盖过向量 contract 模式的取法）：' + ', '.join(bad))
    for rel, other in sorted(sources.items()):
        # 只管 SearchDraftTexts 这张表（别的 *DraftTexts 有自己的 DRAFTS，与 cta 无关）：本文件里任何 DRAFTS.set / delete / clear
        # 都在 build() 之外（build() 只许 m.set），别的文件看 SearchDraftTexts.DRAFTS.set / delete / clear。
        own = r'\bDRAFTS' if rel == DRAFT_TEXTS else r'\bSearchDraftTexts\s*\.\s*DRAFTS'
        if re.search(own + r'\s*\.\s*(?:set|delete|clear)\s*\(', other.code):
            v.append('W2 ' + rel + ' 在 build() 之外改 SearchDraftTexts.DRAFTS')
    try:
        fallbacks = json.loads(read(root, TEXTS)).get('fallbacks') or {}
    except (OSError, ValueError):
        fallbacks = {}
        v.append('W2 读不了 ' + TEXTS)
    badf = sorted(k for k in fallbacks if is_cta_like(k, cta_keys))
    if badf:
        v.append('W2 契约 fallbacks 有 cta 键（SearchDraftTexts.text 会取到它）：' + ', '.join(badf))


def string_consts(src):
    out = {}
    for m in re.finditer(r"\b(?:const|static\s+readonly)\s+(\w+)\s*:\s*string\s*=\s*('(?:[^'\\\n]|\\.)*')\s*;", src.code):
        out[m.group(1)] = literal(m.group(2))
    return out


def hilog_calls(src):
    out = []
    for m in re.finditer(r'\bhilog\s*\.\s*(\w+)\s*\(', src.masked):
        args, _c = split_top(src.code, src.masked, m.end() - 1)
        out.append((m.start(), m.group(1), args or []))
    return out


def loggers(src):
    """本文件里含 hilog 调用的函数 / 方法名，以及初值会走到它们（或直接含 hilog）的常量名。"""
    names = set()
    for m in re.finditer(r'(?:\bfunction\s+(\w+)|^\s*(?:(?:private|public|protected|static|readonly)\s+)*(\w+))\s*\(([^()]*)\)'
                         r'\s*(?::\s*[\w<>\[\]| ,]+)?\s*\{', src.masked, re.M):
        name = m.group(1) or m.group(2)
        if name in ('if', 'for', 'while', 'switch', 'catch', 'constructor'):
            continue
        body = src.block(m.end() - 1) or ''
        if re.search(r'\bhilog\s*\.', body):
            names.add(name)
    for m in re.finditer(r'\b(?:const|static\s+readonly)\s+(\w+)\s*:\s*\(\s*\w+\s*:\s*string\s*\)\s*=>\s*void\s*=', src.masked):
        end = src.masked.find(';', m.end())
        init = src.code[m.end():end if end > 0 else len(src.code)]
        if reaches(init, names):
            names.add(m.group(1))
    return names


def reaches(expr, names):
    if re.search(r'\bhilog\s*\.', expr):
        return True
    for name in names:
        if re.search(r'(?:^|[^\w])' + re.escape(name) + r'\s*\(', expr) or re.fullmatch(r'\s*(?:\w+\.)*' + re.escape(name) + r'\s*', expr):
            return True
    return False


def check_w3(sources, v):
    src = sources.get(MAPPER)
    if src is None:
        v.append('W3 缺 ' + MAPPER)
        return
    consts = string_consts(src)
    calls = hilog_calls(src)
    if not calls:
        v.append('W3 ProductCardMapper.ets 没有 hilog 调用（缺键的默认诊断没有写出来）')
    for start, level, args in calls:
        line = src.text.count('\n', 0, start) + 1
        where = 'W3 ProductCardMapper.ets:%d hilog.%s' % (line, level)
        if level not in HILOG_LEVELS:
            v.append(where + '：级别只许 info / warn / error（Release 也要能看到）')
        if len(args) != 4:
            v.append(where + '：应恰好 4 个参数（域、标签、格式串、text_key），现为 %d 个' % len(args))
            continue
        fmt_arg = args[2]
        if re.fullmatch(r"'(?:[^'\\\n]|\\.)*'", fmt_arg):
            fmt = literal(fmt_arg)
        elif fmt_arg in consts:
            fmt = consts[fmt_arg]
        else:
            v.append(where + '：格式串不是字面量或本文件的字符串常量（' + fmt_arg + '）')
            continue
        specs = re.findall(r'%(\{\w+\})?[a-zA-Z]', fmt)
        if len(specs) != 1 or specs[0] != '{public}' or not re.search(r'%\{public\}s', fmt):
            v.append(where + '：格式串应只有一个 %{public}s（现为「' + fmt + '」）')
        if not re.fullmatch(r'[A-Za-z_]\w*', args[3]):
            v.append(where + '：最后一个参数应是单个标识符（text_key），现为「' + args[3] + '」')
    names = loggers(src)
    for method in ('fromCard', 'fromCardWithStatus'):
        m = re.search(r'\bstatic\s+' + method + r'\s*\(', src.masked)
        if not m:
            v.append('W3 找不到 static ' + method + '(')
            continue
        params, _close = split_top(src.code, src.masked, m.end() - 1, generics=True)
        last = params[-1] if params else ''
        pm = re.fullmatch(r'(\w+)\s*:\s*\(\s*\w+\s*:\s*string\s*\)\s*=>\s*void\s*=\s*(.+)', last, re.S)
        if not pm:
            v.append('W3 ' + method + ' 的最后一个参数应是「名字: (key: string) => void = 默认值」（现为「' + norm(last) + '」）')
            continue
        if not reaches(pm.group(2), names):
            v.append('W3 ' + method + ' 的默认诊断走不到 hilog（默认值「' + norm(pm.group(2)) + '」）')


def check(root, expect=REAL):
    v = []
    # L1
    try:
        lock_commit = json.loads(read(root, LOCK))['rebate_platform']['commit']
    except (OSError, ValueError, KeyError, TypeError):
        lock_commit = None
    try:
        vec_commit = json.loads(read(root, VECTORS)).get('contractCommit')
    except (OSError, ValueError, AttributeError):
        vec_commit = None
    if lock_commit != LOCK_COMMIT:
        v.append('L1 contract.lock 的 rebate_platform.commit 应为 %s（D10-857），现为 %s' % (LOCK_COMMIT, lock_commit))
    if vec_commit != lock_commit:
        v.append('L1 向量 contractCommit（%s）与 contract.lock（%s）不一致' % (vec_commit, lock_commit))
    # L2
    for rel, want in expect.snapshots:
        try:
            got = sha256(root, rel)
        except OSError:
            got = None
        if got != want:
            v.append('L2 %s 的 sha256 应等于 iOS 同名快照 %s…，现为 %s' % (rel, want[:12], got))
    # V1
    try:
        with open(os.path.join(root, VECTORS), 'rb') as fh:
            raw = fh.read()
        got_sha, got_lines = hashlib.sha256(raw).hexdigest(), raw.count(b'\n')
    except OSError:
        got_sha, got_lines = None, None
    if got_sha != expect.vector_sha or got_lines != expect.vector_lines:
        v.append('V1 %s 应与 iOS 原件逐字节相同（%d 行、sha256 %s…），现为 %s 行、%s' % (
            VECTORS, expect.vector_lines, expect.vector_sha[:12], got_lines, got_sha))
    # 读源码
    sources = {}
    for rel in product_files(root):
        try:
            sources[rel] = Source(root, rel)
        except (OSError, UnicodeDecodeError):
            v.append('W1 读不了 ' + rel)
    cta_keys = vector_cta_keys(root) | set(ALWAYS_CTA)
    # W1 / W4
    seen = {}
    for rel, src in sorted(sources.items()):
        if rel == MAPPER:
            continue
        for method, args in mapper_calls(src):
            seen[rel] = seen.get(rel, 0) + 1
            where = '%s 第 %d 处 %s' % (rel, seen[rel], method)
            if len(args) > MAX_ARGS:
                v.append('W4 ' + where + ' 传了 %d 个参数（第 6 个 onCtaFallback 不许在调用方覆盖）' % len(args))
            if rel not in CALL_SITES:
                v.append('W1 未登记的调用点：' + where + '（先核它的文案函数对 cta 键等同 contract 模式，再登记进 CALL_SITES）')
                continue
            texts_arg = norm(args[1]) if len(args) > 1 else ''
            why = None
            nm = re.fullmatch(r'new (\w+)\(\)', texts_arg)
            fm = re.fullmatch(r'this\.(\w+)', texts_arg)
            if nm:
                why = delegates_text(src, nm.group(1))
            elif texts_arg == 'this.config.texts' and rel in CONFIG_PAGES:
                why = config_wiring(root, sources, rel)
            elif fm and fm.group(1) != 'config':
                cls = field_class(src, fm.group(1))
                why = ('this.' + fm.group(1) + ' 的声明不是「' + fm.group(1) + ': X = new X();」') if cls is None \
                    else delegates_text(src, cls)
            else:
                why = '文案参数「' + texts_arg + '」解析不了'
            if why:
                v.append('W1 ' + where + '：' + why)
    for rel, want in sorted(CALL_SITES.items()):
        if seen.get(rel, 0) != want:
            v.append('W1 %s 应有 %d 处 ProductCardMapper 映射调用，现为 %d 处' % (rel, want, seen.get(rel, 0)))
    # W2 / W3
    check_w2(root, sources, cta_keys, v)
    check_w3(sources, v)
    # R1
    for lst, suite, test in ((DS_LIST, DS_SUITE, './CtaKeyVector.test'), (CORE_LIST, CORE_SUITE, './CtaKeyDetail.test')):
        if not os.path.isfile(os.path.join(root, suite)):
            v.append('R1 缺 ' + suite)
            continue
        if not re.search(r'\bexport\s+default\s+function\s+\w+\s*\(', scan(read(root, suite))[0]):
            v.append('R1 ' + suite + ' 没有 export default function')
        try:
            code = scan(read(root, lst))[0]
        except OSError:
            v.append('R1 缺 ' + lst)
            continue
        im = re.search(r"\bimport\s+(\w+)\s+from\s+'" + re.escape(test) + r"'\s*;", code)
        if not im or not re.search(r'(?:^|[^\w.])' + im.group(1) + r'\s*\(\s*\)\s*;', code[im.end():]):
            v.append('R1 ' + lst + ' 没有导入并调用 ' + test + '（套件不登记，Hypium 不跑）')
    return v


# ------------------------------------------------------------------ 自测：合成参考件 + 错误实现

REF_VECTORS = json.dumps({
    'version': 1, 'contractCommit': LOCK_COMMIT,
    'baseCard': {'platform': 'taobao', 'cta': {'text_key': 'btn.buy.rebate'}},
    'cases': [{'id': 'unknown.contract', 'card': {'cta': {'text_key': 'btn.buy.future_x'}}},
              {'id': 'unknown.other_prefix', 'card': {'cta': {'text_key': 'cta.next.buy'}}},
              {'id': 'unrenderable.other_placeholder', 'card': {'cta': {'text_key': 'platform_coming_soon'}}},
              {'id': 'missing.cta', 'card': {'cta': None}}],
}, ensure_ascii=False, indent=2) + '\n'

REFERENCE = {
    LOCK: json.dumps({'rebate_platform': {'repo': '../rebate-platform', 'commit': LOCK_COMMIT}}, indent=2) + '\n',
    VECTORS: REF_VECTORS,
    'contracts/snapshot/contracts/enums/admin.json': '{"values": ["system:payout"]}\n',
    'contracts/snapshot/contracts/error-codes.json': '{"codes": [30145, 30146]}\n',
    'contracts/snapshot/contracts/openapi.json': '{"paths": {}}\n',
    TEXTS: json.dumps({'version': 1, 'texts': {'btn.buy': '购买', 'btn.buy.rebate': '购买预估返 {amount}',
                                               'error.30141': '商品已下架'},
                       'fallbacks': {'error.50001': '服务暂时不可用'}}, ensure_ascii=False, indent=2) + '\n',
    DRAFT_TEXTS: """import { DefaultTexts } from 'generated';

/** 草稿表。 */
export class SearchDraftTexts {
  static readonly DRAFTS: Map<string, string> = SearchDraftTexts.build();

  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    // ---- 平台名
    m.set('platform.taobao', '淘宝');
    m.set('card.price_unavailable', '暂时查不到该商品价格');
    m.set('search.fallback.title', '看看{platform_name}的其他商品');
    return m;
  }

  /** 先取契约字典，再取草稿；缺键返回空串。 */
  static text(key: string): string {
    return DefaultTexts.text(key) ?? SearchDraftTexts.DRAFTS.get(key) ?? DefaultTexts.fallback(key) ?? '';
  }
}
""",
    APP_SEARCH: """import { SearchPageConfig, SearchTexts } from 'search';
import { ProductPageConfig, ProductTexts } from 'product';
import { SearchDraftTexts } from './SearchDraftTexts';

/** 两个页面共用的文案来源。 */
class AppSearchTexts implements SearchTexts, ProductTexts {
  text(key: string): string {
    return SearchDraftTexts.text(key);
  }

  format(key: string, vars: Map<string, string>): string {
    return SearchDraftTexts.format(key, vars);
  }
}

export class AppSearch {
  private readonly texts: AppSearchTexts = new AppSearchTexts();

  searchConfig(param: Object): SearchPageConfig {
    const config: SearchPageConfig = new SearchPageConfig(controller, this.texts);
    return config;
  }

  productConfig(param: Object): ProductPageConfig {
    const config: ProductPageConfig = new ProductPageConfig(controller, this.texts);
    return config;
  }
}
""",
    SEARCH_VIEW: """import { ProductCardMapper } from 'designsystem';

export class SearchPageConfig {
  readonly controller: SearchController;
  readonly texts: SearchTexts;

  constructor(controller: SearchController, texts: SearchTexts) {
    this.controller = controller;
    this.texts = texts;
  }
}

@ComponentV2
export struct SearchView {
  private toCards(items: Record<string, Object>[], prefix: string, purchase: Record<string, string>): ResultCard[] {
    return items.map((raw: Record<string, Object>, index: number) => {
      return new ResultCard(raw, ProductCardMapper.fromCard(raw, this.config.texts, true, now, status),
        ProductCardMapper.fromCard(raw, this.config.texts, false, now, status), prefix);
    });
  }
}
""",
    DETAIL_VIEW: """import { ProductCardMapper } from 'designsystem';

export class ProductPageConfig {
  readonly controller: ProductDetailController;
  readonly texts: ProductTexts;
  constructor(controller: ProductDetailController, texts: ProductTexts) {
    this.controller = controller;
    this.texts = texts;
  }
}

@ComponentV2
export struct ProductDetailView {
  private apply(s: ProductSnapshot): void {
    m.card = ProductCardMapper.fromCard(s.product, this.config.texts, s.view.buyEnabled, Date.now(), s.purchaseStatus);
  }
}
""",
    APP_CLIPBOARD: """import { ProductCardMapper, ProductCardTexts } from 'designsystem';
import { SearchDraftTexts } from '../search/SearchDraftTexts';

export class AppClipboard {
  private rowsOf(r: ClipboardResultView): ClipboardCardRow[] {
    out.push(new ClipboardCardRow(r.serial, row, binding,
      ProductCardMapper.fromCardWithStatus(row.card, new CardTexts(), true, statusOf), '', false,
      ProductCardMapper.fromCardWithStatus(row.card, new CardTexts(), false, statusOf)));
    return out;
  }
}

/** 卡片文案（与搜索页同一份草稿表）。 */
class CardTexts implements ProductCardTexts {
  text(key: string): string {
    return SearchDraftTexts.text(key);
  }
}
""",
    APP_HOME: """import { ProductCardData, ProductCardMapper, ProductCardTexts } from 'designsystem';
import { SearchDraftTexts } from '../search/SearchDraftTexts';

class CardTexts implements ProductCardTexts {
  text(key: string): string {
    return SearchDraftTexts.text(key);
  }
}

export class HomeControllerPort implements HomeScreenPort {
  private readonly texts: CardTexts = new CardTexts();

  productCard(json: Record<string, Object>): ProductCardData {
    const d: ProductCardData = ProductCardMapper.fromCardWithStatus(json, this.texts, false,
      (platform: string): string => AppTrade.shared.platformStatus(platform));
    return d;
  }
}
""",
    APP_AGENT: """import { ProductCardData, ProductCardMapper, ProductCardTexts } from 'designsystem';
import { SearchDraftTexts } from '../search/SearchDraftTexts';

class CardTexts implements ProductCardTexts {
  text(key: string): string {
    return SearchDraftTexts.text(key);
  }
}

class AgentControllerPort implements AgentScreenPort {
  private readonly texts: CardTexts = new CardTexts();

  productCard(json: Record<string, Object>): ProductCardData {
    const d: ProductCardData = ProductCardMapper.fromCardWithStatus(json, this.texts, true,
      (platform: string): string => AppTrade.shared.platformStatus(platform));
    d.amountHidden = false;
    return d;
  }
}
""",
    MAPPER: """import { hilog } from '@kit.PerformanceAnalysisKit';

/** 缺键诊断：只带 text_key。 */
class CtaKeyLog {
  static fallback(key: string): void {
    hilog.warn(0x0000, 'CouliCta', 'cta text_key %{public}s not renderable, fallback btn.buy', key);
  }
}

export class ProductCardMapper {
  static fromCardWithStatus(card: Record<string, Object>, texts: ProductCardTexts, buyEnabled: boolean,
    statusOf: (platform: string) => string, nowMillis: number = Date.now(),
    onCtaFallback: (key: string) => void = (key: string): void => CtaKeyLog.fallback(key)): ProductCardData {
    return ProductCardMapper.fromCard(card, texts, buyEnabled, nowMillis, statusOf(''), onCtaFallback);
  }

  static fromCard(card: Record<string, Object>, texts: ProductCardTexts, buyEnabled: boolean = true,
    nowMillis: number = Date.now(), purchaseStatus: string = ProductCardMapper.PURCHASE_ON,
    onCtaFallback: (key: string) => void = (key: string): void => CtaKeyLog.fallback(key)): ProductCardData {
    return new ProductCardData();
  }
}
""",
    DS_LIST: """import formatVectorTest from './FormatVector.test';
import ctaKeyVectorTest from './CtaKeyVector.test';

export default function testsuite() {
  formatVectorTest();
  ctaKeyVectorTest();
}
""",
    CORE_LIST: """import searchIntegrationTest from './SearchIntegration.test';
import ctaKeyDetailTest from './CtaKeyDetail.test';

export default function testsuite() {
  searchIntegrationTest();
  ctaKeyDetailTest();
}
""",
    DS_SUITE: "export default function ctaKeyVectorTest() {\n}\n",
    CORE_SUITE: "export default function ctaKeyDetailTest() {\n}\n",
}

# (名称, 文件, 原文, 替换, 必须命中的检查项)
MUTANTS = [
    ('锁回 00deded', LOCK, LOCK_COMMIT, '00deded0ef6f62716fcd8ca62f549dfdc1da4995', 'L1'),
    ('向量的 contractCommit 与锁不一致', VECTORS, '"contractCommit": "' + LOCK_COMMIT,
     '"contractCommit": "00deded0ef6f62716fcd8ca62f549dfdc1da4995', 'L1'),
    ('升锁后快照没重新同步（texts 与 iOS 不同）', TEXTS, '"btn.buy": "购买"', '"btn.buy": "去购买"', 'L2'),
    ('openapi 快照不是锁定提交的', 'contracts/snapshot/contracts/openapi.json', '{"paths": {}}', '{"paths": {"/x": {}}}', 'L2'),
    ('向量被改了一个字', VECTORS, '"missing.cta"', '"missing.cta2"', 'V1'),
    ('搜索卡换成别的文案函数', SEARCH_VIEW, 'fromCard(raw, this.config.texts, true', 'fromCard(raw, new EchoTexts(), true', 'W1'),
    ('AppSearchTexts 先查草稿、缺键回键名', APP_SEARCH, '    return SearchDraftTexts.text(key);\n  }\n\n  format',
     '    return SearchDraftTexts.DRAFTS.get(key) ?? key;\n  }\n\n  format', 'W1'),
    ('详情配置换了文案来源', APP_SEARCH, 'new ProductPageConfig(controller, this.texts)',
     'new ProductPageConfig(controller, new KeyEchoTexts())', 'W1'),
    ('ProductPageConfig 构造器不收调用方的 texts', DETAIL_VIEW, '    this.texts = texts;', '    this.texts = new EchoTexts();', 'W1'),
    ('剪贴板弹层的 CardTexts 回键名', APP_CLIPBOARD, '    return SearchDraftTexts.text(key);', '    return key;', 'W1'),
    ('首页的 texts 换成别的类', APP_HOME, 'private readonly texts: CardTexts = new CardTexts();',
     'private readonly texts: HomeTexts = new HomeTexts();', 'W1'),
    ('AI 卡少一处映射（换了写法）', APP_AGENT, 'ProductCardMapper.fromCardWithStatus(json, this.texts, true,',
     'ProductCardMapper.map(json, this.texts, true,', 'W1'),
    ('新调用点没登记', 'features/home/src/main/ets/HomeCards.ets', None,
     "export function card(j: Record<string, Object>): ProductCardData {\n"
     "  return ProductCardMapper.fromCard(j, new CardTexts(), false);\n}\n", 'W1'),
    ('草稿表加 btn.buy「去购买」', DRAFT_TEXTS, "    m.set('platform.taobao', '淘宝');",
     "    m.set('platform.taobao', '淘宝');\n    m.set('btn.buy', '去购买');", 'W2'),
    ('草稿表加锁外新键', DRAFT_TEXTS, "    return m;", "    m.set('btn.buy.future_x', '马上买');\n    return m;", 'W2'),
    ('SearchDraftTexts.text 先查草稿', DRAFT_TEXTS,
     'return DefaultTexts.text(key) ?? SearchDraftTexts.DRAFTS.get(key)',
     'return SearchDraftTexts.DRAFTS.get(key) ?? DefaultTexts.text(key)', 'W2'),
    ('草稿表用循环拼（解析不了）', DRAFT_TEXTS, "    return m;",
     "    for (const k of EXTRA) {\n      m.set(k, '购买');\n    }\n    return m;", 'W2'),
    ('别处往草稿表塞 btn.buy', APP_HOME, '  productCard(json', "  init(): void {\n    SearchDraftTexts.DRAFTS.set('btn.buy', '去购买');\n  }\n\n  productCard(json", 'W2'),
    ('契约 fallbacks 有 btn.buy.rebate', TEXTS, '"error.50001": "服务暂时不可用"',
     '"error.50001": "服务暂时不可用", "btn.buy.rebate": "购买"', 'W2'),
    ('日志多带 product_key', MAPPER, "%{public}s not renderable, fallback btn.buy', key);",
     "%{public}s not renderable, fallback btn.buy %{public}s', key, productKey);", 'W3'),
    ('日志把标题拼进参数', MAPPER, "fallback btn.buy', key);", "fallback btn.buy', key + ' ' + title);", 'W3'),
    ('日志用 private（Release 看不到键）', MAPPER, '%{public}s', '%{private}s', 'W3'),
    ('日志用 debug 级别', MAPPER, 'hilog.warn(', 'hilog.debug(', 'W3'),
    ('不记诊断（默认空函数、没有 hilog）', MAPPER,
     "    hilog.warn(0x0000, 'CouliCta', 'cta text_key %{public}s not renderable, fallback btn.buy', key);\n", '', 'W3'),
    ('fromCard 的默认值是空函数', MAPPER,
     "purchaseStatus: string = ProductCardMapper.PURCHASE_ON,\n    onCtaFallback: (key: string) => void = (key: string): void => CtaKeyLog.fallback(key))",
     "purchaseStatus: string = ProductCardMapper.PURCHASE_ON,\n    onCtaFallback: (key: string) => void = (_key: string): void => {\n    })", 'W3'),
    ('fromCardWithStatus 没有诊断参数', MAPPER,
     "nowMillis: number = Date.now(),\n    onCtaFallback: (key: string) => void = (key: string): void => CtaKeyLog.fallback(key)): ProductCardData {\n    return ProductCardMapper.fromCard(card, texts, buyEnabled, nowMillis, statusOf(''), onCtaFallback);",
     "nowMillis: number = Date.now()): ProductCardData {\n    return ProductCardMapper.fromCard(card, texts, buyEnabled, nowMillis, statusOf(''));", 'W3'),
    ('调用方把诊断换成空函数', APP_HOME, '(platform: string): string => AppTrade.shared.platformStatus(platform));',
     '(platform: string): string => AppTrade.shared.platformStatus(platform), Date.now(), (_k: string): void => {\n      });', 'W4'),
    ('designsystem 套件没登记', DS_LIST, '  ctaKeyVectorTest();\n', '', 'R1'),
    ('core 套件没导入', CORE_LIST, "import ctaKeyDetailTest from './CtaKeyDetail.test';\n", '', 'R1'),
]


def write_tree(base, files):
    for rel, text in files.items():
        p = os.path.join(base, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w', encoding='utf-8') as fh:
            fh.write(text)


def reference_expect(base):
    snaps = tuple((rel, sha256(base, rel)) for rel, _want in SAME_NAME)
    with open(os.path.join(base, VECTORS), 'rb') as fh:
        raw = fh.read()
    return Expect(hashlib.sha256(raw).hexdigest(), raw.count(b'\n'), snaps)


def self_test():
    tmp = tempfile.mkdtemp(prefix='ctakey-check-')
    bad = 0
    try:
        ref = os.path.join(tmp, 'ref')
        write_tree(ref, REFERENCE)
        expect = reference_expect(ref)
        got = check(ref, expect)
        print('自测 参考件：%d 违反%s' % (len(got), '' if not got else ' ' + repr(got)))
        bad += 1 if got else 0
        for name, rel, old, new, want in MUTANTS:
            files = dict(REFERENCE)
            if old is None:
                assert rel not in files, name
                files[rel] = new
            else:
                assert files[rel].count(old) == 1, (name, files[rel].count(old))
                files[rel] = files[rel].replace(old, new)
            d = os.path.join(tmp, 'mut')
            shutil.rmtree(d, ignore_errors=True)
            write_tree(d, files)
            got = check(d, expect)
            hit = any(x.startswith(want + ' ') for x in got)
            print(('拦下 ' if hit else '漏过!') + ' %s（应命中 %s；报 %s）' % (name, want, sorted({x.split(' ')[0] for x in got})))
            bad += 0 if hit else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print('check_cta_key --self-test：%d 个错误实现，%s' % (len(MUTANTS), '全部拦下' if bad == 0 else '%d 处失败' % bad))
    return 1 if bad else 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    root = os.path.abspath(argv[argv.index('--root') + 1]) if '--root' in argv else \
        os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
    got = check(root)
    for x in got:
        print(x)
    print('check_cta_key：%d 处违反（%s）' % (len(got), root))
    return 1 if got else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
