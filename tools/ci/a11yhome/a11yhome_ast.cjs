#!/usr/bin/env node
// FU-HM-A11Y-HOME-SEARCH-harmony 宿主守卫的解析部分（由 check_a11y_home_search.py 调用，不单独跑）。用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS，
// 判定全部走 AST（struct / 组件属性链 / @Builder 调用点与形参代入 / 类方法 / bindSheet 选项），不用正则切块，注释与字符串里的字不算。
// 写法照 tools/ci/loginphone/loginphone_ast.cjs。
//   用法：node a11yhome_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>"}}（HomeCards.ets、SearchView.ets、SearchDraftTexts.ets、契约 texts.default.json）
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."]}
// 规则编号见 check_a11y_home_search.py 文件头。
'use strict';
const fs = require('fs');
const path = require('path');

const HOME = 'features/home/src/main/ets/HomeCards.ets';
const SEARCH = 'features/search/src/main/ets/SearchView.ets';
const DRAFT = 'entry/src/main/ets/search/SearchDraftTexts.ets';
const CONTRACT = 'contracts/snapshot/contracts/texts.default.json';

const ID_POPUP_CLOSE = 'home_popup_close';
const ID_NOTICE_CLOSE = 'home_notice_close';
const ID_FILTER_PRICE = 'search_filter_price';
const ID_PRICE_TITLE = 'search_price_title';
const ID_PRICE_MIN = 'search_price_min';
const ID_PRICE_MAX = 'search_price_max';
const ID_PRICE_CONFIRM = 'search_price_confirm';
const ID_SEARCH_INPUT = 'search_input';
const KEY_PLACEHOLDER = 'search.placeholder';

const tsDir = process.argv[2];
if (!tsDir) { console.error('a11yhome_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('a11yhome_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('a11yhome_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
    process.exit(3);
  }
  return { ets: cfg.compilerOptions.ets, etsLoaderPath: path.dirname(cfgPath) };
}
const ETS_OPTIONS = etsOptions();

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const violations = [];
const incomplete = [];

function parse(rel) {
  const text = input.files[rel];
  if (text === undefined || text === null) {
    incomplete.push(rel + '：文件不存在，无法判定');
    return null;
  }
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, ETS_OPTIONS);
  if (sf.parseDiagnostics.length > 0) {
    const d = sf.parseDiagnostics[0];
    incomplete.push(rel + ':' + (sf.getLineAndCharacterOfPosition(d.start).line + 1) + ' 语法错误：' +
      ts.flattenDiagnosticMessageText(d.messageText, ' '));
    return null;
  }
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
function findTop(sf, pred, name) {
  let hit = null;
  ts.forEachChild(sf, (n) => { if (pred(n) && n.name && n.name.text === name) { hit = n; } });
  return hit;
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
  if (ts.isMethodDeclaration(p)) { return p; }
  return null;
}
/** 模块级 const 的字面量值（字符串 / 数字），以及类的 static readonly 字符串常量（键 "类名.成员"）。 */
function moduleConsts(sf) {
  const out = new Map();
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
        if (!ts.isPropertyDeclaration(m) || !m.initializer || !m.modifiers) { continue; }
        const mods = m.modifiers.map((x) => x.kind);
        if (mods.indexOf(ts.SyntaxKind.StaticKeyword) < 0 || mods.indexOf(ts.SyntaxKind.ReadonlyKeyword) < 0) { continue; }
        const init = unwrap(m.initializer);
        if (isStr(init)) { out.set(n.name.text + '.' + memberName(m), init.text); }
      }
    }
  });
  return out;
}
function enclosingFunction(node) {
  let n = node.parent;
  while (n && !ts.isMethodDeclaration(n) && !ts.isFunctionDeclaration(n) && !ts.isArrowFunction(n) && !ts.isFunctionExpression(n) &&
    !ts.isConstructorDeclaration(n) && !ts.isGetAccessorDeclaration(n)) { n = n.parent; }
  return n || null;
}
function enclosingMethod(node) {
  let n = node.parent;
  while (n && !ts.isMethodDeclaration(n)) { n = n.parent; }
  return n || null;
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

// ---------------------------------------------------------------- 求值（带 @Builder 形参代入环境 env：Map<形参名, {expr, env}>）

/** 表达式可能取到的字符串 / 数字值集合；判不了为 null。 */
function values(e, consts, env, depth) {
  depth = depth || 0;
  if (depth > 10 || !e) { return null; }
  e = unwrap(e);
  if (isStr(e)) { return new Set([e.text]); }
  if (ts.isNumericLiteral(e)) { return new Set([Number(e.text)]); }
  if (ts.isConditionalExpression(e)) {
    const a = values(e.whenTrue, consts, env, depth + 1);
    const b = values(e.whenFalse, consts, env, depth + 1);
    return a && b ? new Set([...a, ...b]) : null;
  }
  if (ts.isIdentifier(e)) {
    if (env && env.has(e.text)) { const b = env.get(e.text); return values(b.expr, consts, b.env, depth + 1); }
    const local = localConst(e, e.text);
    if (local) { return values(local, consts, env, depth + 1); }
    if (consts.has(e.text)) { return new Set([consts.get(e.text)]); }
    return null;
  }
  if (ts.isPropertyAccessExpression(e) && ts.isIdentifier(e.expression)) {
    const k = e.expression.text + '.' + e.name.text;
    if (consts.has(k)) { return new Set([consts.get(k)]); }
  }
  return null;
}

/** 表达式（经 env 里的形参绑定）解析到最终的表达式与其所在 env。 */
function resolveExpr(e, env, depth) {
  depth = depth || 0;
  e = unwrap(e);
  while (depth < 10 && ts.isIdentifier(e) && env && env.has(e.text)) {
    const b = env.get(e.text);
    e = unwrap(b.expr);
    env = b.env;
    depth++;
  }
  return { expr: e, env: env };
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
  last(name) { const c = this.call(name); return c.length > 0 ? c[c.length - 1] : null; }
}

function indexStruct(struct) {
  const comps = [];
  const byRoot = new Map();
  walk(struct, (n) => {
    if (!ts.isExpressionStatement(n)) { return; }
    const ch = chainOf(n.expression);
    if (ch.root && (ts.isEtsComponentExpression(ch.root) ||
      (ts.isCallExpression(ch.root) && ts.isIdentifier(ch.root.expression) && /^[A-Z]/.test(ch.root.expression.text)))) {
      const c = new Comp(n, ch.root, ch.calls);
      comps.push(c);
      byRoot.set(ch.root, c);
    }
  });
  const methods = new Map();
  for (const m of struct.members) {
    if (ts.isMethodDeclaration(m)) { methods.set(memberName(m), m); }
  }
  const builderCalls = new Map();
  walk(struct, (n) => {
    if (!ts.isExpressionStatement(n)) { return; }
    const e = unwrap(n.expression);
    if (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression) && e.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
      const name = e.expression.name.text;
      if (!builderCalls.has(name)) { builderCalls.set(name, []); }
      builderCalls.get(name).push(n);
    }
  });
  return { struct, comps, byRoot, methods, builderCalls };
}

/** node 执行时的形参绑定（每个 @Builder 调用点一条；build 或无形参的方法为 [null]）。 */
function bindingsAt(idx, node, depth) {
  depth = depth || 0;
  const m = enclosingMethod(node);
  if (!m || depth > 6) { return [null]; }
  const name = memberName(m);
  const calls = idx.builderCalls.get(name) || [];
  if (name === 'build' || m.parameters.length === 0 || calls.length === 0) { return [null]; }
  const out = [];
  for (const s of calls) {
    const call = unwrap(s.expression);
    for (const outer of bindingsAt(idx, s, depth + 1)) {
      const env = new Map();
      m.parameters.forEach((p, i) => {
        if (ts.isIdentifier(p.name) && call.arguments[i]) { env.set(p.name.text, { expr: call.arguments[i], env: outer }); }
      });
      out.push(env);
    }
  }
  return out;
}

function idValues(comp, consts, env) {
  if (comp.name === 'CouliButton') {
    const v = propValue(comp.args[0], 'buttonId');
    return v ? (values(v, consts, env) || new Set()) : new Set();
  }
  const out = new Set();
  for (const c of comp.call('id')) {
    const v = values(c.args[0], consts, env);
    if (v) { for (const x of v) { out.add(x); } }
  }
  return out;
}

/** 组件的每个实例（每个 @Builder 调用路径一个）：{ comp, env, ids }。 */
function instances(idx, consts, comp) {
  return bindingsAt(idx, comp.stmt).map((env) => ({ comp: comp, env: env, ids: idValues(comp, consts, env) }));
}

function isStaticCall(n, cls, method) {
  return ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && ts.isIdentifier(n.expression.expression) &&
    n.expression.expression.text === cls && n.expression.name.text === method;
}

// ---------------------------------------------------------------- 不可执行代码（v2，Codex r1 S2-2）
// 判定只认「会执行」的调用：常量为假的 if / 三元 / && 分支、常量为真的 else / || 右侧、常量为假的 while / for 循环体、
// 同一语句列表里在 return / throw / break / continue（或两支都退出的 if、总会退出的块）之后的语句、从不调用的函数体
// （裸箭头语句、void、声明后再没被引用的局部函数）里的调用，都不算移焦 / 播报。只在确定不可执行时才排除（判不了按可执行）。

const BOOL_CONST_CACHE = new Map();
/** 模块级 const 的布尔 / 数字 / 字符串字面量（常量条件用）。 */
function literalConsts(sf) {
  if (BOOL_CONST_CACHE.has(sf)) { return BOOL_CONST_CACHE.get(sf); }
  const out = new Map();
  ts.forEachChild(sf, (n) => {
    if (ts.isVariableStatement(n) && (n.declarationList.flags & ts.NodeFlags.Const)) {
      for (const d of n.declarationList.declarations) {
        if (ts.isIdentifier(d.name) && d.initializer) { out.set(d.name.text, d.initializer); }
      }
    }
  });
  BOOL_CONST_CACHE.set(sf, out);
  return out;
}
/** 表达式的常量值（true / false / 数字 / 字符串 / null）；不是常量为 undefined。 */
function constValue(e, depth) {
  depth = depth || 0;
  e = unwrap(e);
  if (!e || depth > 8) { return undefined; }
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (e.kind === ts.SyntaxKind.NullKeyword) { return null; }
  if (ts.isNumericLiteral(e)) { return Number(e.text); }
  if (isStr(e)) { return e.text; }
  if (ts.isIdentifier(e)) {
    if (e.text === 'undefined') { return null; }
    const local = localConst(e, e.text);
    if (local) { return constValue(local, depth + 1); }
    const mod = literalConsts(e.getSourceFile()).get(e.text);
    return mod ? constValue(mod, depth + 1) : undefined;
  }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) {
    const v = constValue(e.operand, depth + 1);
    return v === undefined ? undefined : !v;
  }
  if (ts.isBinaryExpression(e)) {
    const k = e.operatorToken.kind;
    const a = constValue(e.left, depth + 1);
    if (k === ts.SyntaxKind.AmpersandAmpersandToken) {
      if (a !== undefined && !a) { return a; }
      const b = constValue(e.right, depth + 1);
      return a !== undefined && b !== undefined ? b : (b !== undefined && !b ? false : undefined);
    }
    if (k === ts.SyntaxKind.BarBarToken) {
      if (a !== undefined && a) { return a; }
      const b = constValue(e.right, depth + 1);
      return a !== undefined && b !== undefined ? b : (b !== undefined && b ? true : undefined);
    }
    const b = constValue(e.right, depth + 1);
    if (a === undefined || b === undefined) { return undefined; }
    switch (k) {
      case ts.SyntaxKind.EqualsEqualsEqualsToken: case ts.SyntaxKind.EqualsEqualsToken: return a === b;
      case ts.SyntaxKind.ExclamationEqualsEqualsToken: case ts.SyntaxKind.ExclamationEqualsToken: return a !== b;
      case ts.SyntaxKind.GreaterThanToken: return a > b;
      case ts.SyntaxKind.GreaterThanEqualsToken: return a >= b;
      case ts.SyntaxKind.LessThanToken: return a < b;
      case ts.SyntaxKind.LessThanEqualsToken: return a <= b;
      default: return undefined;
    }
  }
  return undefined;
}
function constTruth(e) { const v = constValue(e); return v === undefined ? undefined : !!v; }
function isFn(n) { return ts.isArrowFunction(n) || ts.isFunctionExpression(n) || ts.isFunctionDeclaration(n) || ts.isMethodDeclaration(n); }
/** 语句是否一定退出所在语句列表（之后的兄弟语句不可执行）。 */
function alwaysExits(st) {
  if (!st) { return false; }
  if (ts.isReturnStatement(st) || ts.isThrowStatement(st) || ts.isBreakStatement(st) || ts.isContinueStatement(st)) { return true; }
  if (ts.isBlock(st)) { return st.statements.some(alwaysExits); }
  if (ts.isIfStatement(st)) {
    const c = constTruth(st.expression);
    if (c === true) { return alwaysExits(st.thenStatement); }
    if (c === false) { return !!st.elseStatement && alwaysExits(st.elseStatement); }
    return !!st.elseStatement && alwaysExits(st.thenStatement) && alwaysExits(st.elseStatement);
  }
  return false;
}
/** 函数（或包着函数的对象字面量）值会不会被调用：只在确定不会时返回 false。 */
function valueUsed(n) {
  let cur = n;
  let p = n.parent;
  while (p && (ts.isParenthesizedExpression(p) || ts.isAsExpression(p) || ts.isNonNullExpression(p))) { cur = p; p = p.parent; }
  if (!p) { return true; }
  if (ts.isExpressionStatement(p) || ts.isVoidExpression(p)) { return false; }
  if (ts.isPropertyAssignment(p) && p.initializer === cur && ts.isObjectLiteralExpression(p.parent)) { return valueUsed(p.parent); }
  if (ts.isVariableDeclaration(p) && p.initializer === cur && ts.isIdentifier(p.name)) {
    const name = p.name.text;
    const scope = enclosingFunction(p) || p.getSourceFile();
    let used = false;
    walk(scope, (x) => { if (!used && ts.isIdentifier(x) && x.text === name && x !== p.name) { used = true; } });
    return used;
  }
  return true;
}
/** node 是否确定不可执行（向上走到所在方法为止；root 是扫描起点：回调实参或被调用的方法体，本身按会被调用算）。 */
function isDead(node, root) {
  let cur = node;
  let p = node.parent;
  while (p) {
    if (ts.isIfStatement(p)) {
      const c = constTruth(p.expression);
      if ((cur === p.thenStatement && c === false) || (cur === p.elseStatement && c === true)) { return true; }
    } else if (ts.isConditionalExpression(p)) {
      const c = constTruth(p.condition);
      if ((cur === p.whenTrue && c === false) || (cur === p.whenFalse && c === true)) { return true; }
    } else if (ts.isBinaryExpression(p) && cur === p.right) {
      const k = p.operatorToken.kind;
      const c = constTruth(p.left);
      if ((k === ts.SyntaxKind.AmpersandAmpersandToken && c === false) || (k === ts.SyntaxKind.BarBarToken && c === true)) { return true; }
    } else if ((ts.isWhileStatement(p) || ts.isForStatement(p)) && cur === p.statement) {
      if (p.condition !== undefined || ts.isWhileStatement(p)) {
        if (constTruth(ts.isWhileStatement(p) ? p.expression : p.condition) === false) { return true; }
      }
    } else if (ts.isBlock(p) || ts.isCaseClause(p) || ts.isDefaultClause(p) || ts.isSourceFile(p)) {
      for (const st of p.statements) {
        if (st === cur) { break; }
        if (alwaysExits(st)) { return true; }
      }
    }
    // 走到方法 / 函数声明为止（被 this.<方法>() 调到的方法体按会执行算）；root 以外的箭头 / 函数表达式要确有调用。
    if (ts.isMethodDeclaration(p) || ts.isFunctionDeclaration(p) || ts.isConstructorDeclaration(p) || ts.isGetAccessorDeclaration(p) ||
      ts.isSetAccessorDeclaration(p)) { return false; }
    if (isFn(p) && p !== root && !valueUsed(p)) { return true; }
    cur = p;
    p = p.parent;
  }
  return false;
}

/** 范围里（含嵌套箭头函数），以及经 this.<方法>() 展开的方法体里，找满足 pred 且会执行的调用（v2：不可执行代码不算）。 */
function reachableCalls(idx, scope, pred) {
  const out = [];
  const seen = new Set();
  function scan(node, depth) {
    walk(node, (n) => {
      if (!ts.isCallExpression(n)) { return; }
      if (isDead(n, node)) { return; }
      if (pred(n)) { out.push(n); }
      if (depth < 4 && ts.isPropertyAccessExpression(n.expression) && n.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
        const m = idx.methods.get(n.expression.name.text);
        if (m && !seen.has(m) && m.body) { seen.add(m); scan(m.body, depth + 1); }
      }
    });
  }
  for (const s of (Array.isArray(scope) ? scope : [scope])) { if (s) { scan(s, 0); } }
  return out;
}

/**
 * 与赋值「同路执行」的语句：从赋值所在语句向外逐层取同一语句列表里的兄弟语句，但跳过分支语句（if / switch：另一条路径），
 * 到 case 分支或函数体为止（同 loginphone LP4-say）。
 */
function unconditionalScope(assign) {
  let cur = assign;
  while (cur && !ts.isExpressionStatement(cur)) { cur = cur.parent; }
  if (!cur) { return []; }
  const out = [cur];
  for (;;) {
    const p = cur.parent;
    if (!p) { break; }
    if (ts.isBlock(p) || ts.isCaseClause(p) || ts.isDefaultClause(p)) {
      for (const s of p.statements) {
        if (s !== cur && !ts.isIfStatement(s) && !ts.isSwitchStatement(s)) { out.push(s); }
      }
      if (ts.isCaseClause(p) || ts.isDefaultClause(p) || (p.parent && (ts.isMethodDeclaration(p.parent) ||
        ts.isArrowFunction(p.parent) || ts.isFunctionDeclaration(p.parent) || ts.isFunctionExpression(p.parent)))) { break; }
    }
    cur = p;
  }
  return out;
}

// ---------------------------------------------------------------- 焦点移动

/**
 * 范围里的焦点移动：CouliFocusReturn.to（键盘 + 读屏）、CouliFocusReturn.accessibilityFocus（只读屏）、
 * <…>.getFocusController().requestFocus(id)（只键盘）。ids 判不了为 null。
 */
function focusMoves(idx, consts, scope) {
  const isKbd = (n) => ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === 'requestFocus' &&
    /getFocusController\(\)$/.test(compact(n.expression.expression));
  const calls = reachableCalls(idx, scope, (n) => isStaticCall(n, 'CouliFocusReturn', 'to') ||
    isStaticCall(n, 'CouliFocusReturn', 'accessibilityFocus') || isKbd(n));
  return calls.map((n) => {
    const kind = isStaticCall(n, 'CouliFocusReturn', 'to') ? 'to' : (isKbd(n) ? 'kbd' : 'a11y');
    const arg = kind === 'kbd' ? n.arguments[0] : n.arguments[1];
    return { kind: kind, ids: arg ? values(arg, consts, null) : null, call: n };
  });
}
function exactly(ids, id) { return ids !== null && ids.size === 1 && ids.has(id); }
function describeMove(m) {
  return m.kind + '(' + (m.ids === null ? '判不了' : [...m.ids].join(' / ')) + ')@' + lineOf(m.call);
}
/** 移焦判定：a11y = 有读屏焦点移到 id；kbd = 有键盘焦点移到 id；wrong = 读屏焦点移到别处或判不了的调用。 */
function judgeMoves(moves, id) {
  return {
    a11y: moves.some((m) => (m.kind === 'to' || m.kind === 'a11y') && exactly(m.ids, id)),
    kbd: moves.some((m) => (m.kind === 'to' || m.kind === 'kbd') && exactly(m.ids, id)),
    wrong: moves.filter((m) => (m.kind === 'to' || m.kind === 'a11y') && !exactly(m.ids, id)).map(describeMove),
  };
}
function callbackArgs(comps, name) {
  const out = [];
  for (const c of comps) { for (const call of c.call(name)) { if (call.args[0]) { out.push(call.args[0]); } } }
  return out;
}

// ---------------------------------------------------------------- AH1 首页弹窗打开：读屏焦点 + 键盘焦点到关闭

function checkPopup(file, idx, consts) {
  const close = idx.comps.filter((c) => idValues(c, consts, null).has(ID_POPUP_CLOSE));
  const frame = idx.comps.filter((c) => idValues(c, consts, null).has('home_popup'));
  if (close.length === 0 || frame.length === 0) {
    report('AH1-missing', idx.struct, 'HomePopupView 找不到 home_popup / home_popup_close（hm07v 钉住的 id 不得改）', file);
    return;
  }
  const roots = callbackArgs(idx.comps, 'onAppear');
  const moves = focusMoves(idx, consts, roots);
  const j = judgeMoves(moves, ID_POPUP_CLOSE);
  if (!j.a11y) {
    report('AH1-a11y', frame[0].root, '弹窗出现时没有把读屏焦点移到 home_popup_close（只 getFocusController().requestFocus 是键盘焦点；' +
      '应 CouliFocusReturn.to / accessibilityFocus）' + (moves.length ? '；现有：' + moves.map(describeMove).join(', ') : ''), file);
  }
  if (!j.kbd) {
    report('AH1-kbd', frame[0].root, '弹窗出现时键盘焦点不再移到 home_popup_close（Hm07vOverlayUi:185 钉住；CouliFocusReturn.to 两种都移）', file);
  }
  if (j.wrong.length > 0) {
    report('AH1-wrong', frame[0].root, '弹窗出现时读屏焦点还会移到别处 / 判不了：' + j.wrong.join(', '), file);
  }
}

// ---------------------------------------------------------------- AH2 公告关闭名带行标识

/** this.<方法>(…)（方法体只有一句 return）展开成 return 表达式 + 形参绑定；最多 3 层。 */
function expandThisCall(e, env) {
  for (let i = 0; i < 3; i++) {
    const r = resolveExpr(e, env);
    e = r.expr; env = r.env;
    if (!(ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression) && e.expression.expression.kind === ts.SyntaxKind.ThisKeyword)) {
      break;
    }
    const m = IDX_FOR_EXPAND.methods.get(e.expression.name.text);
    if (!m || !m.body || m.body.statements.length !== 1 || !ts.isReturnStatement(m.body.statements[0]) || !m.body.statements[0].expression) {
      break;
    }
    const next = new Map();
    m.parameters.forEach((p, k) => { if (ts.isIdentifier(p.name) && e.arguments[k]) { next.set(p.name.text, { expr: e.arguments[k], env: env }); } });
    e = unwrap(m.body.statements[0].expression);
    env = next;
  }
  return { expr: unwrap(e), env: env };
}
let IDX_FOR_EXPAND = null;

function checkNotice(file, idx, consts) {
  IDX_FOR_EXPAND = idx;
  const closes = idx.comps.filter((c) => idValues(c, consts, null).has(ID_NOTICE_CLOSE));
  if (closes.length === 0) {
    report('AH2-missing', idx.struct, 'HomeNoticeCard 找不到 home_notice_close（hm07v 设备钉住的 id 不得改）', file);
    return;
  }
  for (const c of closes) {
    const at = c.last('accessibilityText');
    if (!at || !at.args[0]) {
      report('AH2-label', c.root, 'home_notice_close 没有 accessibilityText', file);
      continue;
    }
    const top = expandThisCall(at.args[0], null);
    if (!isStaticCall(top.expr, 'HomeNoticeA11y', 'closeLabel')) {
      report('AH2-label', at.node, 'home_notice_close 的读屏名不是 HomeNoticeA11y.closeLabel(row.item.text)（现为 ' + compact(at.args[0]) +
        '；每条同名「关闭公告」= 没有行标识；直接拼接也不收：前 12 字截断只在 closeLabel 里由逻辑层钉住）', file);
      continue;
    }
    const arg = top.expr.arguments[0] ? resolveExpr(top.expr.arguments[0], top.env).expr : null;
    let ok = false;
    if (arg && ts.isPropertyAccessExpression(arg) && arg.name.text === 'text' && ts.isPropertyAccessExpression(arg.expression) &&
      arg.expression.name.text === 'item') {
      const base = resolveExpr(arg.expression.expression, top.env).expr;
      const m = enclosingMethod(c.stmt);
      ok = !!(base && ts.isIdentifier(base) && m && m.parameters.some((p) => ts.isIdentifier(p.name) && p.name.text === base.text &&
        p.type && /HomeNoticeRow/.test(p.type.getText())));
    }
    if (!ok) {
      report('AH2-row', at.node, 'closeLabel 的实参不是本行公告正文 <row>.item.text（row = 该关闭按钮所在 @Builder 的 HomeNoticeRow 形参；现为 ' +
        (top.expr.arguments[0] ? compact(top.expr.arguments[0]) : '无') + '）', file);
    }
  }
}

// ---------------------------------------------------------------- AH3 价格半屏：焦点进标题、关闭回【价格】、校验错误播报并关联

// 说明实参的取值（同 loginphone T4，加形参代入）。OPAQUE = 未知文字但不是该错误；MARK = 该错误；null = 判不了。
const OPAQUE = '\u0002';
const MARK = '\u0001ERR\u0001';
function descValue(e, err, idx, env, depth) {
  if (depth > 8 || !e) { return null; }
  e = unwrap(e);
  if (isStr(e)) { return e.text; }
  if (ts.isNumericLiteral(e)) { return Number(e.text); }
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isIdentifier(e)) {
    if (env && env.has(e.text)) { const b = env.get(e.text); return descValue(b.expr, err, idx, b.env, depth + 1); }
    const local = localConst(e, e.text);
    return local ? descValue(local, err, idx, env, depth + 1) : null;
  }
  if (ts.isTemplateExpression(e)) {
    let s = e.head.text;
    for (const span of e.templateSpans) {
      const v = descValue(span.expression, err, idx, env, depth + 1);
      if (v === null) { return null; }
      s += String(v) + span.literal.text;
    }
    return s;
  }
  if (ts.isPropertyAccessExpression(e)) {
    if (/^this\.model$|^model$/.test(compact(e.expression))) { return e.name.text === err ? MARK : OPAQUE; }
    if (e.name.text === 'length') {
      const v = descValue(e.expression, err, idx, env, depth + 1);
      return typeof v === 'string' && v.indexOf(OPAQUE) < 0 ? v.length : null;
    }
    return OPAQUE;
  }
  if (ts.isCallExpression(e)) {
    if (ts.isPropertyAccessExpression(e.expression) && e.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
      const m = idx.methods.get(e.expression.name.text);
      if (m && m.body && m.body.statements.length === 1 && ts.isReturnStatement(m.body.statements[0])) {
        const next = new Map();
        m.parameters.forEach((p, k) => { if (ts.isIdentifier(p.name) && e.arguments[k]) { next.set(p.name.text, { expr: e.arguments[k], env: env }); } });
        return descValue(m.body.statements[0].expression, err, idx, next, depth + 1);
      }
    }
    const carries = e.arguments.some((a) => { const v = descValue(a, err, idx, env, depth + 1); return typeof v === 'string' && v.indexOf(MARK) >= 0; });
    return carries ? MARK + OPAQUE : OPAQUE;
  }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) {
    const v = descValue(e.operand, err, idx, env, depth + 1);
    return typeof v === 'boolean' ? !v : null;
  }
  if (ts.isConditionalExpression(e)) {
    const c = descValue(e.condition, err, idx, env, depth + 1);
    if (c === true) { return descValue(e.whenTrue, err, idx, env, depth + 1); }
    if (c === false) { return descValue(e.whenFalse, err, idx, env, depth + 1); }
    const a = descValue(e.whenTrue, err, idx, env, depth + 1);
    const b = descValue(e.whenFalse, err, idx, env, depth + 1);
    return typeof a === 'string' && typeof b === 'string' && a.indexOf(MARK) >= 0 && b.indexOf(MARK) >= 0 ? a : null;
  }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    const a = descValue(e.left, err, idx, env, depth + 1);
    if (op === ts.SyntaxKind.QuestionQuestionToken) { return a; }
    const b = descValue(e.right, err, idx, env, depth + 1);
    if (a === null || b === null) { return null; }
    if (op === ts.SyntaxKind.PlusToken) {
      return typeof a === 'number' && typeof b === 'number' ? a + b : String(a) + String(b);
    }
    if (op === ts.SyntaxKind.AmpersandAmpersandToken) { return typeof a === 'boolean' && typeof b === 'boolean' ? a && b : null; }
    if (op === ts.SyntaxKind.BarBarToken) { return typeof a === 'boolean' && typeof b === 'boolean' ? a || b : null; }
    const opaque = (v) => typeof v === 'string' && v.indexOf(OPAQUE) >= 0;
    if (opaque(a) || opaque(b) || typeof a === 'boolean' || typeof b === 'boolean') { return null; }
    switch (op) {
      case ts.SyntaxKind.GreaterThanToken: return a > b;
      case ts.SyntaxKind.GreaterThanEqualsToken: return a >= b;
      case ts.SyntaxKind.LessThanToken: return a < b;
      case ts.SyntaxKind.LessThanEqualsToken: return a <= b;
      case ts.SyntaxKind.EqualsEqualsEqualsToken: case ts.SyntaxKind.EqualsEqualsToken: return a === b;
      case ts.SyntaxKind.ExclamationEqualsEqualsToken: case ts.SyntaxKind.ExclamationEqualsToken: return a !== b;
      default: return null;
    }
  }
  return null;
}

/** 从 builder 名出发，经 this.<builder>() 调用语句能到的所有方法名。 */
function builderTree(idx, start) {
  const seen = new Set();
  const stack = [start];
  while (stack.length) {
    const name = stack.pop();
    if (seen.has(name) || !idx.methods.has(name)) { continue; }
    seen.add(name);
    for (const [callee, stmts] of idx.builderCalls) {
      if (stmts.some((s) => { const m = enclosingMethod(s); return m && memberName(m) === name; })) { stack.push(callee); }
    }
  }
  return seen;
}
function compsIn(idx, names) {
  return idx.comps.filter((c) => { const m = enclosingMethod(c.stmt); return m && names.has(memberName(m)); });
}

function checkPriceSheet(file, idx, consts) {
  // ① 找价格半屏：bindSheet(…, this.<builder>(), {…})，builder 树里有 search_price_confirm / search_price_min
  let sheet = null;
  for (const c of idx.comps) {
    for (const call of c.call('bindSheet')) {
      const b = call.args[1] ? unwrap(call.args[1]) : null;
      if (!b || !ts.isCallExpression(b) || !ts.isPropertyAccessExpression(b.expression)) { continue; }
      const tree = builderTree(idx, b.expression.name.text);
      const comps = compsIn(idx, tree);
      const hit = comps.some((x) => instances(idx, consts, x).some((i) => i.ids.has(ID_PRICE_CONFIRM) || i.ids.has(ID_PRICE_MIN)));
      if (hit) { sheet = { comp: c, call: call, tree: tree, comps: comps }; }
    }
  }
  if (sheet === null) {
    report('AH3-missing', idx.struct, '找不到价格半屏（bindSheet 的内容 builder 里没有 search_price_confirm / search_price_min）', file);
    return;
  }
  const opts = sheet.call.args[2] ? unwrap(sheet.call.args[2]) : null;
  const optFns = (names) => {
    const out = [];
    for (const n of names) { const v = opts ? propValue(opts, n) : null; if (v) { out.push(v); } }
    return out;
  };
  // ② 关闭后回【价格】：onDisappear / onWillDisappear 里 键盘 + 读屏焦点都回 search_filter_price
  if (!opts || !ts.isObjectLiteralExpression(opts)) {
    report('AH3-out', sheet.call.node.expression.name, '价格半屏 bindSheet 的选项不是对象字面量，判不了关闭回焦', file);
  } else {
    const moves = focusMoves(idx, consts, optFns(['onDisappear', 'onWillDisappear']));
    const j = judgeMoves(moves, ID_FILTER_PRICE);
    if (!j.a11y || !j.kbd) {
      report('AH3-out', sheet.call.node.expression.name, '价格半屏关闭后焦点没回到【价格】search_filter_price（要键盘 + 读屏两种，CouliFocusReturn.to；缺 ' +
        [!j.kbd ? '键盘' : '', !j.a11y ? '读屏' : ''].filter((x) => x).join('、') + '）' +
        (moves.length ? '；现有：' + moves.map(describeMove).join(', ') : ''), file);
    }
    if (j.wrong.length > 0) {
      report('AH3-out', sheet.call.node.expression.name, '价格半屏关闭时读屏焦点还会移到别处 / 判不了：' + j.wrong.join(', '), file);
    }
  }
  // ③ 打开时焦点进标题：TITLE_BAR 标题有 id search_price_title、可获焦，onAppear（标题 / 半屏树 / 选项 onAppear）读屏焦点移到它
  const titles = sheet.comps.filter((c) => c.name === 'Text' && c.call('accessibilityRole').some((r) => /TITLE_BAR/.test(compact(r.node))));
  if (titles.length === 0) {
    report('AH3-in', sheet.call.node, '价格半屏里找不到标题（accessibilityRole TITLE_BAR 的 Text）', file);
  } else {
    const t = titles[0];
    const ids = idValues(t, consts, null);
    if (ids.size === 0) {
      report('AH3-in-id', t.root, '价格半屏标题没有 id（应 search_price_title）', file);
    } else if (!exactly(ids, ID_PRICE_TITLE)) {
      report('AH3-in-id', t.root, '价格半屏标题 id 是 ' + [...ids].join(' / ') + '，应 search_price_title（设备 a11y_hs_03 按它查焦点）', file);
    }
    const fz = t.last('focusable');
    if (!fz || !fz.args[0] || fz.args[0].kind !== ts.SyntaxKind.TrueKeyword) {
      report('AH3-in-focusable', t.root, '价格半屏标题没有 .focusable(true)（Text 缺省不可获焦，键盘焦点进不去）', file);
    }
    const roots = callbackArgs(sheet.comps, 'onAppear').concat(optFns(['onAppear', 'onWillAppear']));
    const moves = focusMoves(idx, consts, roots);
    const j = judgeMoves(moves, ID_PRICE_TITLE);
    if (!j.a11y) {
      report('AH3-in', t.root, '价格半屏打开时读屏焦点没移到标题 search_price_title（标题 onAppear 调 CouliFocusReturn.to，照 CouliSheetPanel）' +
        (moves.length ? '；现有：' + moves.map(describeMove).join(', ') : ''), file);
    }
    if (j.wrong.length > 0) {
      report('AH3-in', t.root, '价格半屏打开时读屏焦点还会移到别处 / 判不了：' + j.wrong.join(', '), file);
    }
  }
  // ④ 校验失败播报：sheetError 每处非空赋值同路有 CouliAnnounce.say(…, 该错误)
  const sets = collect(idx.struct, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
    ts.isPropertyAccessExpression(n.left) && n.left.name.text === 'sheetError' && /^this\.model$|^model$/.test(compact(n.left.expression)));
  const nonEmpty = sets.filter((n) => { const r = unwrap(n.right); return !(isStr(r) && r.text.length === 0); });
  if (nonEmpty.length === 0) {
    report('AH3-none', idx.struct, '没有给 sheetError 赋错误文字的地方（校验失败提示被删了？）', file);
  }
  for (const a of nonEmpty) {
    const scope = unconditionalScope(a);
    const says = reachableCalls(idx, scope, (n) => isStaticCall(n, 'CouliAnnounce', 'say'));
    const rhs = compact(a.right);
    const carries = (arg) => {
      if (!arg) { return false; }
      const x = unwrap(arg);
      if (compact(x) === rhs || /^(this\.)?model\.sheetError$/.test(compact(x))) { return true; }
      if (ts.isIdentifier(x)) { const l = localConst(x, x.text); return !!(l && compact(l) === rhs); }
      return false;
    };
    if (says.length === 0) {
      report('AH3-say', a, 'sheetError 出错时没有 CouliAnnounce.say 播报（读屏听不到校验失败）', file);
    } else if (!says.some((s) => carries(s.arguments[1]))) {
      report('AH3-say', a, 'sheetError 出错时播报的不是这句错误（' + says.map((s) => compact(s)).join(' ; ') + '）', file);
    }
  }
  // ⑤ 两个价格框的 accessibilityDescription 在出错时带 sheetError（每个调用点分别求值）
  for (const want of [ID_PRICE_MIN, ID_PRICE_MAX]) {
    const hits = [];
    for (const c of idx.comps) {
      if (c.name !== 'TextInput') { continue; }
      for (const inst of instances(idx, consts, c)) { if (inst.ids.has(want)) { hits.push(inst); } }
    }
    if (hits.length === 0) {
      report('AH3-desc', idx.struct, '找不到价格框 ' + want, file);
      continue;
    }
    for (const inst of hits) {
      const d = inst.comp.last('accessibilityDescription');
      if (!d || !d.args[0]) {
        report('AH3-desc', inst.comp.root, want + ' 没有 accessibilityDescription（校验错误没关联到价格框）', file);
        continue;
      }
      const v = descValue(d.args[0], 'sheetError', idx, inst.env, 0);
      if (v === null) {
        report('AH3-desc', d.node, want + ' 的 accessibilityDescription 无法静态判定是否在出错时带 sheetError', file);
      } else if (typeof v !== 'string' || v.indexOf(MARK) < 0) {
        report('AH3-desc', d.node, want + ' 的 accessibilityDescription 在 sheetError 非空时不带这句错误', file);
      }
    }
  }
}

// ---------------------------------------------------------------- AH4 搜索框读屏标签

/** 文案键：this.t(K) / this.config.texts.text(K) / t(K)，K 经常量求值；判不了为 null。 */
function keysOf(e, consts) {
  e = unwrap(e);
  if (!e || !ts.isCallExpression(e) || e.arguments.length !== 1) { return null; }
  const callee = compact(e.expression);
  if (['this.t', 'this.config.texts.text', 't', 'this.text'].indexOf(callee) < 0) { return null; }
  return values(e.arguments[0], consts, null);
}

function draftTexts(sf) {
  const out = new Map();
  const cls = findTop(sf, ts.isClassDeclaration, 'SearchDraftTexts');
  if (!cls) { return null; }
  walk(cls, (n) => {
    if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === 'set' &&
      n.arguments.length === 2 && isStr(n.arguments[0]) && isStr(n.arguments[1])) {
      out.set(n.arguments[0].text, n.arguments[1].text);
    }
  });
  return out;
}

function checkSearchLabel(file, idx, consts, contract, drafts) {
  const effective = (k) => (Object.prototype.hasOwnProperty.call(contract, k) ? contract[k] : (drafts.has(k) ? drafts.get(k) : ''));
  const inputs = idx.comps.filter((c) => c.name === 'TextInput' && idValues(c, consts, null).has(ID_SEARCH_INPUT));
  if (inputs.length !== 1) {
    report('AH4-missing', idx.struct, 'search_input 的 TextInput 应恰一个（现 ' + inputs.length + '）', file);
    return;
  }
  const input = inputs[0];
  const phExpr = propValue(input.args[0], 'placeholder');
  const phKeys = phExpr ? keysOf(phExpr, consts) : null;
  if (!phKeys || phKeys.size !== 1 || !phKeys.has(KEY_PLACEHOLDER)) {
    report('AH4-placeholder', input.root, '搜索框占位不再是 search.placeholder（占位文字照旧显示，只改读屏名）', file);
  }
  const phText = effective(KEY_PLACEHOLDER);
  const at = input.last('accessibilityText');
  if (!at || !at.args[0]) {
    report('AH4-label', input.root, 'search_input 没有 accessibilityText（读屏会读占位或什么都不读）', file);
    return;
  }
  if (phExpr && compact(at.args[0]) === compact(phExpr)) {
    report('AH4-label', at.node, 'search_input 的读屏名与占位是同一个表达式（' + compact(at.args[0]) + '）', file);
    return;
  }
  const keys = keysOf(at.args[0], consts);
  if (keys === null) {
    report('AH4-label', at.node, 'search_input 的读屏名不是可静态判定的文案键（this.t(SearchKeys.X)）：' + compact(at.args[0]), file);
    return;
  }
  for (const k of keys) {
    if (k === KEY_PLACEHOLDER) {
      report('AH4-label', at.node, 'search_input 的读屏名仍是占位键 search.placeholder（「' + phText + '」）', file);
      continue;
    }
    const text = effective(k);
    if (typeof text !== 'string' || text.length === 0) {
      report('AH4-text', at.node, '标签键 ' + k + ' 在契约与 SearchDraftTexts 里都没有文字（同 lockph R3）', file);
    } else if (text === phText) {
      report('AH4-label', at.node, '标签键 ' + k + ' 的文字「' + text + '」与占位相同（读屏名仍是占位）', file);
    }
  }
}

// ---------------------------------------------------------------- 主流程

const home = parse(HOME);
const search = parse(SEARCH);
const draft = parse(DRAFT);
let contract = null;
if (input.files[CONTRACT] === undefined || input.files[CONTRACT] === null) {
  incomplete.push(CONTRACT + '：文件不存在，无法判定');
} else {
  try {
    contract = JSON.parse(input.files[CONTRACT]).texts;
    if (!contract || typeof contract !== 'object') { incomplete.push(CONTRACT + '：没有 texts'); contract = null; }
  } catch (e) {
    incomplete.push(CONTRACT + '：JSON 解析失败 ' + e.message);
  }
}
if (home && search && draft && contract) {
  const popup = findTop(home, ts.isStructDeclaration, 'HomePopupView');
  const notice = findTop(home, ts.isStructDeclaration, 'HomeNoticeCard');
  const view = findTop(search, ts.isStructDeclaration, 'SearchView');
  const drafts = draftTexts(draft);
  if (!popup) { incomplete.push(HOME + '：找不到 struct HomePopupView'); }
  if (!notice) { incomplete.push(HOME + '：找不到 struct HomeNoticeCard'); }
  if (!view) { incomplete.push(SEARCH + '：找不到 struct SearchView'); }
  if (!drafts) { incomplete.push(DRAFT + '：找不到 class SearchDraftTexts'); }
  if (popup && notice && view && drafts) {
    const hc = moduleConsts(home);
    const sc = moduleConsts(search);
    checkPopup(HOME, indexStruct(popup), hc);
    checkNotice(HOME, indexStruct(notice), hc);
    const si = indexStruct(view);
    checkPriceSheet(SEARCH, si, sc);
    checkSearchLabel(SEARCH, si, sc, contract, drafts);
  }
}
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete }));
