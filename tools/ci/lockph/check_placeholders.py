#!/usr/bin/env python3
"""FU-HM-LOCK-PLACEHOLDERS-harmony 测试作者 v1：文案占位符通用守卫（宿主静态检查）。

为什么要有：升锁后契约给某个键加了文案（或改了占位符名），本端代码仍按草稿的占位符名代入，页面就丢值或露字面量
（deletion.cooling.deadline 契约 {cancel_deadline} / 代码 time；login.code.countdown 契约 {n} / 代码 sec）。
这类错 hvigor、codelinter、单测都不报，只有到页面上才看见；这里在宿主上逐个调用点比对。

扫描范围：common / features / entry 下 src/main、src/release、src/staging 的 .ets（不含 src/test、src/ohosTest、src/mock、
common/generated 生成物）。识别的占位代入写法（--list 打印每种写法命中的调用点）：
  F1 fmt1(<texts>, KEY, 'name', value)                 features/me MeKit、features/wallet WalletViewKit
  F2 this.fmt(KEY, 'name', value)                      features/auth LoginView（三参）
  F3 X.format1(KEY, 'name', value)                     Core MeDraftTexts / AccountDraftTexts
  F4 <texts>.format(KEY, VARS[, …]) / this.fmt(KEY, VARS)  VARS 是本函数里的 Map 变量（收集 VARS.set('name', …)）、
                                                       new Map<string, string>()（空），或本文件里返回 Map 的函数 / this.方法 调用（收集其函数体的 .set）
  F5 <…>.text(KEY) / this.t(KEY) / t(KEY) 后接 .split('{name}').join(…)（可连写多段）
  F6 Cls.CONST.replace('{name}', …) / .split('{name}')  模板是本端常量（不是文案键，如 PriceTerms.buySuffix）
KEY 可解析：字面量、Cls.CONST（static readonly 字符串常量）、文件级 const、a ?? B（取 B）、c ? A : B（两支都查）、末尾 as string。
解析不了的（运行时才知道的键，如 outcome.textKey、l['key']）计入「动态键，跳过」，--list 逐条列出，不判红。

判定（每个调用点 × 每个可解析键）：生效文案 = 契约 texts.default.json 的 texts 优先，否则草稿表（*DraftTexts.ets 里 m.set('键', '文')）。
  R1 代入的每个占位符名必须出现在生效文案里（代入名错 / 契约改名未跟）；两种多给不判 R1（同一 Map 供别的键用，多给的名字
     format 时无害）：键取自 a ?? B 的 B（Map 也供运行时键 a 用，如错误文案共用 trace6 / provider_name），以及只在 if 分支里
     set 的名字（如 SearchView 价格筛选三个键共用一个 Map）。这两种情况 R2 照判，契约改名仍会被拦（自测有对应变异体）；
  R2 生效文案里的每个占位符都必须有代入（漏代入）；唯一例外：调用点一个变量都不给、且契约 fallbacks 有该键（产品有意走 fallback）；
  R3 键在契约与所有草稿表里都没有文字；
  R4 键只在草稿里、且多张草稿表占位符集合不一致（查找链不同会得到不同结果）。
F6 只查 R1、R2。

用法：
  python3 tools/ci/lockph/check_placeholders.py              本仓库（违反即退出 1）
  python3 tools/ci/lockph/check_placeholders.py --root <树>   换一棵树
  python3 tools/ci/lockph/check_placeholders.py --list        另列识别到的全部调用点与跳过的动态键
  python3 tools/ci/lockph/check_placeholders.py --dump-json   输出调用点 JSON（run-logic.cjs 用来定位两处回归用例的真实调用）
  python3 tools/ci/lockph/check_placeholders.py --self-test   合成夹具自测：正确实现零违反，错误实现（代入名错、漏代入、
                                                              契约改名未跟、split 写法名错、草稿键名错、常量模板名错）必须各自被拦
"""
import glob
import json
import os
import re
import shutil
import sys
import tempfile

CONTRACT = 'contracts/snapshot/contracts/texts.default.json'
SCAN_DIRS = ('common', 'features', 'entry')
SRC_SETS = ('main', 'release', 'staging')
PH = re.compile(r'\{([A-Za-z0-9_]+)\}')
CONTROL = {'if', 'for', 'while', 'switch', 'catch', 'with', 'return', 'typeof', 'await'}


# ------------------------------------------------------------------ 词法

def scan(text):
    """返回 (code, masked)：code 把注释换成空格；masked 另把字符串内容换成空格（花括号配对用）。偏移与原文一致。"""
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


def split_args(code, masked, open_idx):
    """open_idx 是 '(' 的位置；返回 (参数文本列表, 右括号位置)。"""
    close = match_close(masked, open_idx)
    if close < 0:
        return None, -1
    args, depth, start = [], 0, open_idx + 1
    for k in range(open_idx + 1, close):
        ch = masked[k]
        if ch in '([{<' and not (ch == '<' and not re.match(r'<\s*[A-Za-z]', masked[k:k + 3])):
            depth += 1
        elif ch in ')]}' or (ch == '>' and depth > 0 and masked[k - 1] != '='):
            depth -= 1
        elif ch == ',' and depth == 0:
            args.append(code[start:k].strip())
            start = k + 1
    tail = code[start:close].strip()
    if tail:
        args.append(tail)
    return args, close


def function_blocks(masked):
    """返回函数体块 [(open, close, header_text)]（含箭头函数、方法、构造器、get/set）。"""
    blocks = []
    stack = []
    for k, ch in enumerate(masked):
        if ch == '{':
            stack.append(k)
        elif ch == '}' and stack:
            o = stack.pop()
            before = masked[max(0, o - 400):o].rstrip()
            is_fn = False
            if before.endswith('=>'):
                is_fn = True
            else:
                m = re.search(r'\)\s*(?::\s*[^{};=()]+(?:\([^(){};]*\)[^{};=()]*)?)?$', before)
                if m:
                    # 找与这个 ')' 配对的 '('，看前面的词是不是控制语句
                    rp = o - (len(masked[max(0, o - 400):o]) - len(before)) - (len(before) - m.start())
                    rp = masked.rfind(')', 0, o) if masked[rp] != ')' else rp
                    depth, lp = 0, -1
                    for q in range(rp, -1, -1):
                        if masked[q] == ')':
                            depth += 1
                        elif masked[q] == '(':
                            depth -= 1
                            if depth == 0:
                                lp = q
                                break
                    word = re.search(r'([A-Za-z_]\w*)\s*$', masked[max(0, lp - 60):lp]) if lp > 0 else None
                    is_fn = lp > 0 and not (word and word.group(1) in CONTROL)
            if is_fn:
                blocks.append((o, k, masked[max(0, o - 300):o]))
    return blocks


# ------------------------------------------------------------------ 文案来源

def load_contract(root):
    with open(os.path.join(root, CONTRACT), encoding='utf-8') as fh:
        d = json.load(fh)
    return d.get('texts', {}), d.get('fallbacks', {})


def split_plus(expr):
    """按顶层 '+' 切开（字符串与括号内的不切）。"""
    code, masked = scan(expr)
    parts, depth, start = [], 0, 0
    for k, ch in enumerate(masked):
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        elif ch == '+' and depth == 0:
            parts.append(code[start:k].strip())
            start = k + 1
    parts.append(code[start:].strip())
    return parts


def load_drafts(root):
    """键 → [(相对文件, 文字)]。值可以是字面量连接，也可以拼接别的文案（X.text('k')，如 AgentDraftTexts 复用钱包草稿），
    后者按生效文案展开；其余非字面量项（函数调用等）按不含占位符处理。"""
    raw = {}
    for f in sorted(product_files(root)):
        if not f.endswith('DraftTexts.ets'):
            continue
        code, masked = scan(read(f))
        for m in re.finditer(r"\.set\(\s*'([^']+)'\s*,", code):
            args, _ = split_args(code, masked, m.start() + 4)
            if not args or len(args) != 2:
                continue
            raw.setdefault(m.group(1), []).append((os.path.relpath(f, root).replace(os.sep, '/'), args[1]))
    texts, _ = load_contract(root)

    def expand(expr, depth):
        out = []
        for term in split_plus(expr):
            lit = re.fullmatch(r"'((?:[^'\\]|\\.)*)'", term)
            if lit:
                out.append(lit.group(1))
                continue
            ref = re.fullmatch(r"[A-Za-z_]\w*\.text\(\s*'([^']+)'\s*\)", term)
            if ref and depth < 5:
                k = ref.group(1)
                if k in texts:
                    out.append(texts[k])
                elif k in raw:
                    out.append(expand(raw[k][0][1], depth + 1))
        return ''.join(out)

    return {key: [(f, expand(e, 0)) for f, e in entries] for key, entries in raw.items()}


def product_files(root):
    out = []
    for top in SCAN_DIRS:
        for f in glob.glob(os.path.join(root, top, '**', 'src', '*', '**', '*.ets'), recursive=True):
            rel = os.path.relpath(f, root).replace(os.sep, '/')
            parts = rel.split('/')
            if 'oh_modules' in parts or 'build' in parts or rel.startswith('common/generated/'):
                continue
            si = parts.index('src')
            if si + 1 < len(parts) and parts[si + 1] in SRC_SETS:
                out.append(f)
    return sorted(set(out))


def read(f):
    with open(f, encoding='utf-8') as fh:
        return fh.read()


# ------------------------------------------------------------------ 常量与键解析

CLASS_RE = re.compile(r'\b(?:class|namespace|enum)\s+([A-Za-z_]\w*)')
STATIC_RE = re.compile(r"static\s+readonly\s+([A-Za-z_]\w*)\s*(?::\s*string)?\s*=\s*'((?:[^'\\]|\\.)*)'")
FILE_CONST_RE = re.compile(r"^(?:export\s+)?const\s+([A-Za-z_]\w*)\s*(?::\s*string)?\s*=\s*'((?:[^'\\]|\\.)*)'", re.M)


def collect_constants(files):
    cls_consts, file_consts = {}, {}
    for f in files:
        code, _ = scan(read(f))
        classes = [(m.start(), m.group(1)) for m in CLASS_RE.finditer(code)]
        for m in STATIC_RE.finditer(code):
            owner = None
            for pos, name in classes:
                if pos < m.start():
                    owner = name
            if owner:
                cls_consts.setdefault((owner, m.group(1)), set()).add(m.group(2))
        fc = {}
        for m in FILE_CONST_RE.finditer(code):
            fc[m.group(1)] = m.group(2)
        file_consts[f] = fc
    return cls_consts, file_consts


def resolve(expr, f, cls_consts, file_consts):
    """返回 (键列表, 说明) 或 (None, 原因)。"""
    e = re.sub(r'\s+as\s+string\s*$', '', expr.strip()).strip()
    while e.startswith('(') and e.endswith(')') and match_close(e, 0) == len(e) - 1:
        e = e[1:-1].strip()
    m = re.fullmatch(r"'((?:[^'\\]|\\.)*)'", e)
    if m:
        return [m.group(1)], ''
    if '??' in e:
        right = e.rsplit('??', 1)[1]
        keys, why = resolve(right, f, cls_consts, file_consts)
        return (keys, '取 ?? 右侧') if keys else (None, why)
    m = re.fullmatch(r'(.+?)\?(.+):(.+)', e, re.S)
    if m:
        a, _ = resolve(m.group(2), f, cls_consts, file_consts)
        b, _ = resolve(m.group(3), f, cls_consts, file_consts)
        if a and b:
            return sorted(set(a + b)), '三元两支'
        return None, '三元有动态支'
    m = re.fullmatch(r'([A-Za-z_]\w*)\.([A-Za-z_]\w*)', e)
    if m:
        vals = cls_consts.get((m.group(1), m.group(2)))
        if vals and len(vals) == 1:
            return sorted(vals), ''
        return None, '动态键'
    m = re.fullmatch(r'[A-Za-z_]\w*', e)
    if m and e in file_consts.get(f, {}):
        return [file_consts[f][e]], ''
    return None, '动态键'


# ------------------------------------------------------------------ 调用点

class Site:
    def __init__(self, form, f, line, keys, names, note='', empty_vars=False, template=None, call=''):
        self.form, self.file, self.line, self.keys = form, f, line, keys
        self.names, self.note, self.empty_vars, self.template, self.call = names, note, empty_vars, template, call
        self.shared = 'shared' in note or '取 ?? 右侧' in note   # 键取 a ?? B 的 B：同一份变量也供运行时键用，多给的名字不判 R1
        self.cond = set()        # 只在分支里 set 的名字（同一 Map 供几个分支键用）：不判 R1，仍计入 R2 的「有代入」


def line_of(text, pos):
    return text.count('\n', 0, pos) + 1


def is_definition(code, close):
    # 声明 / 签名：右括号后是「: 类型 {」或「: 类型;」；三元的「: fmt1(…)」不算
    return re.match(r'\s*:\s*[\w<>\[\]|., ]+\s*[{;]', code[close + 1:close + 120]) is not None


def vars_names(code, masked, blocks, pos, ident, f, fn_sets):
    """VARS 标识符在调用点所在函数里被 set 的名字。返回 (names, note) 或 (None, 原因)。"""
    m = re.fullmatch(r'new\s+Map\s*<\s*string\s*,\s*string\s*>\s*\(\s*\)', ident)
    if m:
        return set(), 'empty'
    m = re.fullmatch(r'(?:this\.)?([A-Za-z_]\w*)\s*\((.*)\)', ident, re.S)
    if m and m.group(1) in fn_sets:
        return set(fn_sets[m.group(1)]), '本文件函数 ' + m.group(1) + '()'

    if not re.fullmatch(r'[A-Za-z_]\w*', ident):
        return None, '变量表达式 ' + ident
    enclosing = sorted([b for b in blocks if b[0] < pos < b[1]], key=lambda b: b[1] - b[0])
    for o, c, header in enclosing:
        body = code[o:c]
        decl = re.search(r'^([ \t]*).*\b(?:const|let|var)\s+' + re.escape(ident) + r'\b', body, re.M)
        if decl:
            dyn = re.findall(re.escape(ident) + r"\.set\(\s*([^'\s][^,]*),", body)
            if dyn:
                return None, 'VARS 有非字面量名 ' + ','.join(dyn)
            names, cond = set(), set()
            for sm in re.finditer(r'^([ \t]*).*?' + re.escape(ident) + r"\.set\(\s*'([^']+)'", body, re.M):
                names.add(sm.group(2))
                if len(sm.group(1)) > len(decl.group(1)):
                    cond.add(sm.group(2))
            # 先无条件 set 过的名字不算条件代入
            uncond = {n for n in names if n not in cond}
            return names, ('cond:' + ','.join(sorted(cond - uncond))) if cond - uncond else ''
        hdr_params = header[header.rfind('('):] if '(' in header else ''
        if re.search(r'\b' + re.escape(ident) + r'\s*:', hdr_params):
            return None, '参数透传'
    return None, '找不到 VARS 声明'


def file_map_functions(code):
    """本文件里返回 Map<string, string> 的函数：名 → 其函数体里 .set('name' 的名字。"""
    out = {}
    for m in re.finditer(r'(?:function\s+|^\s*(?:private\s+|static\s+|public\s+)*)([A-Za-z_]\w*)\s*\([^()]*\)\s*:\s*Map\s*<\s*string\s*,\s*string\s*>\s*\{',
                         code, re.M):
        o = m.end() - 1
        _, masked = scan(code)
        c = match_close(masked, o, '{', '}')
        body = code[o:c]
        out[m.group(1)] = set(re.findall(r"\.set\(\s*'([^']+)'", body))
    return out


def find_sites(root):
    files = product_files(root)
    cls_consts, file_consts = collect_constants(files)
    sites, skipped = [], []
    for f in files:
        raw = read(f)
        code, masked = scan(raw)
        rel = os.path.relpath(f, root).replace(os.sep, '/')
        blocks = None
        fn_sets = file_map_functions(code)

        def add_skip(form, pos, why, call):
            skipped.append((form, rel, line_of(code, pos), why, call))

        def keyed(form, pos, key_expr, names, call, empty=False, note=''):
            keys, why = resolve(key_expr, f, cls_consts, file_consts)
            if keys is None:
                add_skip(form, pos, why + '：' + key_expr, call)
                return
            sites.append(Site(form, rel, line_of(code, pos), keys, sorted(names), (note + ' ' + why).strip(), empty, call=call))

        for m in re.finditer(r'(?<![\w.])fmt1\s*\(|\.fmt\s*\(|(?<![\w.])fmt\s*\(|\.format1\s*\(|\.format\s*\(', code):
            open_idx = m.end() - 1
            args, close = split_args(code, masked, open_idx)
            if args is None or is_definition(code, close):
                continue
            name = m.group(0)
            call = re.sub(r'\s+', ' ', code[m.start():close + 1])[:160]
            if name.startswith('fmt1'):
                form, key_i, name_i = 'F1', 1, 2
            elif 'format1' in name:
                form, key_i, name_i = 'F3', 0, 1
            elif 'fmt' in name and len(args) == 3 and re.fullmatch(r"'[^']*'", args[1]):
                form, key_i, name_i = 'F2', 0, 1
            else:
                form, key_i, name_i = 'F4', 0, None
            if len(args) <= key_i:
                continue
            if name_i is not None:
                if len(args) <= name_i:
                    continue
                nm = re.fullmatch(r"'([^']*)'", args[name_i])
                if not nm:
                    add_skip(form, m.start(), '占位符名非字面量', call)
                    continue
                if form == 'F3' and len(args) > 2 and args[2].strip() == 'null':
                    keyed(form, m.start(), args[key_i], [], call, empty=True)
                else:
                    keyed(form, m.start(), args[key_i], [nm.group(1)], call)
                continue
            if len(args) < 2:
                continue
            if blocks is None:
                blocks = function_blocks(masked)
            keys, why = resolve(args[0], f, cls_consts, file_consts)
            if keys is None:
                add_skip(form, m.start(), why + '：' + args[0], call)
                continue
            names, vnote = vars_names(code, masked, blocks, m.start(), args[1], f, fn_sets)
            if names is None:
                add_skip(form, m.start(), vnote, call)
                continue
            site = Site(form, rel, line_of(code, m.start()), keys, sorted(names),
                        (why + ' ' + ('' if vnote == 'empty' else vnote)).strip(), vnote == 'empty', call=call)
            site.shared = why == '取 ?? 右侧'
            site.cond = set(vnote[5:].split(',')) if vnote.startswith('cond:') else set()
            sites.append(site)

        # F5：文案 + split('{x}').join(…) 连写
        for m in re.finditer(r'(?:\.text|(?<![\w.])t|\.t)\s*\(', code):
            open_idx = m.end() - 1
            args, close = split_args(code, masked, open_idx)
            if not args or len(args) != 1 or is_definition(code, close):
                continue
            names, k = [], close + 1
            while True:
                s = re.match(r"\s*\.split\(\s*'([^']*)'\s*\)\s*\.join\(", code[k:])
                if not s:
                    break
                for ph in PH.findall(s.group(1)):
                    names.append(ph)
                jopen = k + s.end() - 1
                jc = match_close(masked, jopen)
                k = jc + 1
            if not names:
                continue
            call = re.sub(r'\s+', ' ', code[m.start():k])[:160]
            keyed('F5', m.start(), args[0], names, call)

        # F6：常量模板
        for m in re.finditer(r'\b([A-Z][A-Za-z_]\w*)\.([A-Za-z_]\w*)\s*\.(?:replace|replaceAll|split)\(\s*\'([^\']*)\'', code):
            vals = cls_consts.get((m.group(1), m.group(2)))
            if not vals or len(vals) != 1:
                continue
            tpl = next(iter(vals))
            if not PH.search(tpl) and not PH.search(m.group(3)):
                continue
            ln = line_of(code, m.start())
            names = set(PH.findall(m.group(3)))
            # 同一行里连写的其余 replace / split（ArkUI 构建行没有分号，只看到行尾）
            rest = code[m.end():].split('\n', 1)[0].split(';')[0]
            names |= set(PH.findall(' '.join(re.findall(r"\.(?:replace|replaceAll|split)\(\s*'([^']*)'", rest))))
            sites.append(Site('F6', rel, ln, [], sorted(names), m.group(1) + '.' + m.group(2), template=tpl,
                              call=re.sub(r'\s+', ' ', code[m.start():m.end() + 60])[:160]))

        # 其余带 '{x}' 的 split / replace（接收者不是文案取值也不是常量）：列出供人工判断
        for m in re.finditer(r"\.(?:split|replace|replaceAll)\(\s*'[^']*\{[A-Za-z0-9_]+\}[^']*'", code):
            ln = line_of(code, m.start())
            if any(s.file == rel and s.line == ln and s.form in ('F5', 'F6') for s in sites):
                continue
            add_skip('F5/F6', m.start(), '接收者不是可解析的文案或常量', re.sub(r'\s+', ' ', code[max(0, m.start() - 80):m.end() + 20])[-160:])
    return sites, skipped


# ------------------------------------------------------------------ 判定

def check(root, sites):
    texts, fallbacks = load_contract(root)
    drafts = load_drafts(root)
    violations = []
    for s in sites:
        where = s.file + ':' + str(s.line)
        if s.form == 'F6':
            have = set(PH.findall(s.template))
            for n in sorted(set(s.names) - have):
                violations.append((where, s.note, 'R1', '代入 {' + n + '}，常量模板「' + s.template + '」里没有'))
            for n in sorted(have - set(s.names)):
                violations.append((where, s.note, 'R2', '常量模板「' + s.template + '」的 {' + n + '} 没有代入'))
            continue
        for key in s.keys:
            if key in texts:
                eff, src = texts[key], '契约'
            elif key in drafts:
                sets = {frozenset(PH.findall(v)) for _, v in drafts[key]}
                if len(sets) > 1:
                    violations.append((where, key, 'R4', '只在草稿里且草稿表占位符不一致：'
                                       + '；'.join(f + '「' + v + '」' for f, v in drafts[key])))
                    continue
                eff, src = drafts[key][0][1], '草稿 ' + drafts[key][0][0]
            else:
                violations.append((where, key, 'R3', '契约与草稿表都没有这个键'))
                continue
            have = set(PH.findall(eff))
            given = set(s.names)
            for n in sorted(given - have - s.cond):
                if s.shared:
                    break
                violations.append((where, key, 'R1', '代入 {' + n + '}，生效文案（' + src + '）「' + eff + '」里没有'))
            if s.empty_vars and key in fallbacks:
                continue
            for n in sorted(have - given):
                violations.append((where, key, 'R2', '生效文案（' + src + '）「' + eff + '」的 {' + n + '} 没有代入'
                                   + '（代入了：' + (','.join(sorted(given)) or '无') + '）'))
    return violations


def run(root, listing=False, quiet=False):
    sites, skipped = find_sites(root)
    violations = check(root, sites)
    if not quiet:
        forms = {}
        for s in sites:
            forms[s.form] = forms.get(s.form, 0) + 1
        print('LOCKPH 识别到可判定调用点 %d 处（%s）；动态键 / 不可解析跳过 %d 处' % (
            len(sites), '，'.join(k + '=' + str(v) for k, v in sorted(forms.items())), len(skipped)))
        if listing:
            for s in sorted(sites, key=lambda x: (x.file, x.line)):
                print('  %s %s:%d keys=%s names=%s %s' % (s.form, s.file, s.line, ','.join(s.keys) or '-',
                                                          ','.join(s.names) or '无', s.note))
            print('跳过：')
            for form, f, ln, why, call in skipped:
                print('  %s %s:%d %s ｜ %s' % (form, f, ln, why, call))
        keys = sorted({v[1] for v in violations})
        for v in violations:
            print('违反 %s %s [%s] %s' % (v[0], v[1], v[2], v[3]))
        print('LOCKPH 违反 %d 条，涉及键 %d 个：%s' % (len(violations), len(keys), '，'.join(keys) or '无'))
    return sites, skipped, violations


# ------------------------------------------------------------------ 自测

FIX_CONTRACT = {
    'version': 1,
    'texts': {
        'deletion.cooling.deadline': '{cancel_deadline} 前可以撤回注销',
        'login.code.countdown': '{n} 秒后可重新获取',
        'order.found': '找到 {count} 笔，共 {amount}',
        'match.title': '显示 {spec}',
        'pending.desc': '上次 {phone} 还没结果',
        'price.min_only': '券后 {min} 以上',
        'price.max_only': '券后 {max} 以内',
    },
    'fallbacks': {'pending.desc': '上一次提交还没有收到结果'},
}
FIX_DRAFTS = """export class FixDraftTexts {
  static readonly DRAFTS: Map<string, string> = FixDraftTexts.build();
  private static build(): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    m.set('deletion.cooling.deadline', '{cancel_deadline} 前可以撤回注销');
    m.set('draft.only', '还剩 {left} 次，' +
      '共 {total} 次');
    m.set('label.month', '{month}结算');
    m.set('composed', FixDraftTexts.text('label.month') + ' 起');
    return m;
  }
}
"""
FIX_KEYS = """export class FixKeys {
  static readonly COUNTDOWN: string = 'login.code.countdown';
  static readonly FOUND: string = 'order.found';
}
export class FixTerms {
  static readonly suffix: string = '· 预估返 {amount}';
}
"""
FIX_VIEW = """import { FixKeys, FixTerms } from './FixKeys';

function vars(platform: string): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  m.set('count', platform);
  m.set('amount', platform);
  return m;
}

export class FixView {
  private fmt(key: string, name: string, value: string): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set(name, value);
    return this.config.texts.format(key, vars);
  }

  build(): void {
    Text(fmt1(this.config.texts, 'deletion.cooling.deadline', 'cancel_deadline', this.until))
    Text(this.fmt(FixKeys.COUNTDOWN, 'n', String(this.left)))
    Text(this.port.text('match.title').split('{spec}').join(this.spec))
    Text(this.config.texts.format(FixKeys.FOUND, vars(this.p)))
    Text(this.config.texts.format(outcome.textKey ?? 'pending.desc', new Map<string, string>()))
    Text(base + FixTerms.suffix.replace('{amount}', this.amt))
    Text(this.masked ? fmt1(this.config.texts, 'match.title', 'spec', '*')
      : fmt1(this.config.texts, 'match.title', 'spec', this.spec))
    Text(FixDraftTexts.text('composed').split('{month}').join(this.month))
    Text(this.fmt(outcome.textKey ?? 'login.code.countdown', 'n', String(this.left)))
  }

  price(min: string | null, max: string | null): string {
    const pv: Map<string, string> = new Map<string, string>();
    if (min !== null) {
      pv.set('min', min);
    }
    if (max !== null) {
      pv.set('max', max);
    }
    if (min !== null) {
      return this.config.texts.format('price.min_only', pv);
    }
    return this.config.texts.format('price.max_only', pv);
  }

  found(n: number, amount: string): string {
    const v: Map<string, string> = new Map<string, string>();
    v.set('count', String(n));
    if (amount.length > 0) {
      v.set('amount', amount);
    }
    return this.config.texts.format(FixKeys.FOUND, v);
  }

  left(a: string, b: string): string {
    const vv: Map<string, string> = new Map<string, string>();
    vv.set('left', a);
    vv.set('total', b);
    return FixDraftTexts.format('draft.only', vv);
  }

  dynamic(key: string, vars: Map<string, string>): string {
    return this.config.texts.format(key, vars);
  }
}
"""

# (名称, 要改的文件, 原文, 替换, 期望违反的键, 期望规则)
MUTANTS = [
    ('代入名错（fmt1 用草稿名 time）', 'features/x/src/main/ets/FixView.ets',
     "'deletion.cooling.deadline', 'cancel_deadline'", "'deletion.cooling.deadline', 'time'",
     'deletion.cooling.deadline', {'R1', 'R2'}),
    ('契约改名未跟（契约 {sec}→{n}，代码仍 sec）', 'features/x/src/main/ets/FixView.ets',
     "this.fmt(FixKeys.COUNTDOWN, 'n'", "this.fmt(FixKeys.COUNTDOWN, 'sec'",
     'login.code.countdown', {'R1', 'R2'}),
    ('契约改名未跟（契约侧改名，代码不动）', CONTRACT,
     '"{n} 秒后可重新获取"', '"{seconds} 秒后可重新获取"',
     'login.code.countdown', {'R1', 'R2'}),
    ('漏代入（vars 少 set 一个）', 'features/x/src/main/ets/FixView.ets',
     "    v.set('count', String(n));\n", '',
     'order.found', {'R2'}),
    ('漏代入（本文件 vars() 函数少 set）', 'features/x/src/main/ets/FixView.ets',
     "  m.set('amount', platform);\n", '',
     'order.found', {'R2'}),
    ('split 写法名错', 'features/x/src/main/ets/FixView.ets',
     "split('{spec}')", "split('{specs}')",
     'match.title', {'R1', 'R2'}),
    ('草稿键名错（只在草稿里）', 'features/x/src/main/ets/FixView.ets',
     "vv.set('total', b);", "vv.set('sum', b);",
     'draft.only', {'R1', 'R2'}),
    ('常量模板名错', 'features/x/src/main/ets/FixView.ets',
     "replace('{amount}'", "replace('{amt}'",
     'FixTerms.suffix', {'R1', 'R2'}),
    ('空 Map 调用、键没有契约 fallback（不得豁免）', 'features/x/src/main/ets/FixView.ets',
     "format(outcome.textKey ?? 'pending.desc', new Map<string, string>())",
     "format(outcome.textKey ?? 'login.code.countdown', new Map<string, string>())",
     'login.code.countdown', {'R2'}),
    ('分支共用 Map 时契约改名未跟（豁免不吞 R2）', CONTRACT,
     '"券后 {min} 以上"', '"券后 {low} 以上"',
     'price.min_only', {'R2'}),
    ('a ?? B 的 B 键代入名错（豁免不吞 R2）', 'features/x/src/main/ets/FixView.ets',
     "outcome.textKey ?? 'login.code.countdown', 'n'", "outcome.textKey ?? 'login.code.countdown', 'sec'",
     'login.code.countdown', {'R2'}),
    ('三元第二支名错（「: fmt1(」不得当成声明跳过）', 'features/x/src/main/ets/FixView.ets',
     "      : fmt1(this.config.texts, 'match.title', 'spec'", "      : fmt1(this.config.texts, 'match.title', 'spce'",
     'match.title', {'R1', 'R2'}),
    ('拼接草稿 split 名错', 'features/x/src/main/ets/FixView.ets',
     "split('{month}')", "split('{mon}')",
     'composed', {'R1', 'R2'}),
    ('键在契约与草稿都没有', 'features/x/src/main/ets/FixView.ets',
     "'match.title'", "'match.titel'",
     'match.titel', {'R3'}),
]


def build_fixture(base):
    os.makedirs(os.path.join(base, os.path.dirname(CONTRACT)), exist_ok=True)
    with open(os.path.join(base, CONTRACT), 'w', encoding='utf-8') as fh:
        json.dump(FIX_CONTRACT, fh, ensure_ascii=False, indent=2)
    for rel, text in (('common/core/src/main/ets/FixDraftTexts.ets', FIX_DRAFTS),
                      ('features/x/src/main/ets/FixKeys.ets', FIX_KEYS),
                      ('features/x/src/main/ets/FixView.ets', FIX_VIEW),
                      # 测试目录与生成物不扫：这里故意放错误写法，不得被报
                      ('features/x/src/test/Bad.test.ets', "fmt1(t, 'login.code.countdown', 'sec', '1')\n"),
                      ('common/generated/src/main/ets/Gen.ets', "fmt1(t, 'login.code.countdown', 'sec', '1')\n")):
        p = os.path.join(base, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w', encoding='utf-8') as fh:
            fh.write(text)


def self_test():
    failures = []
    tmp = tempfile.mkdtemp(prefix='lockph-selftest-')
    try:
        good = os.path.join(tmp, 'good')
        build_fixture(good)
        sites, skipped, v = run(good, quiet=True)
        forms = {s.form for s in sites}
        if v:
            failures.append('正确实现不应有违反：' + repr(v))
        for need in ('F1', 'F2', 'F4', 'F5', 'F6'):
            if need not in forms:
                failures.append('正确夹具没识别到写法 ' + need)
        if not any('参数透传' in sk[3] or '动态键' in sk[3] for sk in skipped):
            failures.append('动态键调用点应计入跳过')
        if any(s.file.startswith('common/generated') or '/src/test/' in s.file for s in sites):
            failures.append('不得扫描测试目录或生成物')
        print('自测 正确实现：调用点 %d，跳过 %d，违反 %d' % (len(sites), len(skipped), len(v)))
        for i, (name, rel, old, new, key, rules) in enumerate(MUTANTS):
            d = os.path.join(tmp, 'm%d' % i)
            shutil.copytree(good, d)
            p = os.path.join(d, rel)
            text = read(p)
            if old not in text:
                failures.append('变异体「%s」原文不在夹具里' % name)
                continue
            with open(p, 'w', encoding='utf-8') as fh:
                fh.write(text.replace(old, new, 1))
            _, _, mv = run(d, quiet=True)
            hit = {r for (_w, k, r, _m) in mv if k == key}
            other = {k for (_w, k, _r, _m) in mv if k != key}
            ok = rules <= hit and not other
            print('自测 错误实现「%s」：%s（命中 %s 规则 %s%s）' % (
                name, '被拦' if ok else '没拦住', key, ','.join(sorted(hit)) or '无',
                '；另报 ' + ','.join(sorted(other)) if other else ''))
            if not ok:
                failures.append('错误实现「%s」应报 %s %s，实得 %r' % (name, key, sorted(rules), mv))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in failures:
        print('自测失败：' + f)
    print('LOCKPH 自测：%d 个错误实现，失败 %d' % (len(MUTANTS), len(failures)))
    return 1 if failures else 0


def main(argv):
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
    if '--root' in argv:
        root = os.path.abspath(argv[argv.index('--root') + 1])
    if '--self-test' in argv:
        return self_test()
    if '--dump-json' in argv:
        sites, skipped = find_sites(root)
        json.dump({'sites': [{'form': s.form, 'file': s.file, 'line': s.line, 'keys': s.keys, 'names': s.names,
                              'emptyVars': s.empty_vars, 'call': s.call} for s in sites],
                   'skipped': [{'form': a, 'file': b, 'line': c, 'why': d, 'call': e} for a, b, c, d, e in skipped]},
                  sys.stdout, ensure_ascii=False)
        return 0
    _, _, v = run(root, listing='--list' in argv)
    return 1 if v else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
