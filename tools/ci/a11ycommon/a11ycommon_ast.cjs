#!/usr/bin/env node
// FU-HM-A11Y-COMMON-harmony 宿主守卫的解析部分（由 check_a11y_common.py 调用，不单独跑）。用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS，
// 判定全部走 AST（struct / 类 / 组件属性链 / 自定义组件对象实参 / 方法调用点 / 赋值语句），不用正则切块，注释与字符串里的字不算。
// 写法照 tools/ci/loginphone/loginphone_ast.cjs。
//   用法：node a11ycommon_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>"}, "scan": ["<相对路径>", ...]}
//     files 含 REQUIRED（见 check_a11y_common.py）与 scan 里的全部文件；scan = AC3 全仓扫描范围（features/*/src/main、entry/src/main 的 .ets）
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."], "stats": {...}}
// 规则编号见 check_a11y_common.py 文件头。
'use strict';
const fs = require('fs');
const path = require('path');

const DRAFT = 'common/core/src/main/ets/orders/OrderDraftTexts.ets';
/** 契约文案生成物（contracts/texts.default.json 经 gen.py 转写；取文案时契约优先于草稿表）。 */
const GEN_TEXTS = 'common/generated/src/main/ets/DefaultTexts.ets';
const KIT = 'features/orders/src/main/ets/OrderViewKit.ets';
const LIST = 'features/orders/src/main/ets/OrderListView.ets';
const DETAIL = 'features/orders/src/main/ets/OrderDetailView.ets';
const DS_WALLET = 'common/designsystem/src/main/ets/components/Wallet.ets';
const WALLET = 'features/wallet/src/main/ets/WalletView.ets';
const WITHDRAW = 'features/wallet/src/main/ets/WithdrawView.ets';
const PAYOUT = 'features/wallet/src/main/ets/PayoutAccountView.ets';
const LOGIN = 'features/auth/src/main/ets/LoginView.ets';
const BIND = 'features/auth/src/main/ets/BindPhoneView.ets';

/** D10-1248 ⑨：复制按钮读「复制订单号 {no}」，{no} 读完整单号（与「订单号 {no}」同口径）。 */
const COPY_KEY = 'order_list.copy_spoken';
const COPY_VALUE = '复制订单号 {no}';
/** D10-1275：复制按钮可见文字键 order_list.copy_label「复制」（三端同名；已随契约升锁进 DefaultTexts，草稿表不再有这两个键）。 */
const LABEL_KEY = 'order_list.copy_label';
const LABEL_VALUE = '复制';
/** 说明弹窗（问号）的识别：primaryText 取 wallet.help.ok（【知道了】）。 */
const HELP_OK = 'wallet.help.ok';
/** 每页至少有几处问号触发说明弹窗（防止删问号 / 改走别的出口逃过检查）。 */
const HELP_MIN = new Map([[WALLET, 3], [WITHDRAW, 1]]);
/** D10-1248 ③：资金页弹窗按主按钮键分类——确认类（【知道了】：返回 = 主按钮同一出口）与破坏类（【确认放弃】：返回 = 【取消】）。 */
const FUND_FILES = [WITHDRAW, PAYOUT];
const ACK_KEYS = new Set(['withdraw.ok']);
const DESTRUCTIVE_KEYS = new Set(['pending_confirm.abandon.ok']);
/** 本单 8 处（任务书 §1 / README ③）：必须仍是「点遮罩不关」且「系统返回可关」。按方法名定位（行号会漂）。 */
const PINNED = [[WITHDRAW, 'openRiskDialog'], [WITHDRAW, 'confirmAbandon'], [PAYOUT, 'openRiskDialog'], [PAYOUT, 'confirmAbandon'],
  [LOGIN, 'showBlocked'], [LOGIN, 'showOAuthRiskBlocked'], [BIND, 'showRiskBlocked'], [BIND, 'confirmMerge']];
/** AC3 显式豁免名单（「文件::函数」；现为空，加项要编排批）。 */
const EXEMPT = new Set([]);

const tsDir = process.argv[2];
if (!tsDir) { console.error('a11ycommon_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('a11ycommon_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('a11ycommon_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
    process.exit(3);
  }
  return { ets: cfg.compilerOptions.ets, etsLoaderPath: path.dirname(cfgPath) };
}
const ETS_OPTIONS = etsOptions();

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const violations = [];
const incomplete = [];
const stats = { scanned: 0, maskSites: 0, helpTriggers: {}, copyRows: 0 };

const parsed = new Map();
function parse(rel) {
  if (parsed.has(rel)) { return parsed.get(rel); }
  const text = input.files[rel];
  if (text === undefined || text === null) {
    incomplete.push(rel + '：文件不存在，无法判定');
    parsed.set(rel, null);
    return null;
  }
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, ETS_OPTIONS);
  if (sf.parseDiagnostics.length > 0) {
    const d = sf.parseDiagnostics[0];
    incomplete.push(rel + ':' + (sf.getLineAndCharacterOfPosition(d.start).line + 1) + ' 语法错误：' +
      ts.flattenDiagnosticMessageText(d.messageText, ' '));
    parsed.set(rel, null);
    return null;
  }
  parsed.set(rel, sf);
  return sf;
}

function lineOf(node) { return node.getSourceFile().getLineAndCharacterOfPosition(node.getStart()).line + 1; }
function report(rule, node, msg, file) {
  violations.push({ rule: rule, file: file || (node ? node.getSourceFile().fileName : ''), line: node ? lineOf(node) : 0, msg: msg });
}
function walk(node, visit) { visit(node); ts.forEachChild(node, (c) => walk(c, visit)); }
function collect(node, pred) { const out = []; walk(node, (n) => { if (pred(n)) { out.push(n); } }); return out; }
function compact(node) { return node.getText().replace(/\s+/g, ''); }
function unwrap(e) {
  while (e && (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isNonNullExpression(e))) { e = e.expression; }
  return e;
}
function isStr(n) { return n && (ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)); }
function memberName(m) { return m.name && (ts.isIdentifier(m.name) || ts.isStringLiteral(m.name)) ? m.name.text : ''; }
function isThis(n) { return n && n.kind === ts.SyntaxKind.ThisKeyword; }
function isFunctionLike(n) {
  return ts.isMethodDeclaration(n) || ts.isFunctionDeclaration(n) || ts.isArrowFunction(n) || ts.isFunctionExpression(n) ||
    ts.isConstructorDeclaration(n) || ts.isGetAccessorDeclaration(n);
}
function contains(outer, inner) { return inner.pos >= outer.pos && inner.end <= outer.end; }
/** 属性链拆成 { root, calls: [{ name, args, node }] }，calls 按书写顺序。 */
function chainOf(expr) {
  const calls = [];
  let e = unwrap(expr);
  while (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression)) {
    calls.unshift({ name: e.expression.name.text, args: Array.from(e.arguments), node: e });
    e = unwrap(e.expression.expression);
  }
  return { root: e, calls: calls };
}
function topLevel(sf, pred) {
  const out = [];
  ts.forEachChild(sf, (n) => { if (pred(n)) { out.push(n); } });
  return out;
}
function findStruct(sf, name) {
  return topLevel(sf, (n) => ts.isStructDeclaration(n) && n.name && n.name.text === name)[0] || null;
}
function findClass(sf, name) {
  return topLevel(sf, (n) => ts.isClassDeclaration(n) && n.name && n.name.text === name)[0] || null;
}
function property(obj, name) {
  if (!obj || !ts.isObjectLiteralExpression(obj)) { return null; }
  return obj.properties.find((p) => p.name && (ts.isIdentifier(p.name) || ts.isStringLiteral(p.name)) && p.name.text === name) || null;
}
function propValue(obj, name) {
  const p = property(obj, name);
  if (!p) { return null; }
  if (ts.isPropertyAssignment(p)) { return p.initializer; }
  if (ts.isShorthandPropertyAssignment(p)) { return p.name; }
  return null;
}
function decorators(m) {
  const ds = (ts.getAllDecorators ? ts.getAllDecorators(m) : m.decorators) || [];
  return ds.map((d) => compact(d.expression));
}
function enclosingFunction(node) {
  let n = node.parent;
  while (n && !isFunctionLike(n)) { n = n.parent; }
  return n || null;
}
function enclosingMember(node) {
  let n = node.parent;
  while (n && !(ts.isMethodDeclaration(n) || ts.isConstructorDeclaration(n) || ts.isFunctionDeclaration(n) ||
    ts.isPropertyDeclaration(n) || ts.isGetAccessorDeclaration(n))) { n = n.parent; }
  return n || null;
}
function enclosingContainer(node) {
  let n = node.parent;
  while (n && !ts.isStructDeclaration(n) && !ts.isClassDeclaration(n)) { n = n.parent; }
  return n || null;
}

// ---------------------------------------------------------------- 取值：模块 const、类静态只读字段、局部 const、三元、字符串拼接

/** 文件级 const（字符串 / 数字字面量）与各类的 static readonly 字符串字段（键 = 「类名.字段」）。 */
function staticTable(sf) {
  const out = new Map();
  if (!sf) { return out; }
  ts.forEachChild(sf, (n) => {
    if (ts.isVariableStatement(n) && (n.declarationList.flags & ts.NodeFlags.Const)) {
      for (const d of n.declarationList.declarations) {
        if (!ts.isIdentifier(d.name) || !d.initializer) { continue; }
        const init = unwrap(d.initializer);
        if (isStr(init)) { out.set(d.name.text, init.text); }
        else if (ts.isNumericLiteral(init)) { out.set(d.name.text, Number(init.text)); }
      }
    }
    if (ts.isClassDeclaration(n) && n.name) {
      for (const m of n.members) {
        if (!ts.isPropertyDeclaration(m) || !m.initializer) { continue; }
        const mods = (ts.getModifiers ? ts.getModifiers(m) : m.modifiers) || [];
        if (!mods.some((x) => x.kind === ts.SyntaxKind.StaticKeyword)) { continue; }
        const init = unwrap(m.initializer);
        if (isStr(init)) { out.set(n.name.text + '.' + memberName(m), init.text); }
      }
    }
  });
  // 计算出来的文件级 const（如 HELP_ID_PREFIX + 'frozen'）：按已知值再求一轮（最多 3 轮）。
  for (let round = 0; round < 3; round++) {
    let added = false;
    ts.forEachChild(sf, (n) => {
      if (!ts.isVariableStatement(n) || !(n.declarationList.flags & ts.NodeFlags.Const)) { return; }
      for (const d of n.declarationList.declarations) {
        if (!ts.isIdentifier(d.name) || !d.initializer || out.has(d.name.text)) { continue; }
        const v = values(d.initializer, out, 0, null);
        if (v && v.size === 1) { out.set(d.name.text, [...v][0]); added = true; }
      }
    });
    if (!added) { break; }
  }
  return out;
}
function mergedTable(...sfs) {
  const out = new Map();
  for (const sf of sfs) { for (const [k, v] of staticTable(sf)) { out.set(k, v); } }
  return out;
}
/** 在 node 所在的各层函数里找局部 const name 的初值。 */
function localConst(node, name) {
  let fn = enclosingFunction(node);
  while (fn) {
    let hit = null;
    walk(fn, (n) => {
      if (hit === null && ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === name && n.initializer &&
        n.parent && (n.parent.flags & ts.NodeFlags.Const)) { hit = n.initializer; }
    });
    if (hit) { return hit; }
    fn = enclosingFunction(fn);
  }
  return null;
}
const MAX_VALUES = 64;
/** 表达式可能取到的字符串 / 数字值集合；判不了为 null。facts 能定三元条件真假时只取那一支。 */
function values(e, table, depth, facts) {
  depth = depth || 0;
  if (depth > 10 || !e) { return null; }
  e = unwrap(e);
  if (isStr(e)) { return new Set([e.text]); }
  if (ts.isNumericLiteral(e)) { return new Set([Number(e.text)]); }
  if (ts.isConditionalExpression(e)) {
    const c = facts ? evalBool(e.condition, facts) : null;
    if (c === true) { return values(e.whenTrue, table, depth + 1, facts); }
    if (c === false) { return values(e.whenFalse, table, depth + 1, facts); }
    const a = values(e.whenTrue, table, depth + 1, facts);
    const b = values(e.whenFalse, table, depth + 1, facts);
    return a && b ? new Set([...a, ...b]) : null;
  }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.PlusToken) {
    const a = values(e.left, table, depth + 1, facts);
    const b = values(e.right, table, depth + 1, facts);
    if (!a || !b || a.size * b.size > MAX_VALUES) { return null; }
    const out = new Set();
    for (const x of a) { for (const y of b) { out.add(String(x) + String(y)); } }
    return out;
  }
  if (ts.isTemplateExpression(e)) {
    let acc = new Set([e.head.text]);
    for (const span of e.templateSpans) {
      const v = values(span.expression, table, depth + 1, facts);
      if (!v || acc.size * v.size > MAX_VALUES) { return null; }
      const next = new Set();
      for (const x of acc) { for (const y of v) { next.add(x + String(y) + span.literal.text); } }
      acc = next;
    }
    return acc;
  }
  if (ts.isIdentifier(e)) {
    const local = localConst(e, e.text);
    if (local) { return values(local, table, depth + 1, facts); }
    if (table.has(e.text)) { return new Set([table.get(e.text)]); }
    return null;
  }
  if (ts.isPropertyAccessExpression(e) && ts.isIdentifier(e.expression)) {
    const key = e.expression.text + '.' + e.name.text;
    if (table.has(key)) { return new Set([table.get(key)]); }
  }
  return null;
}

// ---------------------------------------------------------------- 路径事实（三元分支 / if 分支的条件，按紧凑文本记真假）

function newFacts() { return new Map(); }
function addFact(f, expr, pol) {
  const e = unwrap(expr);
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) { addFact(f, e.operand, !pol); return; }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken && pol) {
    addFact(f, e.left, true); addFact(f, e.right, true); return;
  }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.BarBarToken && !pol) {
    addFact(f, e.left, false); addFact(f, e.right, false); return;
  }
  f.set(compact(e), pol);
}
function evalBool(expr, f) {
  const e = unwrap(expr);
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) {
    const v = evalBool(e.operand, f);
    return v === null ? null : !v;
  }
  return f.has(compact(e)) ? f.get(compact(e)) : null;
}
/** node 到所在函数为止：三元的 whenTrue / whenFalse、if 的 then / else 记成事实。 */
function pathFacts(node) {
  const f = newFacts();
  let cur = node;
  while (cur && cur.parent && !isFunctionLike(cur)) {
    const p = cur.parent;
    if (ts.isConditionalExpression(p) && cur !== p.condition) { addFact(f, p.condition, cur === p.whenTrue); }
    if (ts.isIfStatement(p) && cur !== p.expression) { addFact(f, p.expression, cur === p.thenStatement); }
    cur = p;
  }
  return f;
}

// ---------------------------------------------------------------- 组件索引

class Comp {
  constructor(stmt, root, calls) {
    this.stmt = stmt;
    this.root = root;
    this.calls = calls;
    this.name = root.expression.getText();
    this.args = Array.from(root.arguments || []);
  }
  call(name) { return this.calls.filter((c) => c.name === name); }
  has(name) { return this.calls.some((c) => c.name === name); }
}
/** 节点（struct / 文件）里每个组件语句：内置组件（EtsComponentExpression）与首字母大写的自定义组件调用。 */
function componentsIn(node) {
  const comps = [];
  walk(node, (n) => {
    if (!ts.isExpressionStatement(n)) { return; }
    const ch = chainOf(n.expression);
    if (ch.root && (ts.isEtsComponentExpression(ch.root) ||
      (ts.isCallExpression(ch.root) && ts.isIdentifier(ch.root.expression) && /^[A-Z]/.test(ch.root.expression.text)))) {
      comps.push(new Comp(n, ch.root, ch.calls));
    }
  });
  return comps;
}
function idValues(comp, table) {
  const out = new Set();
  let unresolved = false;
  const push = (expr) => {
    const v = values(expr, table, 0, pathFacts(expr));
    if (v) { for (const x of v) { if (x !== '') { out.add(String(x)); } } } else { unresolved = true; }
  };
  for (const c of comp.call('id')) { push(c.args[0]); }
  if (comp.args[0] && ts.isObjectLiteralExpression(comp.args[0])) {
    for (const k of ['buttonId', 'retryId']) {
      const v = propValue(comp.args[0], k);
      if (v) { push(v); }
    }
  }
  out.unresolved = unresolved;
  return out;
}

// ---------------------------------------------------------------- AC1：订单【复制】读屏名带本行完整单号

function findSetCall(sf, key) {
  return collect(sf, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
    n.expression.name.text === 'set' && n.arguments.length === 2 && isStr(unwrap(n.arguments[0])) &&
    unwrap(n.arguments[0]).text === key);
}
function placeholders(text) {
  const out = [];
  const re = /\{([a-z0-9_]+)\}/g;
  let m;
  while ((m = re.exec(text)) !== null) { out.push(m[1]); }
  return out;
}

/** 单号表达式是不是「本行完整单号」：取 orderNo（OrderView.orderNo / OrderNumberDisplay 的 text），不经脱敏读法。 */
function fullOrderNo(v, facts, depth) {
  depth = depth || 0;
  if (!v || depth > 6) { return '判不了'; }
  v = unwrap(v);
  if (ts.isConditionalExpression(v)) {
    const c = evalBool(v.condition, facts);
    if (c === true) { return fullOrderNo(v.whenTrue, facts, depth + 1); }
    if (c === false) { return fullOrderNo(v.whenFalse, facts, depth + 1); }
    return fullOrderNo(v.whenTrue, facts, depth + 1) || fullOrderNo(v.whenFalse, facts, depth + 1);
  }
  if (ts.isIdentifier(v)) {
    const local = localConst(v, v.text);
    if (local) { return fullOrderNo(local, facts, depth + 1); }
  }
  const text = compact(v);
  if (/OrderNumberDisplay\.spoken|STAR|mask|spoken/i.test(text)) { return '是脱敏 / 读屏读法（' + text + '），不是完整单号'; }
  const ok = collect(v, (n) => (ts.isPropertyAccessExpression(n) && n.name.text === 'orderNo') ||
    (ts.isIdentifier(n) && n.text === 'orderNo')).length > 0 || /\['text'\]/.test(text);
  return ok ? '' : '不是本行单号（' + text + '）';
}

/**
 * copySpoken 实参的来源：沿 OrderView 字段 / this.<方法>() / 局部 const / 三元找到格式化调用。返回问题列表（空 = 合格）。
 * ctx = { table, kitSf, depth, facts }
 */
function resolveCopy(e, ctx, out) {
  const depth = ctx.depth || 0;
  if (depth > 8) { out.problems.push('来源嵌套太深，判不了'); return; }
  e = unwrap(e);
  const facts = ctx.facts || newFacts();
  if (isStr(e)) {
    if (e.text === '') { out.empty++; } else { out.problems.push('固定文字「' + e.text + '」'); }
    return;
  }
  if (ts.isConditionalExpression(e)) {
    const c = evalBool(e.condition, facts);
    if (c !== false) {
      const f = new Map(facts); addFact(f, e.condition, true);
      resolveCopy(e.whenTrue, Object.assign({}, ctx, { depth: depth + 1, facts: f }), out);
    }
    if (c !== true) {
      const f = new Map(facts); addFact(f, e.condition, false);
      resolveCopy(e.whenFalse, Object.assign({}, ctx, { depth: depth + 1, facts: f }), out);
    }
    return;
  }
  if (ts.isIdentifier(e)) {
    const local = localConst(e, e.text);
    if (local) { resolveCopy(local, Object.assign({}, ctx, { depth: depth + 1 }), out); return; }
    // 局部 let：初值与本函数里的每次赋值都算来源（各按自己的路径事实）。
    const fn = enclosingFunction(e);
    const decl = fn ? collect(fn, (n) => ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === e.text)[0] : null;
    if (decl) {
      const srcs = [];
      if (decl.initializer) { srcs.push(decl.initializer); }
      for (const a of collect(fn, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
        ts.isIdentifier(unwrap(n.left)) && unwrap(n.left).text === e.text)) { srcs.push(a.right); }
      for (const s of srcs) { resolveCopy(s, Object.assign({}, ctx, { depth: depth + 1, facts: pathFacts(s) }), out); }
      return;
    }
    out.problems.push('标识符 ' + e.text + ' 判不了来源');
    return;
  }
  if (ts.isCallExpression(e)) {
    const callee = unwrap(e.expression);
    const name = ts.isPropertyAccessExpression(callee) ? callee.name.text : (ts.isIdentifier(callee) ? callee.text : '');
    if (name === 'format' || name === 'fmt') { checkFormat(e, ctx, facts, out); return; }
    if (name === 't' || name === 'text') {
      out.problems.push(compact(e) + ' 只取固定文案，不带本行单号');
      return;
    }
    if (ts.isPropertyAccessExpression(callee) && isThis(callee.expression)) {
      const owner = enclosingContainer(e);
      const m = owner ? owner.members.find((x) => ts.isMethodDeclaration(x) && memberName(x) === name) : null;
      if (!m || !m.body) { out.problems.push('this.' + name + '() 找不到方法体'); return; }
      const rets = collect(m.body, (n) => ts.isReturnStatement(n) && n.expression && enclosingFunction(n) === m);
      if (rets.length === 0) { out.problems.push('this.' + name + '() 没有 return'); return; }
      for (const r of rets) { resolveCopy(r.expression, Object.assign({}, ctx, { depth: depth + 1, facts: pathFacts(r.expression) }), out); }
      return;
    }
    out.problems.push(compact(e) + ' 判不了来源');
    return;
  }
  if (ts.isPropertyAccessExpression(e)) {
    const field = e.name.text;
    const recv = unwrap(e.expression);
    const cls = isThis(recv) ? enclosingContainer(e) : (ctx.kitSf ? findClass(ctx.kitSf, 'OrderView') : null);
    if (!cls) { out.problems.push(compact(e) + '：找不到 OrderView 类'); return; }
    const decl = cls.members.find((m) => ts.isPropertyDeclaration(m) && memberName(m) === field);
    const getter = cls.members.find((m) => ts.isGetAccessorDeclaration(m) && memberName(m) === field);
    if (!decl && !getter) { out.problems.push(compact(e) + '：' + (cls.name ? cls.name.text : '类') + ' 没有字段 ' + field); return; }
    const sources = [];
    if (decl && decl.initializer) { sources.push(decl.initializer); }
    if (getter && getter.body) {
      for (const r of collect(getter.body, (n) => ts.isReturnStatement(n) && n.expression)) { sources.push(r.expression); }
    }
    for (const m of cls.members) {
      if (!(ts.isConstructorDeclaration(m) || ts.isMethodDeclaration(m)) || !m.body) { continue; }
      for (const a of collect(m.body, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
        ts.isPropertyAccessExpression(unwrap(n.left)) && isThis(unwrap(n.left).expression) && unwrap(n.left).name.text === field)) {
        sources.push(a.right);
      }
    }
    if (sources.length === 0) { out.problems.push(compact(e) + '：字段 ' + field + ' 没有赋值'); return; }
    for (const s of sources) { resolveCopy(s, Object.assign({}, ctx, { depth: depth + 1, facts: pathFacts(s) }), out); }
    return;
  }
  out.problems.push(compact(e) + ' 判不了来源');
}

function checkFormat(call, ctx, facts, out) {
  const keyArg = call.arguments[0];
  const keys = keyArg ? values(keyArg, ctx.table, 0, facts) : null;
  if (!keys || keys.size !== 1 || !keys.has(COPY_KEY)) {
    out.problems.push(compact(call) + ' 的键不是 ' + COPY_KEY + '（取到 ' + (keys ? [...keys].join(' / ') : '判不了') + '）');
    return;
  }
  const varsArg = call.arguments[1] ? unwrap(call.arguments[1]) : null;
  if (!varsArg || !ts.isIdentifier(varsArg)) {
    out.problems.push(compact(call) + ' 没有按 Map 变量代入 {no}');
    return;
  }
  const fn = enclosingFunction(call);
  const sets = collect(fn || call.getSourceFile(), (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
    n.expression.name.text === 'set' && ts.isIdentifier(unwrap(n.expression.expression)) &&
    unwrap(n.expression.expression).text === varsArg.text && n.arguments.length === 2);
  const names = new Set();
  for (const s of sets) {
    const k = unwrap(s.arguments[0]);
    if (isStr(k)) { names.add(k.text); }
  }
  for (const p of out.placeholders) {
    const hit = sets.filter((s) => isStr(unwrap(s.arguments[0])) && unwrap(s.arguments[0]).text === p);
    if (hit.length === 0) {
      out.problems.push(varsArg.text + ' 没有代入 {' + p + '}（只 set 了 ' + ([...names].join(', ') || '无') + '）');
      continue;
    }
    for (const s of hit) {
      const why = fullOrderNo(s.arguments[1], facts, 0);
      if (why) { out.problems.push('{' + p + '} 的值' + why); }
    }
  }
  out.ok++;
}

/** 契约文案表：DefaultTexts.buildTexts() 方法体（不含 buildFallbacks 的兜底表）；找不到即判定不完整。 */
function contractTexts(gen) {
  const cls = findClass(gen, 'DefaultTexts');
  const m = cls ? cls.members.find((x) => ts.isMethodDeclaration(x) && memberName(x) === 'buildTexts' && x.body) : null;
  if (!m) { incomplete.push(GEN_TEXTS + '：找不到 DefaultTexts.buildTexts()'); }
  return m ? m.body : null;
}

/** AC1-draft / AC1-label 共用：契约（DefaultTexts.buildTexts）里键恰一处、值 = 约定原文；草稿表里没有这个键（契约优先，草稿同名即死代码）。
 *  返回契约里的值（判不了返回 null）。 */
function checkContractKey(rule, key, want, why, gen, genBody, draft) {
  const sets = findSetCall(genBody, key);
  let value = null;
  if (sets.length !== 1 || !isStr(unwrap(sets[0].arguments[1]))) {
    report(rule, sets[0] || gen, '契约 DefaultTexts ' + key + ' 应恰有一处字面量（实际 ' + sets.length + ' 处）', GEN_TEXTS);
  } else {
    value = unwrap(sets[0].arguments[1]).text;
    if (value !== want) {
      report(rule, sets[0], '契约 DefaultTexts ' + key + ' 是「' + value + '」，' + why + ' 定为「' + want + '」', GEN_TEXTS);
    }
  }
  for (const d of findSetCall(draft, key)) {
    report(rule, d, '草稿表又有 ' + key + '（' + compact(d.arguments[1]) + '）：契约已有此键且优先，草稿同名是死代码，应删', DRAFT);
  }
  return value;
}

function checkCopy() {
  const draft = parse(DRAFT);
  const kit = parse(KIT);
  const gen = parse(GEN_TEXTS);
  if (!draft || !kit || !gen) { return; }
  const genBody = contractTexts(gen);
  if (!genBody) { return; }
  const value = checkContractKey('AC1-draft', COPY_KEY, COPY_VALUE, 'D10-1248 ⑨（读完整单号）', gen, genBody, draft);
  checkContractKey('AC1-label', LABEL_KEY, LABEL_VALUE, 'D10-1275', gen, genBody, draft);
  const phs = placeholders(value === null ? COPY_VALUE : value);
  if (phs.length === 0) { phs.push('no'); }
  const table = mergedTable(kit);
  for (const rel of [LIST, DETAIL]) {
    const sf = parse(rel);
    if (!sf) { continue; }
    const rows = componentsIn(sf).filter((c) => c.name === 'OrderNumberRow');
    if (rows.length === 0) {
      report('AC1-copy', sf, '没有 OrderNumberRow（订单号行 / 【复制】不见了）', rel);
      continue;
    }
    for (const r of rows) {
      stats.copyRows++;
      const lt = propValue(r.args[0], 'copyText');
      const lc = lt ? unwrap(lt) : null;
      const lk = lc && ts.isCallExpression(lc) && lc.arguments.length === 1 ? values(lc.arguments[0], mergedTable(kit, sf), 0, null) : null;
      if (!lk || lk.size !== 1 || !lk.has(LABEL_KEY)) {
        report('AC1-label', r.root, 'copyText = ' + (lt ? compact(lt) : '没给') + '：应取 ' + LABEL_KEY + '（D10-1275，取到 ' +
          (lk ? [...lk].join(' / ') : '判不了') + '）', rel);
      }
      const e = propValue(r.args[0], 'copySpoken');
      if (!e) { report('AC1-copy', r.root, 'OrderNumberRow 没给 copySpoken（【复制】读屏名不带单号）', rel); continue; }
      const out = { problems: [], ok: 0, empty: 0, placeholders: phs };
      resolveCopy(e, { table: mergedTable(kit, sf), kitSf: kit, depth: 0, facts: newFacts() }, out);
      if (out.ok === 0 && out.problems.length === 0) { out.problems.push('没有走到带 {no} 的格式化'); }
      for (const p of out.problems) {
        report('AC1-copy', r.root, 'copySpoken = ' + compact(e) + '：' + p + '（D10-1248 ⑨：读「复制订单号 {no}」，{no} = 本行完整单号）', rel);
      }
    }
  }
  void table;
}

// ---------------------------------------------------------------- AC2：问号说明关闭后焦点回问号

/** 函数体里 `const O = new CouliDialogOptions()` 的对象与其属性赋值。 */
class DialogSite {
  constructor(fn, name, decl) {
    this.fn = fn;
    this.name = name;
    this.decl = decl;
    this.assigns = new Map();
    for (const a of collect(fn.body, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      ts.isPropertyAccessExpression(unwrap(n.left)) && ts.isIdentifier(unwrap(unwrap(n.left).expression)) &&
      unwrap(unwrap(n.left).expression).text === name)) {
      const prop = unwrap(a.left).name.text;
      if (!this.assigns.has(prop)) { this.assigns.set(prop, []); }
      this.assigns.get(prop).push(a);
    }
  }
  values(prop) { return (this.assigns.get(prop) || []).map((a) => a.right); }
  one(prop) { const v = this.values(prop); return v.length > 0 ? v[v.length - 1] : null; }
  fnName() {
    if (ts.isMethodDeclaration(this.fn) || ts.isFunctionDeclaration(this.fn)) { return this.fn.name ? this.fn.name.text : ''; }
    return '';
  }
}
function dialogSites(sf) {
  const out = [];
  for (const d of collect(sf, (n) => ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.initializer &&
    ts.isNewExpression(unwrap(n.initializer)) && compact(unwrap(n.initializer).expression) === 'CouliDialogOptions')) {
    const fn = enclosingFunction(d);
    if (fn && fn.body) { out.push(new DialogSite(fn, d.name.text, d)); }
  }
  return out;
}
function stringLiterals(node) {
  return collect(node, (n) => isStr(n)).map((n) => n.text);
}

/** Wallet.ets 里 AmountGrid 问号 id 用的前缀参数名、WalletHeroCard 透传用的参数名；判不了为 null。 */
function gridPrefixParams() {
  const sf = parse(DS_WALLET);
  if (!sf) { return null; }
  const grid = findStruct(sf, 'AmountGrid');
  const hero = findStruct(sf, 'WalletHeroCard');
  if (!grid || !hero) {
    incomplete.push(DS_WALLET + '：找不到 struct ' + (!grid ? 'AmountGrid' : 'WalletHeroCard'));
    return null;
  }
  const params = (s) => new Set(s.members.filter((m) => ts.isPropertyDeclaration(m) && decorators(m).includes('Param')).map(memberName));
  const gridParams = params(grid);
  const heroParams = params(hero);
  const buttons = componentsIn(grid).filter((c) => c.call('onClick').some((oc) =>
    collect(oc.args[0] || oc.node, (n) => ts.isPropertyAccessExpression(n) && isThis(n.expression) && n.name.text === 'onHelp').length > 0));
  const res = { grid: null, hero: null };
  if (buttons.length === 0) {
    report('AC2-grid-id', grid, 'AmountGrid 里找不到调 this.onHelp 的问号按钮', DS_WALLET);
    return res;
  }
  for (const b of buttons) {
    const ids = b.call('id');
    if (ids.length === 0) {
      report('AC2-grid-id', b.root, 'AmountGrid 问号按钮没挂 id（说明弹窗关闭后焦点回不来）', DS_WALLET);
      continue;
    }
    for (const c of ids) {
      const arg = c.args[0];
      const thisParams = collect(arg, (n) => ts.isPropertyAccessExpression(n) && isThis(n.expression) && gridParams.has(n.name.text))
        .map((n) => n.name.text).filter((n) => n !== 'items' && n !== 'stackedItems');
      const usesIndex = collect(arg, (n) => ts.isIdentifier(n) && n.text === 'index').length > 0;
      const usesItem = collect(arg, (n) => ts.isPropertyAccessExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'item').length > 0;
      if (thisParams.length === 0) {
        report('AC2-grid-id', c.node, 'AmountGrid 问号 id 不带调用方给的前缀参数（@Param）：' + compact(arg), DS_WALLET);
      } else {
        res.grid = thisParams[0];
      }
      if (usesIndex) {
        report('AC2-grid-id', c.node, 'AmountGrid 问号 id 用了下标 index（横排 / 纵排顺序不同，回焦会落错格；要按条目）：' + compact(arg), DS_WALLET);
      }
      if (!usesItem) {
        report('AC2-grid-id', c.node, 'AmountGrid 问号 id 没按条目（item.<键>）区分：' + compact(arg), DS_WALLET);
      }
    }
  }
  if (res.grid !== null) {
    const inner = componentsIn(hero).filter((c) => c.name === 'AmountGrid');
    for (const g of inner) {
      const v = propValue(g.args[0], res.grid);
      const e = v ? unwrap(v) : null;
      if (e && ts.isPropertyAccessExpression(e) && isThis(e.expression) && heroParams.has(e.name.text)) {
        res.hero = e.name.text;
      } else {
        report('AC2-hero-pass', g.root, 'WalletHeroCard 内的 AmountGrid 没把调用方给的前缀（@Param）透传给 ' + res.grid +
          '（实际 ' + (v ? compact(v) : '没给') + '）', DS_WALLET);
      }
    }
    if (inner.length === 0) { report('AC2-hero-pass', hero, 'WalletHeroCard 里没有 AmountGrid', DS_WALLET); }
  }
  return res;
}

/** 调用点由什么触发：Button.onClick（返回组件）或 AmountGrid / WalletHeroCard 的 onHelp（返回组件 + 种类）。 */
function triggerOf(call, comps) {
  let n = call;
  while (n && n.parent) {
    const p = n.parent;
    if (ts.isPropertyAssignment(p) && memberName(p) === 'onHelp' && ts.isObjectLiteralExpression(p.parent) &&
      ts.isCallExpression(p.parent.parent) && ts.isIdentifier(p.parent.parent.expression)) {
      const kind = p.parent.parent.expression.text;
      return { kind: kind, comp: comps.find((c) => c.root === p.parent.parent) || null, obj: p.parent };
    }
    if (ts.isCallExpression(p) && ts.isPropertyAccessExpression(p.expression) && p.expression.name.text === 'onClick' &&
      p.arguments.indexOf(n) >= 0) {
      const comp = comps.find((c) => c.calls.some((x) => x.node === p)) || null;
      return { kind: 'onClick', comp: comp, obj: null };
    }
    if (ts.isMethodDeclaration(p) || ts.isStructDeclaration(p) || ts.isSourceFile(p)) { break; }
    n = p;
  }
  return null;
}

function checkHelp(prefixes) {
  for (const rel of [WALLET, WITHDRAW]) {
    const sf = parse(rel);
    if (!sf) { continue; }
    const table = staticTable(sf);
    const comps = componentsIn(sf);
    const sites = dialogSites(sf).filter((s) => s.values('primaryText').some((v) => stringLiterals(v).includes(HELP_OK)));
    const seen = [];
    let triggers = 0;
    if (sites.length === 0) {
      report('AC2-help-missing', sf, '找不到说明弹窗（primaryText = ' + HELP_OK + '）', rel);
    }
    for (const s of sites) {
      const rets = s.values('returnFocusId');
      if (rets.length === 0) {
        report('AC2-help-return', s.decl, '说明弹窗（' + s.fnName() + '）没设 returnFocusId：关闭后焦点不回问号', rel);
        const nm = s.fnName();
        triggers += nm ? collect(sf, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
          isThis(n.expression.expression) && n.expression.name.text === nm).length : 0;
        continue;
      }
      const ret = rets[rets.length - 1];
      const r0 = unwrap(ret);
      const fn = s.fn;
      const paramIndex = ts.isIdentifier(r0) && fn.parameters ? fn.parameters.findIndex((p) => ts.isIdentifier(p.name) && p.name.text === r0.text) : -1;
      const name = s.fnName();
      const calls = name ? collect(sf, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
        isThis(n.expression.expression) && n.expression.name.text === name) : [];
      if (calls.length === 0) {
        report('AC2-help-trigger', s.decl, '说明弹窗 ' + name + ' 没有调用点（判不了是哪个问号打开的）', rel);
      }
      for (const c of calls) {
        triggers++;
        const expr = paramIndex >= 0 ? c.arguments[paramIndex] : ret;
        const R = expr ? values(expr, table, 0, pathFacts(expr)) : null;
        if (!R || R.size === 0 || [...R].some((x) => x === '')) {
          report('AC2-help-return', c, '说明弹窗的 returnFocusId 解析不到非空的静态 id（' + (expr ? compact(expr) : '没传') + '）', rel);
          continue;
        }
        const t = triggerOf(c, comps);
        if (t === null) {
          report('AC2-help-trigger', c, '判不了这处说明弹窗由哪个问号打开（只认 Button.onClick 与 AmountGrid / WalletHeroCard 的 onHelp）', rel);
          continue;
        }
        if (t.kind === 'onClick') {
          const B = t.comp ? idValues(t.comp, table) : new Set();
          if (B.size === 0) {
            report('AC2-help-id', t.comp ? t.comp.root : c, '问号按钮没挂 id（returnFocusId ' + [...R].join(' / ') + ' 找不到落点）', rel);
          } else {
            for (const r of R) {
              if (!B.has(r)) {
                report('AC2-help-target', c, 'returnFocusId「' + r + '」不是打开它的问号的 id（问号 id ' + [...B].join(' / ') + '）', rel);
              }
            }
          }
        } else if (t.kind === 'AmountGrid' || t.kind === 'WalletHeroCard') {
          const prop = prefixes ? (t.kind === 'AmountGrid' ? prefixes.grid : prefixes.hero) : null;
          if (!prop) {
            report('AC2-help-id', c, t.kind + ' 没有可用的问号 id 前缀参数（见 Wallet.ets 的 AC2-grid-id / AC2-hero-pass）', rel);
          } else {
            const pv = propValue(t.obj, prop);
            const P = pv ? values(pv, table, 0, pathFacts(pv)) : null;
            if (!P || P.size === 0 || [...P].some((x) => x === '')) {
              report('AC2-help-id', t.comp ? t.comp.root : c, t.kind + ' 没给 ' + prop + '（或判不了 / 为空）：数字格问号不挂 id，关闭后焦点回不来', rel);
            } else {
              for (const r of R) {
                if (![...P].some((p) => r.startsWith(String(p)) && r.length > String(p).length)) {
                  report('AC2-help-target', c, 'returnFocusId「' + r + '」不是 ' + t.kind + ' 问号的 id（前缀 ' + [...P].join(' / ') + ' + 条目键）', rel);
                }
              }
            }
          }
        } else {
          report('AC2-help-trigger', c, '说明弹窗由 ' + t.kind + ' 打开，判不了问号 id', rel);
        }
        seen.push({ node: c, ids: R });
      }
    }
    stats.helpTriggers[rel] = triggers;
    const min = HELP_MIN.get(rel) || 0;
    if (triggers < min) {
      report('AC2-help-missing', sf, '说明弹窗的问号触发点只有 ' + triggers + ' 处（本页应 ≥ ' + min + '：钱包主卡冻结中 / 预估卡 / 暂停行；提现手续费）', rel);
    }
    // AC2-id-unique：各问号回焦 id 互不相同；页面上同一个 id 不得挂在两个组件上。
    for (let i = 0; i < seen.length; i++) {
      for (let j = i + 1; j < seen.length; j++) {
        const dup = [...seen[i].ids].filter((x) => seen[j].ids.has(x));
        if (dup.length > 0) {
          report('AC2-id-unique', seen[j].node, '两个问号回焦到同一个 id「' + dup.join(' / ') + '」（第 ' + lineOf(seen[i].node) + ' 行也是）', rel);
        }
      }
    }
    const byId = new Map();
    for (const c of comps) {
      for (const id of idValues(c, table)) {
        if (!byId.has(id)) { byId.set(id, []); }
        byId.get(id).push(c);
      }
    }
    const helpIds = new Set();
    for (const s of seen) { for (const x of s.ids) { helpIds.add(x); } }
    for (const id of helpIds) {
      const owners = byId.get(id) || [];
      if (owners.length > 1) {
        report('AC2-id-unique', owners[1].root, '问号 id「' + id + '」在本页挂了 ' + owners.length + ' 个组件', rel);
      }
    }
  }
}

// ---------------------------------------------------------------- AC3：点遮罩不关的确认弹窗，系统返回 / 读屏返回手势可关

function isTrue(e) { return e && unwrap(e).kind === ts.SyntaxKind.TrueKeyword; }
function blockChain(stmt, fn) {
  const out = [];
  let n = stmt.parent;
  while (n && n !== fn) {
    if (ts.isBlock(n) || ts.isSourceFile(n) || ts.isCaseClause(n) || ts.isDefaultClause(n)) { out.push(n); }
    n = n.parent;
  }
  return out;
}
function fnLabel(fn) {
  if (!fn) { return '<文件>'; }
  if ((ts.isMethodDeclaration(fn) || ts.isFunctionDeclaration(fn)) && fn.name) { return fn.name.text; }
  const m = enclosingMember(fn);
  return m && m.name ? memberName(m) + '/<匿名>' : '<匿名>';
}
function stmtOf(node) {
  let n = node;
  while (n && !ts.isExpressionStatement(n)) { n = n.parent; }
  return n;
}
function assignsTo(node, prop) {
  return collect(node, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
    ts.isPropertyAccessExpression(unwrap(n.left)) && unwrap(n.left).name.text === prop);
}

function checkBack(scan) {
  for (const rel of scan) {
    const sf = parse(rel);
    if (!sf) { continue; }
    stats.scanned++;
    for (const a of assignsTo(sf, 'backDismisses')) {
      if (!isTrue(a.right)) {
        report('AC3-back-false', a, compact(a) + '：backDismisses 只许设 true（缺省就是 false；显式关掉返回 = 读屏用户关不掉弹窗）', rel);
      }
    }
    for (const a of assignsTo(sf, 'dismissOnMask')) {
      if (isTrue(a.right)) { continue; }
      stats.maskSites++;
      const fn = enclosingFunction(a);
      const label = rel + '::' + fnLabel(fn);
      if (EXEMPT.has(label)) { continue; }
      const recv = compact(unwrap(a.left).expression);
      const stmt = stmtOf(a);
      const blocks = stmt ? blockChain(stmt, fn) : [];
      let ok = false;
      for (const b of blocks) {
        for (const s of b.statements) {
          if (!ts.isExpressionStatement(s)) { continue; }
          const e = unwrap(s.expression);
          if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.EqualsToken && ts.isPropertyAccessExpression(unwrap(e.left)) &&
            unwrap(e.left).name.text === 'backDismisses' && compact(unwrap(e.left).expression) === recv && isTrue(e.right)) { ok = true; }
        }
      }
      if (!ok) {
        report('AC3-back', a, label.split('::')[1] + '：' + recv + '.dismissOnMask = ' + compact(a.right) + ' 却没有同路设 ' + recv +
          '.backDismisses = true（系统返回 / 读屏返回手势关不掉；FU-HM-A11Y-07 共性 ④）', rel);
      }
    }
  }
}

/** 回调里调用的方法名集合（a.b.c() 取 c；f() 取 f）。 */
function callset(fnExpr) {
  const out = new Set();
  if (!fnExpr) { return out; }
  for (const c of collect(fnExpr, (n) => ts.isCallExpression(n))) {
    const callee = unwrap(c.expression);
    if (ts.isPropertyAccessExpression(callee)) { out.add(callee.name.text); }
    else if (ts.isIdentifier(callee)) { out.add(callee.text); }
  }
  return out;
}
function setEq(a, b) { return a.size === b.size && [...a].every((x) => b.has(x)); }
function fmtSet(s) { return s.size === 0 ? '无' : [...s].sort().join(', '); }

function checkExits() {
  for (const [rel, method] of PINNED) {
    const sf = parse(rel);
    if (!sf) { continue; }
    const sites = dialogSites(sf).filter((s) => s.fnName() === method);
    if (sites.length === 0) {
      report('AC3-mask', sf, '找不到 ' + method + ' 里的确认弹窗（方法改名 / 拆走要同步本守卫，走编排批）', rel);
      continue;
    }
    for (const s of sites) {
      const mask = s.one('dismissOnMask');
      if (!mask || unwrap(mask).kind !== ts.SyntaxKind.FalseKeyword) {
        report('AC3-mask', s.decl, method + '：dismissOnMask 不再是 false（资金 / 风控 / 验证类确认弹窗点遮罩不得关闭，只放开系统返回）', rel);
      }
      if (!isTrue(s.one('backDismisses'))) {
        report('AC3-back', s.decl, method + '：没有 backDismisses = true（本单 8 处之一）', rel);
      }
    }
  }
  for (const rel of FUND_FILES) {
    const sf = parse(rel);
    if (!sf) { continue; }
    for (const s of dialogSites(sf)) {
      const mask = s.one('dismissOnMask');
      if (!mask || isTrue(mask)) { continue; }
      const prim = s.one('primaryText');
      const keys = prim ? stringLiterals(prim) : [];
      const onPrimary = callset(s.one('onPrimary'));
      const onSecondary = callset(s.one('onSecondary'));
      const dismissed = s.one('onDismissed');
      const onDismissed = callset(dismissed);
      if (keys.some((k) => ACK_KEYS.has(k))) {
        if (!dismissed) {
          report('AC3-exit', s.decl, s.fnName() + '：风控类弹窗返回关闭没接 onDismissed（应与【知道了】同一出口：' + fmtSet(onPrimary) + '）', rel);
        } else if (onPrimary.size === 0 || !setEq(onDismissed, onPrimary)) {
          report('AC3-exit', dismissed, s.fnName() + '：返回关闭调 ' + fmtSet(onDismissed) + '，【知道了】调 ' + fmtSet(onPrimary) +
            '（D10-1248 ③：返回只能等同现有【知道了】）', rel);
        }
      } else if (keys.some((k) => DESTRUCTIVE_KEYS.has(k))) {
        const extra = [...onDismissed].filter((x) => !onSecondary.has(x));
        if (dismissed && (extra.length > 0 || [...onDismissed].some((x) => onPrimary.has(x) || /abandon/i.test(x)))) {
          report('AC3-exit', dismissed, s.fnName() + '：返回关闭调 ' + fmtSet(onDismissed) + '（D10-1248 ③：放弃确认的返回只能等同【取消】，不得执行 ' +
            fmtSet(onPrimary) + ' 或新增资金动作）', rel);
        }
      } else {
        report('AC3-exit', s.decl, s.fnName() + '：资金页确认弹窗主按钮键 ' + (keys.join(' / ') || '判不了') + ' 未分类（确认类 / 放弃类），返回出口判不了', rel);
      }
    }
  }
  const bind = parse(BIND);
  if (bind) {
    for (const s of dialogSites(bind)) {
      if (!callset(s.one('onPrimary')).has('mergeDecided')) { continue; }
      const d = s.one('onDismissed');
      const sec = s.one('onSecondary');
      if (!d || !sec || compact(d) !== compact(sec)) {
        report('AC3-exit', d || s.decl, s.fnName() + '：合并确认的返回关闭应与【取消】同一出口（onDismissed ' + (d ? compact(d) : '没接') +
          ' / onSecondary ' + (sec ? compact(sec) : '没接') + '）', BIND);
      }
    }
  }
}

// ---------------------------------------------------------------- 主流程

for (const rel of [DRAFT, GEN_TEXTS, KIT, LIST, DETAIL, DS_WALLET, WALLET, WITHDRAW, PAYOUT, LOGIN, BIND]) { parse(rel); }
const structs = [[LIST, 'OrderListView'], [DETAIL, 'OrderDetailView'], [WALLET, 'WalletView'], [WITHDRAW, 'WithdrawView'],
  [PAYOUT, 'PayoutAccountPage'], [LOGIN, 'LoginView'], [BIND, 'BindPhoneView']];
for (const [rel, name] of structs) {
  const sf = parsed.get(rel);
  if (sf && !findStruct(sf, name)) { incomplete.push(rel + '：找不到 struct ' + name); }
}
if (parsed.get(KIT) && !findClass(parsed.get(KIT), 'OrderView')) { incomplete.push(KIT + '：找不到 class OrderView'); }
if (incomplete.length === 0) {
  checkCopy();
  checkHelp(gridPrefixParams());
  checkBack(input.scan || []);
  checkExits();
}
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete, stats: stats }));
