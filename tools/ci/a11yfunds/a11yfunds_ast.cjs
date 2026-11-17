#!/usr/bin/env node
// FU-HM-A11Y-FUNDS-harmony 宿主守卫的解析部分（由 check_a11y_funds.py 调用，不单独跑）。用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS，
// 判定全部走 AST（struct / 类 / 组件属性链 / 自定义组件对象实参 / if·三元·&& 守卫 / 赋值语句），不用正则切块，注释与字符串里的字不算。
// 写法照 tools/ci/a11ycommon/a11ycommon_ast.cjs 与 tools/ci/loginphone/loginphone_ast.cjs（本文件自带解析工具函数，不 require 它们）。
//   用法：node a11yfunds_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>"}}（REQUIRED 五个文件，见 check_a11y_funds.py）
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."], "calls": {"<文件>": ["<调用>", ...]}, "stats": {...}}
// 规则编号见 check_a11y_funds.py 文件头。AF6 的「资金调用集合」由本文件列出（calls），与基线的比对在 check_a11y_funds.py。
'use strict';
const fs = require('fs');
const path = require('path');

const DS_WALLET = 'common/designsystem/src/main/ets/components/Wallet.ets';
const STEP_UP = 'common/designsystem/src/main/ets/components/StepUpPanel.ets';
const WALLET = 'features/wallet/src/main/ets/WalletView.ets';
const WITHDRAW = 'features/wallet/src/main/ets/WithdrawView.ets';

const ID_AMOUNT = 'withdraw_amount';
const ID_TITLE = 'step_up_title';
const ID_CODE = 'step_up_code';
/** AF1：金额类判定的纯函数名与所在文件（逻辑层 Hypium 钉的是这个文件，任务书 §2.1 首选位置）。 */
const AMOUNT_FN = 'isAmountError';
const AMOUNT_FN_MODULE = './WithdrawA11y';
/** AF6：资金页里「资金动作」的接收者（控制器 / 二次验证执行器 / 面板驱动）。 */
const FUND_RECEIVERS = {
  [WITHDRAW]: ['this.config.controller', 'this.stepUpController'],
  [WALLET]: ['this.config.controller'],
  [STEP_UP]: ['this.driver'],
};
const HIDDEN = new Set(['no', 'no-hide-descendants']);

const tsDir = process.argv[2];
if (!tsDir) { console.error('a11yfunds_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('a11yfunds_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('a11yfunds_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
    process.exit(3);
  }
  return { ets: cfg.compilerOptions.ets, etsLoaderPath: path.dirname(cfgPath) };
}
const ETS_OPTIONS = etsOptions();

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const violations = [];
const incomplete = [];
const calls = {};
const stats = {};

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

// ---------------------------------------------------------------- 通用
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
function isFunctionLike(n) {
  return ts.isMethodDeclaration(n) || ts.isFunctionDeclaration(n) || ts.isArrowFunction(n) || ts.isFunctionExpression(n) ||
    ts.isConstructorDeclaration(n) || ts.isGetAccessorDeclaration(n);
}
function isMethodLike(n) {
  return ts.isMethodDeclaration(n) || ts.isFunctionDeclaration(n) || ts.isConstructorDeclaration(n) || ts.isGetAccessorDeclaration(n);
}
function contains(outer, inner) { return inner.pos >= outer.pos && inner.end <= outer.end; }
function enclosingMethod(node) {
  let n = node.parent;
  while (n && !isMethodLike(n)) { n = n.parent; }
  return n || null;
}
function topLevel(sf, pred) { const out = []; ts.forEachChild(sf, (n) => { if (pred(n)) { out.push(n); } }); return out; }
function findStruct(sf, name) { return topLevel(sf, (n) => ts.isStructDeclaration(n) && n.name && n.name.text === name)[0] || null; }
function findClass(sf, name) { return topLevel(sf, (n) => ts.isClassDeclaration(n) && n.name && n.name.text === name)[0] || null; }
function decorators(m) {
  const ds = (ts.getAllDecorators ? ts.getAllDecorators(m) : m.decorators) || [];
  return ds.map((d) => compact(d.expression));
}
function method(container, name) {
  return container.members.find((m) => ts.isMethodDeclaration(m) && memberName(m) === name) || null;
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
/** 属性链拆成 { root, calls: [{ name, args, node }] }，calls 按书写顺序。 */
function chainOf(expr) {
  const out = [];
  let e = unwrap(expr);
  while (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression)) {
    out.unshift({ name: e.expression.name.text, args: Array.from(e.arguments), node: e });
    e = unwrap(e.expression.expression);
  }
  return { root: e, calls: out };
}
function calleeText(call) { return compact(call.expression); }

// ---------------------------------------------------------------- 取值：模块 const、局部 const、三元、拼接、模板串
function staticTable(sf) {
  const out = new Map();
  if (!sf) { return out; }
  for (let round = 0; round < 4; round++) {
    let added = false;
    ts.forEachChild(sf, (n) => {
      if (!ts.isVariableStatement(n) || !(n.declarationList.flags & ts.NodeFlags.Const)) { return; }
      for (const d of n.declarationList.declarations) {
        if (!ts.isIdentifier(d.name) || !d.initializer || out.has(d.name.text)) { continue; }
        const v = values(d.initializer, out, 0);
        if (v && v.size === 1) { out.set(d.name.text, [...v][0]); added = true; }
      }
    });
    if (!added) { break; }
  }
  return out;
}
function localConst(node, name) {
  let n = node.parent;
  while (n) {
    if (isFunctionLike(n)) {
      let hit = null;
      walk(n, (x) => {
        if (hit === null && ts.isVariableDeclaration(x) && ts.isIdentifier(x.name) && x.name.text === name && x.initializer &&
          x.parent && (x.parent.flags & ts.NodeFlags.Const)) { hit = x.initializer; }
      });
      if (hit) { return hit; }
    }
    n = n.parent;
  }
  return null;
}
/** 表达式可能取到的字符串集合；判不了为 null。 */
function values(e, table, depth) {
  depth = depth || 0;
  if (depth > 10 || !e) { return null; }
  e = unwrap(e);
  if (isStr(e)) { return new Set([e.text]); }
  if (ts.isNumericLiteral(e)) { return new Set([String(Number(e.text))]); }
  if (ts.isConditionalExpression(e)) {
    const a = values(e.whenTrue, table, depth + 1);
    const b = values(e.whenFalse, table, depth + 1);
    return a && b ? new Set([...a, ...b]) : null;
  }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.PlusToken) {
    const a = values(e.left, table, depth + 1);
    const b = values(e.right, table, depth + 1);
    if (!a || !b || a.size * b.size > 64) { return null; }
    const out = new Set();
    for (const x of a) { for (const y of b) { out.add(String(x) + String(y)); } }
    return out;
  }
  if (ts.isTemplateExpression(e)) {
    let acc = new Set([e.head.text]);
    for (const span of e.templateSpans) {
      const v = values(span.expression, table, depth + 1);
      if (!v || acc.size * v.size > 64) { return null; }
      const next = new Set();
      for (const x of acc) { for (const y of v) { next.add(x + String(y) + span.literal.text); } }
      acc = next;
    }
    return acc;
  }
  if (ts.isIdentifier(e)) {
    const local = localConst(e, e.text);
    if (local) { return values(local, table, depth + 1); }
    if (table.has(e.text)) { return new Set([table.get(e.text)]); }
    return null;
  }
  return null;
}
/** 唯一取值的字符串；判不了 / 多值为 null。 */
function single(e, table) {
  const v = values(e, table, 0);
  return v && v.size === 1 ? [...v][0] : null;
}

// ---------------------------------------------------------------- 组件
/** 容器里的全部组件属性链：{ name, ets, args, calls, stmt }。 */
function components(container) {
  const out = [];
  walk(container, (n) => {
    if (!ts.isExpressionStatement(n)) { return; }
    const ch = chainOf(n.expression);
    // 内置组件解析成 EtsComponentExpression；不带属性链的自定义组件（如 @Builder 里单独一句 WalletHeroCard({...})）可能是普通调用。
    const isComp = ch.root && (ts.isEtsComponentExpression(ch.root) ||
      (ts.isCallExpression(ch.root) && ts.isIdentifier(ch.root.expression) && /^[A-Z]/.test(ch.root.expression.text)));
    if (!isComp) { return; }
    out.push({ name: compact(ch.root.expression), ets: ch.root, args: Array.from(ch.root.arguments || []), calls: ch.calls, stmt: n });
  });
  return out;
}
function attrCalls(comp, name) { return comp.calls.filter((c) => c.name === name); }
function idsOf(comp, table) {
  const ids = [];
  for (const c of attrCalls(comp, 'id')) {
    const v = c.args[0] ? values(c.args[0], table, 0) : null;
    if (v) { ids.push(...v); }
  }
  return ids;
}
/** comp 外层的组件（由近到远）。 */
function ancestors(comp, all) {
  return all.filter((o) => o !== comp && o.ets.body && contains(o.ets.body, comp.stmt))
    .sort((a, b) => (b.stmt.pos - a.stmt.pos));
}
/** accessibilityLevel 实参可能取到的值集合（字面量 / 三元两支）；没调用为空集。判不了为 null。 */
function levels(comp, table) {
  const out = new Set();
  for (const c of attrCalls(comp, 'accessibilityLevel')) {
    const v = c.args[0] ? values(c.args[0], table, 0) : null;
    if (!v) { return null; }
    for (const x of v) { out.add(x); }
  }
  return out;
}
/** 自己读屏隐藏（每个可能值都是 no / no-hide-descendants）或某层外层一定 no-hide-descendants。 */
function surelyHidden(comp, all, table) {
  const own = levels(comp, table);
  if (own && own.size > 0 && [...own].every((x) => HIDDEN.has(x))) { return true; }
  for (const a of ancestors(comp, all)) {
    const lv = levels(a, table);
    if (lv && lv.size > 0 && [...lv].every((x) => x === 'no-hide-descendants')) { return true; }
  }
  return false;
}
/** 可能被读屏隐藏（自己某个取值隐藏，或外层某个取值是 no-hide-descendants，或判不了）。 */
function maybeHidden(comp, all, table) {
  const own = levels(comp, table);
  if (own === null || [...own].some((x) => HIDDEN.has(x))) { return true; }
  for (const a of ancestors(comp, all)) {
    const lv = levels(a, table);
    if (lv === null || [...lv].some((x) => x === 'no-hide-descendants')) { return true; }
  }
  return false;
}
function isTrueLiteral(e) { e = unwrap(e); return e && e.kind === ts.SyntaxKind.TrueKeyword; }
function isFalseLiteral(e) { e = unwrap(e); return e && e.kind === ts.SyntaxKind.FalseKeyword; }
/** 加号链最左操作数。 */
function leftmost(e) {
  e = unwrap(e);
  while (e && ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.PlusToken) { e = unwrap(e.left); }
  return e;
}

// ---------------------------------------------------------------- 守卫（if / 三元 / && / 提前 return）
/** 在 pol 极性下断言为真的原子表达式。 */
function atoms(expr, pol, out) {
  out = out || [];
  const e = unwrap(expr);
  if (!e) { return out; }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) { return atoms(e.operand, !pol, out); }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) {
    if (pol) { atoms(e.left, true, out); atoms(e.right, true, out); }
    return out;
  }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.BarBarToken) {
    if (!pol) { atoms(e.left, false, out); atoms(e.right, false, out); }
    return out;
  }
  if (pol) {
    out.push(e);
    if (ts.isIdentifier(e)) {
      const init = localConst(e, e.text);
      if (init) { atoms(init, true, out); }
    }
  }
  return out;
}
function onlyExits(stmt) {
  if (!stmt) { return false; }
  if (ts.isReturnStatement(stmt) || ts.isThrowStatement(stmt)) { return true; }
  if (ts.isBlock(stmt)) { return stmt.statements.length > 0 && stmt.statements.every((s) => ts.isReturnStatement(s) || ts.isThrowStatement(s)); }
  return false;
}
/** node 到 stop（不含）之间所有守卫断言为真的原子（穿过回调箭头函数，到方法边界为止）。 */
function guardsOf(node, stop) {
  const out = [];
  let cur = node;
  let p = node.parent;
  while (p && p !== stop) {
    if (ts.isIfStatement(p)) {
      if (cur === p.thenStatement) { atoms(p.expression, true, out); }
      else if (cur === p.elseStatement) { atoms(p.expression, false, out); }
    } else if (ts.isConditionalExpression(p)) {
      if (cur === p.whenTrue) { atoms(p.condition, true, out); }
      else if (cur === p.whenFalse) { atoms(p.condition, false, out); }
    } else if (ts.isBinaryExpression(p) && p.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken && cur === p.right) {
      atoms(p.left, true, out);
    } else if (ts.isBlock(p) || ts.isSourceFile(p)) {
      for (const s of p.statements) {
        if (s === cur) { break; }
        if (ts.isIfStatement(s) && !s.elseStatement && onlyExits(s.thenStatement)) { atoms(s.expression, false, out); }
      }
    }
    if (isMethodLike(p)) { break; }
    cur = p;
    p = p.parent;
  }
  return out;
}
/** v2：带极性的原子（{ e, pol }：pol 为 true 表示断言 e 为真，false 表示断言 e 为假）。 */
function litAtoms(expr, pol, out, alias) {
  out = out || [];
  const e = unwrap(expr);
  if (!e) { return out; }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) { return litAtoms(e.operand, !pol, out, alias); }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) {
    if (pol) { litAtoms(e.left, true, out, alias); litAtoms(e.right, true, out, alias); }
    return out;
  }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.BarBarToken) {
    if (!pol) { litAtoms(e.left, false, out, alias); litAtoms(e.right, false, out, alias); }
    return out;
  }
  // alias：经局部 const 展开得到的原子记下那个 const 的声明（AF7 据此排除「排队时就算好的旧值」）。
  out.push({ e: e, pol: pol, alias: alias || null });
  if (ts.isIdentifier(e)) {
    const decl = constDecl(e);
    if (decl) { litAtoms(decl.initializer, pol, out, alias || decl); }
  }
  return out;
}
/** v2：guardsOf 的带极性版本（node 到 stop（不含）之间；到方法边界为止）。 */
function guardsPol(node, stop) {
  const out = [];
  let cur = node;
  let p = node.parent;
  while (p && p !== stop) {
    if (ts.isIfStatement(p)) {
      if (cur === p.thenStatement) { litAtoms(p.expression, true, out); }
      else if (cur === p.elseStatement) { litAtoms(p.expression, false, out); }
    } else if (ts.isConditionalExpression(p)) {
      if (cur === p.whenTrue) { litAtoms(p.condition, true, out); }
      else if (cur === p.whenFalse) { litAtoms(p.condition, false, out); }
    } else if (ts.isBinaryExpression(p) && p.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken && cur === p.right) {
      litAtoms(p.left, true, out);
    } else if (ts.isBlock(p) || ts.isSourceFile(p)) {
      for (const s of p.statements) {
        if (s === cur) { break; }
        if (ts.isIfStatement(s) && !s.elseStatement && onlyExits(s.thenStatement)) { litAtoms(s.expression, false, out); }
      }
    }
    if (isMethodLike(p)) { break; }
    cur = p;
    p = p.parent;
  }
  return out;
}
const EQ = new Set([ts.SyntaxKind.EqualsEqualsEqualsToken, ts.SyntaxKind.EqualsEqualsToken]);
const NE = new Set([ts.SyntaxKind.ExclamationEqualsEqualsToken, ts.SyntaxKind.ExclamationEqualsToken]);
/** 原子是否断言「a 与 b 相等」：返回 [左, 右] 或 null。 */
function assertsEqual(atom) {
  const e = atom.e;
  if (!ts.isBinaryExpression(e)) { return null; }
  const k = e.operatorToken.kind;
  if ((atom.pol && EQ.has(k)) || (!atom.pol && NE.has(k))) { return [unwrap(e.left), unwrap(e.right)]; }
  return null;
}
/** 原子是否断言字段（is(节点) 为真的表达式）为非空串。 */
function assertsNonEmpty(atom, is) {
  const e = atom.e;
  if (atom.pol && is(e)) { return true; }
  if (atom.pol && ts.isPropertyAccessExpression(e) && e.name.text === 'length' && is(unwrap(e.expression))) { return true; }
  if (!ts.isBinaryExpression(e)) { return false; }
  const k = e.operatorToken.kind;
  const l = unwrap(e.left);
  const r = unwrap(e.right);
  const isLen = (x) => ts.isPropertyAccessExpression(x) && x.name.text === 'length' && is(unwrap(x.expression));
  const zero = (x) => ts.isNumericLiteral(x) && Number(x.text) === 0;
  const empty = (x) => isStr(x) && x.text === '';
  if (atom.pol && k === ts.SyntaxKind.GreaterThanToken && isLen(l) && zero(r)) { return true; }
  if (atom.pol && NE.has(k) && ((is(l) && empty(r)) || (isLen(l) && zero(r)))) { return true; }
  if (!atom.pol && EQ.has(k) && ((is(l) && empty(r)) || (isLen(l) && zero(r)))) { return true; }
  return false;
}
/** 生命周期钩子方法体里的顶层语句（不含嵌套 if / try 里的）。 */
function hookStatements(container, name) {
  const m = method(container, name);
  return m && m.body ? Array.from(m.body.statements) : [];
}
/** 顶层语句里对 this.<F> 的赋值：{ field, rhs, op }。 */
function hookWrites(container, name) {
  const out = [];
  for (const s of hookStatements(container, name)) {
    if (!ts.isExpressionStatement(s)) { continue; }
    const e = unwrap(s.expression);
    if (ts.isBinaryExpression(e) && e.operatorToken.kind >= ts.SyntaxKind.FirstAssignment && e.operatorToken.kind <= ts.SyntaxKind.LastAssignment) {
      const t = unwrap(e.left);
      if (ts.isPropertyAccessExpression(t) && t.expression.kind === ts.SyntaxKind.ThisKeyword) {
        out.push({ field: t.name.text, rhs: unwrap(e.right), op: e.operatorToken.kind });
      }
    } else if ((ts.isPrefixUnaryExpression(e) || ts.isPostfixUnaryExpression(e)) &&
      (e.operator === ts.SyntaxKind.PlusPlusToken || e.operator === ts.SyntaxKind.MinusMinusToken)) {
      const t = unwrap(e.operand);
      if (ts.isPropertyAccessExpression(t) && t.expression.kind === ts.SyntaxKind.ThisKeyword) {
        out.push({ field: t.name.text, rhs: null, op: e.operator });
      }
    }
  }
  return out;
}
/** 顶层语句里 clearTimeout / clearInterval(this.<T>) 的 T。 */
function hookClears(container, name) {
  const out = new Set();
  for (const s of hookStatements(container, name)) {
    const e = ts.isExpressionStatement(s) ? unwrap(s.expression) : null;
    if (e && ts.isCallExpression(e) && /^clear(Timeout|Interval)$/.test(calleeText(e)) && e.arguments.length === 1) {
      const a = unwrap(e.arguments[0]);
      if (ts.isPropertyAccessExpression(a) && a.expression.kind === ts.SyntaxKind.ThisKeyword) { out.add(a.name.text); }
    }
  }
  return out;
}
function memberInit(container, field) {
  const p = container.members.find((m) => ts.isPropertyDeclaration(m) && memberName(m) === field);
  return p ? (p.initializer ? unwrap(p.initializer) : null) : undefined;
}
function boolLit(e) { return e ? (e.kind === ts.SyntaxKind.TrueKeyword ? true : (e.kind === ts.SyntaxKind.FalseKeyword ? false : null)) : null; }
/**
 * 原子是否「页面 / 面板生命周期」复核：
 *   ① this.F 断言为 P（布尔），aboutToDisappear 顶层把 F 写成 !P，且 F 的初值是 P 或 aboutToAppear 顶层写成 P；
 *   ② 等式一侧是 this.F，F 在 aboutToDisappear 顶层被改写（代数 / 世代号）；
 *   ③ extra 里列出的既有生命周期读法（如 this.config.controller.alive，页面离开后为 false）断言为真。
 */
function isLifecycleAtom(atom, container, extra) {
  const e = atom.e;
  if (atom.pol && (extra || []).indexOf(compact(e)) >= 0) { return true; }
  const gone = hookWrites(container, 'aboutToDisappear');
  if (ts.isPropertyAccessExpression(e) && e.expression.kind === ts.SyntaxKind.ThisKeyword) {
    const f = e.name.text;
    const off = gone.some((w) => w.field === f && w.op === ts.SyntaxKind.EqualsToken && boolLit(w.rhs) === !atom.pol);
    const init = memberInit(container, f);
    const on = (init !== undefined && boolLit(init) === atom.pol) ||
      hookWrites(container, 'aboutToAppear').some((w) => w.field === f && w.op === ts.SyntaxKind.EqualsToken && boolLit(w.rhs) === atom.pol);
    return off && on;
  }
  const eq = assertsEqual(atom);
  if (eq) {
    for (const side of eq) {
      if (ts.isPropertyAccessExpression(side) && side.expression.kind === ts.SyntaxKind.ThisKeyword &&
        gone.some((w) => w.field === side.name.text)) { return true; }
    }
  }
  return false;
}
/** 标识符对应的 const 声明（向外层函数找）。 */
function constDecl(ident) {
  let n = ident.parent;
  while (n) {
    if (isFunctionLike(n)) {
      let hit = null;
      walk(n, (x) => {
        if (hit === null && ts.isVariableDeclaration(x) && ts.isIdentifier(x.name) && x.name.text === ident.text && x.initializer &&
          x.parent && (x.parent.flags & ts.NodeFlags.Const)) { hit = x; }
      });
      if (hit) { return hit; }
    }
    n = n.parent;
  }
  return null;
}
/** 延时执行的回调：setTimeout / setInterval / queueMicrotask / requestAnimationFrame / Promise.then·catch·finally / UIContext.postFrameCallback。 */
const DEFER_RE = /^(setTimeout|setInterval|queueMicrotask|requestAnimationFrame)$|\.(then|catch|finally|postFrameCallback|postDelayedFrameCallback)$/;
function deferredCallbackOf(node) {
  let n = node.parent;
  while (n && !isMethodLike(n)) {
    if ((ts.isArrowFunction(n) || ts.isFunctionExpression(n)) && n.parent && ts.isCallExpression(n.parent) &&
      DEFER_RE.test(calleeText(n.parent)) && n.parent.arguments.indexOf(n) >= 0) { return n; }
    n = n.parent;
  }
  return null;
}

function amountGuard(list) {
  return list.some((a) => ts.isCallExpression(a) && /(^|\.)isAmountError$/.test(calleeText(a)) && a.arguments.length > 0 &&
    compact(a.arguments[0]).indexOf('textKey') >= 0);
}
function editableGuard(list) {
  return list.some((a) => /(^|\.)editable$/.test(compact(a)));
}

// ---------------------------------------------------------------- 字段写入
/** 赋值目标 X.F 的接收者是否视图模型（this.model、this、或初值为 this.model 的局部 const）。 */
function isModelReceiver(e) {
  e = unwrap(e);
  const t = compact(e);
  if (t === 'this.model' || e.kind === ts.SyntaxKind.ThisKeyword) { return true; }
  if (ts.isIdentifier(e)) {
    const init = localConst(e, e.text);
    return !!init && compact(init) === 'this.model';
  }
  return false;
}
/** 容器里对字段 field 的写入：{ node, rhs（++ / -- / 复合赋值为 null）}。 */
function writesTo(container, field) {
  const out = [];
  walk(container, (n) => {
    let target = null;
    let rhs;
    if (ts.isBinaryExpression(n) && n.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
      n.operatorToken.kind <= ts.SyntaxKind.LastAssignment) {
      target = n.left;
      rhs = n.operatorToken.kind === ts.SyntaxKind.EqualsToken ? n.right : null;
    } else if ((ts.isPrefixUnaryExpression(n) || ts.isPostfixUnaryExpression(n)) &&
      (n.operator === ts.SyntaxKind.PlusPlusToken || n.operator === ts.SyntaxKind.MinusMinusToken)) {
      target = n.operand;
      rhs = null;
    }
    target = unwrap(target);
    if (target && ts.isPropertyAccessExpression(target) && target.name.text === field && isModelReceiver(target.expression)) {
      out.push({ node: n, rhs: rhs });
    }
  });
  return out;
}
/** 键生成式（及其一层 this.<方法>()）读到的视图模型字段名与出现的全部标识符。 */
function keyReads(fn, container) {
  const fields = new Set();
  const idents = new Set();
  const visit = (root, depth) => {
    walk(root, (n) => {
      if (ts.isIdentifier(n)) { idents.add(n.text); }
      if (ts.isPropertyAccessExpression(n) && isModelReceiver(n.expression)) { fields.add(n.name.text); }
      if (depth === 0 && ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
        n.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
        const m = method(container, n.expression.name.text);
        if (m && m.body) { visit(m.body, 1); }
      }
    });
  };
  visit(fn, 0);
  return { fields: fields, idents: idents };
}
function forEachBuilding(container, builderCall) {
  return collect(container, (n) => (ts.isCallExpression(n) || ts.isEtsComponentExpression(n)) && ts.isIdentifier(n.expression) &&
    n.expression.text === 'ForEach' && n.arguments && n.arguments.length >= 3 && compact(n.arguments[1]).indexOf(builderCall) >= 0);
}

// ---------------------------------------------------------------- AF7（v2，Codex r1 S2-3）：延时移焦不发过期请求
/** 页面 / 面板生命周期的既有读法（断言为真即视为「仍在」）。 */
const LIFECYCLE_EXTRA = { [WITHDRAW]: ['this.config.controller.alive'], [STEP_UP]: [] };
/**
 * 对 container 里移到 targetId 的读屏 / 键盘移焦调用：凡在延时回调里执行的（直接写在回调里，或回调里调的一层 this.<方法>()，或
 * setTimeout(this.<方法>)），执行时必须复核（回调 / 方法里的守卫，不算排队时的条件）：
 *   life   页面 / 面板仍在（isLifecycleAtom）；或任务句柄存在 this.T 且 aboutToDisappear 顶层 clearTimeout(this.T)（取消过期任务）；
 *   seq    （req.seq）等式「this.F === 排队时捕获的 const」，const 的初值是 this.F 或某处 this.F = X 的 X，且 X 是 …banner.seq（错误序号没变）；
 *          或任务句柄存 this.T、排队前同一方法里 clearTimeout(this.T)（新错误取消旧任务）；
 *   state  （req.state）断言视图模型的 state 字段非空（仍是那条金额类错误；改金额 / 换成非金额类错误后为空）；
 *   edit   （req.editable）断言 …editable（执行时仍可编辑）。
 */
function staleFocus(rule, container, targetId, table, req) {
  const isTarget = (n) => ts.isCallExpression(n) && /^CouliFocusReturn\.(accessibilityFocus|to)$/.test(calleeText(n)) &&
    n.arguments.length >= 2 && (() => { const v = values(n.arguments[1], table, 0); return v !== null && v.has(targetId); })();
  const focusCalls = collect(container, isTarget);
  const deferrers = collect(container, (n) => ts.isCallExpression(n) && DEFER_RE.test(calleeText(n)));
  const handleOf = (sched) => {
    const p = sched.parent;
    if (p && ts.isBinaryExpression(p) && p.operatorToken.kind === ts.SyntaxKind.EqualsToken && p.right === sched) {
      const t = unwrap(p.left);
      if (ts.isPropertyAccessExpression(t) && t.expression.kind === ts.SyntaxKind.ThisKeyword) { return t.name.text; }
    }
    return null;
  };
  let deferred = 0;
  let ok = 0;
  for (const f of focusCalls) {
    const paths = [];
    const cb = deferredCallbackOf(f);
    if (cb) { paths.push({ guards: guardsPol(f, cb), sched: cb.parent, via: '', exec: cb }); }
    const owner = enclosingMethod(f);
    if (!cb && owner && container.members.indexOf(owner) >= 0) {
      const name = memberName(owner);
      const inner = guardsPol(f, owner);
      for (const d of deferrers) {
        for (const a of d.arguments) {
          const ua = unwrap(a);
          if (ts.isPropertyAccessExpression(ua) && ua.expression.kind === ts.SyntaxKind.ThisKeyword && ua.name.text === name) {
            paths.push({ guards: inner, sched: d, via: 'this.' + name, exec: owner });
          } else if (ts.isArrowFunction(ua) || ts.isFunctionExpression(ua)) {
            for (const c of collect(ua, (x) => ts.isCallExpression(x) && ts.isPropertyAccessExpression(x.expression) &&
              x.expression.expression.kind === ts.SyntaxKind.ThisKeyword && x.expression.name.text === name)) {
              paths.push({ guards: inner.concat(guardsPol(c, ua)), sched: d, via: 'this.' + name + '()', exec: owner, exec2: ua });
            }
          }
        }
      }
    }
    for (const p of paths) {
      deferred++;
      // 执行时复核只算执行时才求值的条件：经局部 const 展开、而 const 在执行体（回调 / 方法）外算好的原子不算（那是排队时的旧值）。
      const inExec = (node) => contains(p.exec, node) || (p.exec2 ? contains(p.exec2, node) : false);
      p.guards = p.guards.filter((a) => a.alias === null || inExec(a.alias));
      const handle = handleOf(p.sched);
      const cancelledOnLeave = handle !== null && hookClears(container, 'aboutToDisappear').has(handle);
      const missing = [];
      if (!cancelledOnLeave && !p.guards.some((a) => isLifecycleAtom(a, container, LIFECYCLE_EXTRA[container.getSourceFile().fileName]))) {
        missing.push('页面 / 面板仍在（生命周期标志，aboutToDisappear 置否；或任务句柄在 aboutToDisappear 里 clearTimeout）');
      }
      if (req.seq) {
        const schedMethod = enclosingMethod(p.sched);
        const cancelledOnNew = handle !== null && schedMethod !== null && collect(schedMethod, (x) => ts.isCallExpression(x) &&
          /^clear(Timeout|Interval)$/.test(calleeText(x)) && x.arguments.length === 1 && compact(x.arguments[0]) === 'this.' + handle &&
          x.end <= p.sched.pos).length > 0;
        const seqOk = p.guards.some((a) => {
          const eq = assertsEqual(a);
          if (!eq) { return false; }
          for (const [mine, other] of [[eq[0], eq[1]], [eq[1], eq[0]]]) {
            if (!(ts.isPropertyAccessExpression(mine) && mine.expression.kind === ts.SyntaxKind.ThisKeyword && ts.isIdentifier(other))) { continue; }
            const decl = constDecl(other);
            if (!decl || inExec(decl)) { continue; }
            const fld = mine.name.text;
            const sources = writesTo(container, fld).filter((w) => w.rhs).map((w) => compact(w.rhs));
            const init = compact(decl.initializer);
            if ((init === 'this.' + fld || sources.indexOf(init) >= 0) && sources.some((x) => /(^|\.)banner\.seq$/.test(x))) { return true; }
          }
          return false;
        });
        if (!seqOk && !cancelledOnNew) { missing.push('错误序号没变（this.<序号字段> === 排队时捕获的 banner.seq；或新错误排队前 clearTimeout 旧任务）'); }
      }
      if (req.state) {
        const isState = (x) => ts.isPropertyAccessExpression(x) && x.name.text === req.state && isModelReceiver(x.expression);
        const st = p.guards.some((a) => assertsNonEmpty(a, isState) ||
          ((x) => x !== null && x.some((s) => isState(s)))(assertsEqual(a)));
        if (!st) { missing.push('仍是金额类错误（' + req.state + ' 非空；改了金额、换成非金额类错误后不移）'); }
      }
      if (req.editable && !p.guards.some((a) => a.pol && ts.isPropertyAccessExpression(a.e) && a.e.name.text === 'editable' &&
        isModelReceiver(a.e.expression))) {
        missing.push('金额框仍可编辑（editable，执行时再查）');
      }
      if (missing.length) {
        report(rule, f, '延时移焦到 ' + targetId + (p.via ? '（经 ' + p.via + '）' : '') + ' 执行时没有复核：' + missing.join('；') +
          '——过期任务会无条件发送旧移焦请求（离页 / 关面板 / 改金额 / 再次提交后仍抢读屏焦点）');
      } else { ok++; }
    }
  }
  return { deferred: deferred, ok: ok };
}

// ---------------------------------------------------------------- AF1 / AF2：提现页金额框
function checkWithdraw() {
  const sf = parse(WITHDRAW);
  if (!sf) { return; }
  const view = findStruct(sf, 'WithdrawView');
  const model = findClass(sf, 'WithdrawModel');
  if (!view) { incomplete.push(WITHDRAW + '：找不到 struct WithdrawView'); return; }
  if (!model) { incomplete.push(WITHDRAW + '：找不到 class WithdrawModel'); return; }
  const table = staticTable(sf);
  const all = components(view);
  const inputs = all.filter((c) => c.name === 'TextInput' && idsOf(c, table).indexOf(ID_AMOUNT) >= 0);
  if (inputs.length !== 1) {
    report('AF1-desc', view, '金额框 TextInput（id ' + ID_AMOUNT + '）应恰一个，找到 ' + inputs.length + ' 个');
    return;
  }
  const input = inputs[0];
  const modelFields = new Map(model.members.filter((m) => ts.isPropertyDeclaration(m)).map((m) => [memberName(m), decorators(m)]));

  // AF1-fn：金额类判定来自 ./WithdrawA11y 的 isAmountError（逻辑层 Hypium 钉的就是它）。
  const imported = topLevel(sf, (n) => ts.isImportDeclaration(n) && isStr(n.moduleSpecifier) && n.moduleSpecifier.text === AMOUNT_FN_MODULE &&
    n.importClause && n.importClause.namedBindings && ts.isNamedImports(n.importClause.namedBindings) &&
    n.importClause.namedBindings.elements.some((el) => el.name.text === AMOUNT_FN && (!el.propertyName || el.propertyName.text === AMOUNT_FN)));
  if (imported.length === 0) {
    report('AF1-fn', sf.statements[0], '没有从 ' + AMOUNT_FN_MODULE + ' 引入 ' + AMOUNT_FN + '（金额类错误码判定应是 features/wallet 的纯函数，D10-1248 ④）');
  }

  // AF1-desc：金额框 accessibilityDescription(this.model.F)，F 只在金额类错误时写 banner 文字、有清空。
  const desc = attrCalls(input, 'accessibilityDescription');
  let field = null;
  if (desc.length !== 1 || desc[0].args.length !== 1) {
    report('AF1-desc', input.stmt, ID_AMOUNT + ' 没有（恰一个）accessibilityDescription（金额类错误没关联到金额框）');
  } else {
    const a = unwrap(desc[0].args[0]);
    if (ts.isPropertyAccessExpression(a) && isModelReceiver(a.expression) && modelFields.has(a.name.text) &&
      modelFields.get(a.name.text).indexOf('Trace') >= 0) {
      field = a.name.text;
    } else {
      report('AF1-desc', desc[0].node, ID_AMOUNT + ' 的 accessibilityDescription 实参「' + compact(a) + '」不是视图模型的 @Trace 字段（判不了是否金额类错误文字）');
    }
  }
  if (field !== null) {
    const ws = writesTo(view, field);
    // 右值按三元拆成若干叶子，每片叶子带「所在分支的条件」：'' = 清空；…banner.text = 写入（须断言 isAmountError）；其余一律红。
    const leaves = (e, extra, out) => {
      e = unwrap(e);
      if (e && ts.isConditionalExpression(e)) {
        leaves(e.whenTrue, extra.concat(atoms(e.condition, true)), out);
        leaves(e.whenFalse, extra.concat(atoms(e.condition, false)), out);
      } else { out.push({ e: e, g: extra }); }
      return out;
    };
    let setCount = 0;
    let clearCount = 0;
    for (const w of ws) {
      const ls = w.rhs ? leaves(w.rhs, [], []) : [{ e: null, g: [] }];
      for (const l of ls) {
        if (l.e && isStr(l.e) && l.e.text === '') { clearCount++; continue; }
        const ok = l.e && /(^|\.)banner\.text$/.test(compact(l.e)) && amountGuard(guardsOf(w.node, null).concat(l.g));
        if (ok) { setCount++; continue; }
        report('AF1-desc', w.node, '说明字段 ' + field + ' 的写入「' + compact(w.node) + '」不是「只在 isAmountError(textKey) 为真时取 banner 文字」' +
          '（非金额类错误也会关联到金额框，或接错了字段）');
      }
    }
    if (setCount === 0) {
      report('AF1-desc', desc[0].node, '说明字段 ' + field + ' 从没写入金额类错误文字（金额类错误没关联到金额框）');
    }
    if (clearCount === 0) {
      report('AF1-desc', desc[0].node, '说明字段 ' + field + ' 从不清空（banner 清空 / 改了金额后说明仍在）');
    }
  }

  // AF1-focus：与 CouliAnnounce.say(…banner.text) 同一块里（或其中一层 this.<方法>()），isAmountError(textKey) 且可编辑时只移读屏焦点到金额框。
  const says = collect(view, (n) => ts.isCallExpression(n) && calleeText(n) === 'CouliAnnounce.say' && n.arguments.length >= 2 &&
    /(^|\.)banner\.text$/.test(compact(n.arguments[1])));
  if (says.length === 0) {
    report('AF1-focus', view, '找不到新 banner 的播报 CouliAnnounce.say(…banner.text)（判不了同路）');
  }
  const isFocusCall = (n) => ts.isCallExpression(n) && /^CouliFocusReturn\.(accessibilityFocus|to)$/.test(calleeText(n));
  let good = 0;
  const seen = new Set();
  for (const say of says) {
    let block = say.parent;
    while (block && !ts.isBlock(block)) { block = block.parent; }
    if (!block) { continue; }
    const reach = [];
    for (const f of collect(block, isFocusCall)) { reach.push({ f: f, via: null }); }
    for (const c of collect(block, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
      n.expression.expression.kind === ts.SyntaxKind.ThisKeyword)) {
      const m = method(view, c.expression.name.text);
      if (m && m.body) { for (const f of collect(m.body, isFocusCall)) { reach.push({ f: f, via: c }); } }
    }
    for (const r of reach) {
      if (seen.has(r.f)) { continue; }
      seen.add(r.f);
      const idv = r.f.arguments.length >= 2 ? values(r.f.arguments[1], table, 0) : null;
      if (idv === null) {
        report('AF1-focus', r.f, '播报同路上的焦点 id「' + (r.f.arguments[1] ? compact(r.f.arguments[1]) : '') + '」无法静态判定');
        continue;
      }
      if (!idv.has(ID_AMOUNT)) { continue; }
      if (idv.size > 1) {
        report('AF1-focus', r.f, '焦点 id 可能不是 ' + ID_AMOUNT + '：' + [...idv].join(' / '));
        continue;
      }
      const g = guardsOf(r.f, null).concat(r.via ? guardsOf(r.via, null) : []);
      const problems = [];
      if (calleeText(r.f) !== 'CouliFocusReturn.accessibilityFocus') { problems.push('用了 CouliFocusReturn.to（会把键盘焦点也移过去、弹出键盘；只能移读屏焦点）'); }
      if (!amountGuard(g)) { problems.push('没有以 isAmountError(…textKey) 为条件（非金额类错误也会移焦）'); }
      if (!editableGuard(g)) { problems.push('没有以金额框可编辑（editable）为条件'); }
      if (problems.length) { report('AF1-focus', r.f, '移到 ' + ID_AMOUNT + ' 的焦点调用：' + problems.join('；')); }
      else { good++; }
    }
  }
  if (says.length > 0 && good === 0 && !violations.some((v) => v.rule === 'AF1-focus')) {
    report('AF1-focus', says[0], '新 banner 播报的同一路径上，金额类错误时没有把读屏焦点移到 ' + ID_AMOUNT +
      '（CouliFocusReturn.accessibilityFocus(ui, \'' + ID_AMOUNT + '\')，以 isAmountError(textKey) 与 editable 为条件）');
  }
  stats.amountFocusCalls = good;
  // AF7-amount（v2）：上面的移焦若延时执行，执行时须复核页面仍在、错误序号没变、仍是金额类错误、仍可编辑。
  const sa = staleFocus('AF7-amount', view, ID_AMOUNT, table, { seq: true, state: field, editable: true });
  stats.amountFocusDeferred = sa.deferred;
  stats.amountFocusRechecked = sa.ok;

  // AF2：金额卡 ForEach 键不读 inputReset，被拒分支不改键字段，并把显示值写回已接受值。
  const each = forEachBuilding(view, 'this.amountCard(');
  if (each.length !== 1) {
    report('AF2-key', view, '构建金额卡的 ForEach 应恰一个，找到 ' + each.length + ' 个');
    return;
  }
  const key = keyReads(each[0].arguments[2], view);
  if (key.idents.has('inputReset') || key.fields.has('inputReset')) {
    report('AF2-key', each[0].arguments[2], '金额卡 ForEach 键仍读 inputReset（被拒输入会让整卡连同输入框重建）');
  }
  const change = attrCalls(input, 'onChange')[0];
  const fn = change && change.args[0] ? unwrap(change.args[0]) : null;
  if (!fn || !(ts.isArrowFunction(fn) || ts.isFunctionExpression(fn))) {
    report('AF2-restore', input.stmt, ID_AMOUNT + ' 没有 onChange 回调（判不了被拒分支）');
    return;
  }
  const setInputs = collect(fn, (n) => ts.isCallExpression(n) && /\.setInput$/.test(calleeText(n)));
  let reject = null;
  for (const s of collect(fn, (n) => ts.isIfStatement(n))) {
    const pos = atoms(s.expression, true);
    const neg = atoms(s.expression, false);
    const hit = (list) => list.some((a) => setInputs.some((c) => contains(a, c)));
    if (hit(neg) && !hit(pos)) { reject = s.thenStatement; break; }
    if (hit(pos) && !hit(neg)) { reject = s.elseStatement || null; break; }
  }
  if (!reject) {
    report('AF2-restore', change.node, ID_AMOUNT + ' 的 onChange 找不到 setInput 返回 false 的分支（被拒时要把显示值写回已接受值）');
    return;
  }
  for (const f of key.fields) {
    for (const w of writesTo(reject, f)) {
      report('AF2-key', w.node, '被拒分支改了参与金额卡 ForEach 键的字段 ' + f + '（整卡会重建，焦点与键盘丢失）');
    }
  }
  const textArg = input.args[0] ? propValue(unwrap(input.args[0]), 'text') : null;
  const shown = textArg ? compact(textArg).replace(/^\$\$/, '') : '';
  const m = /^(?:this\.model|this)\.([A-Za-z_]\w*)$/.exec(shown);
  if (!m) {
    report('AF2-restore', input.stmt, ID_AMOUNT + ' 的 text 实参「' + shown + '」不是视图模型字段（判不了被拒后显示值是否写回）');
    return;
  }
  // v2（Codex r1 S2-2）：只看「右侧含 inputText」会放过删掉被拒串写入、写进 if (false) 等完全失效的回填。现要求回填一定执行、一定让显示状态变一次：
  //   · 写回：被拒分支里对 text 绑定字段的写入，右值就是 …inputText（属性读取），从被拒分支到它是直线路径（除页面生命周期复核外没有 if / 三元 /
  //     && / 循环 / switch / try，前面没有 return / throw，不在从不调用的函数里；可以在一个 setTimeout 回调里）；
  //   · 非 $$ 绑定（TextInput 的 text 不是双向的，同值写入不刷新）：写回必须在 setTimeout 回调里（下一轮），且在它之前同步、直线地把同一字段写成
  //     onChange 的入参（被拒串）——两次写入在同一轮会合并成「没变」；$$ 绑定时框架已把字段写成被拒串，同步或延时写回都可以。
  const twoWay = /^\$\$/.test(compact(textArg));
  const param = fn.parameters.length > 0 && ts.isIdentifier(fn.parameters[0].name) ? fn.parameters[0].name.text : null;
  const top = reject;
  const pathOf = (node) => {
    const problems = [];
    let deferred = null;
    let cur = node;
    let p = node.parent;
    while (p && cur !== top) {
      if (ts.isBlock(p)) {
        for (const s of p.statements) {
          if (s === cur) { break; }
          if (ts.isReturnStatement(s) || ts.isThrowStatement(s)) { problems.push('前面有无条件 ' + (ts.isReturnStatement(s) ? 'return' : 'throw') + '（执行不到）'); }
          else if (ts.isIfStatement(s) && collect(s, (x) => ts.isReturnStatement(x) || ts.isThrowStatement(x)).length > 0 &&
            !litAtoms(s.expression, false).every((a) => isLifecycleAtom(a, view, LIFECYCLE_EXTRA[WITHDRAW]))) {
            problems.push('前面有条件提前返回「' + compact(s.expression) + '」');
          }
        }
      } else if (ts.isIfStatement(p)) {
        if (cur !== p.expression) {
          const as = litAtoms(p.expression, cur === p.thenStatement);
          if (as.length === 0 || !as.every((a) => isLifecycleAtom(a, view, LIFECYCLE_EXTRA[WITHDRAW]))) { problems.push('写在条件「' + compact(p.expression) + '」里'); }
        }
      } else if (ts.isConditionalExpression(p) || (ts.isBinaryExpression(p) && [ts.SyntaxKind.AmpersandAmpersandToken,
        ts.SyntaxKind.BarBarToken, ts.SyntaxKind.QuestionQuestionToken].indexOf(p.operatorToken.kind) >= 0)) {
        problems.push('写在条件表达式「' + compact(p) + '」里');
      } else if (ts.isIterationStatement(p, false) || ts.isSwitchStatement(p) || ts.isCaseClause(p) || ts.isDefaultClause(p) ||
        ts.isTryStatement(p) || ts.isCatchClause(p) || ts.isLabeledStatement(p) || ts.isCaseBlock(p)) {
        problems.push('写在循环 / switch / try 里');
      } else if (ts.isArrowFunction(p) || ts.isFunctionExpression(p)) {
        if (deferred === null && p.parent && ts.isCallExpression(p.parent) && calleeText(p.parent) === 'setTimeout' &&
          p.parent.arguments[0] === p) { deferred = p.parent; }
        else { problems.push('写在不会被直接执行的函数里'); }
      } else if (isFunctionLike(p) || ts.isClassLike(p)) {
        problems.push('写在不会被直接执行的函数里');
      } else if (!(ts.isExpressionStatement(p) || ts.isParenthesizedExpression(p) || (ts.isCallExpression(p) && p === deferred) ||
        (ts.isBinaryExpression(p) && p.operatorToken.kind === ts.SyntaxKind.EqualsToken && cur === p.right))) {
        problems.push('写在「' + ts.SyntaxKind[p.kind] + '」里（不是直线语句）');
      }
      cur = p;
      p = p.parent;
    }
    return { problems: problems, deferred: deferred };
  };
  const fieldWrites = writesTo(reject, m[1]);
  const backs = fieldWrites.filter((w) => w.rhs && ts.isPropertyAccessExpression(unwrap(w.rhs)) && unwrap(w.rhs).name.text === 'inputText');
  const rejectedWrites = fieldWrites.filter((w) => w.rhs && param !== null && ts.isIdentifier(unwrap(w.rhs)) && unwrap(w.rhs).text === param);
  const why = [];
  let restored = 0;
  for (const b of backs) {
    const pb = pathOf(b.node);
    if (pb.problems.length) { why.push('写回「' + compact(b.node) + '」' + pb.problems.join('；')); continue; }
    if (twoWay) { restored++; continue; }
    if (pb.deferred === null) { why.push('写回「' + compact(b.node) + '」与被拒串写入在同一轮（text 不是 $$ 双向绑定，同值写入不刷新，框里留着被拒串）'); continue; }
    const before = rejectedWrites.filter((w) => {
      const pw = pathOf(w.node);
      return pw.problems.length === 0 && pw.deferred === null && w.node.end <= pb.deferred.pos;
    });
    if (before.length === 0) {
      why.push('写回前没有同步、直线地把 ' + m[1] + ' 写成被拒串（' + (param || 'onChange 入参') + '）——显示状态没变过，写回 inputText 不触发刷新');
      continue;
    }
    restored++;
  }
  if (restored === 0) {
    report('AF2-restore', reject, '被拒分支没有一定执行、一定生效地把金额框显示值 ' + m[1] + ' 写回已接受的金额（…inputText）' +
      (why.length ? '：' + why.join(' / ') : '（没有右值为 …inputText 的写入）'));
  }
  stats.restore = restored;
}

// ---------------------------------------------------------------- AF3：钱包小眼睛
function checkEye() {
  const ds = parse(DS_WALLET);
  const sf = parse(WALLET);
  if (!ds || !sf) { return; }
  const hero = findStruct(ds, 'WalletHeroCard');
  const view = findStruct(sf, 'WalletView');
  if (!hero) { incomplete.push(DS_WALLET + '：找不到 struct WalletHeroCard'); return; }
  if (!view) { incomplete.push(WALLET + '：找不到 struct WalletView'); return; }
  const params = new Set(hero.members.filter((m) => ts.isPropertyDeclaration(m) && decorators(m).indexOf('Param') >= 0).map(memberName));
  // FU-HM-ROOTSHOWN-CHAIN ②（编排 D10-1668 批，#24）：眼睛 / 问号改成不带子组件的 SymbolGlyph 叶子（带子组件的 Button 在设备上不可获焦），
  // 这里 Button 与 SymbolGlyph 都认；其余判据不变。
  const eyes = components(hero).filter((c) => (c.name === 'Button' || c.name === 'SymbolGlyph') &&
    attrCalls(c, 'onClick').some((k) => k.args[0] && compact(k.args[0]).indexOf('this.onToggleHidden(') >= 0));
  if (eyes.length !== 1) {
    report('AF3-eye', hero, '主卡眼睛按钮（onClick 调 onToggleHidden 的 Button）应恰一个，找到 ' + eyes.length + ' 个');
    return;
  }
  const idCalls = attrCalls(eyes[0], 'id');
  const eyeParams = new Set();
  for (const c of idCalls) {
    if (!c.args[0]) { continue; }
    walk(c.args[0], (n) => {
      if (ts.isPropertyAccessExpression(n) && n.expression.kind === ts.SyntaxKind.ThisKeyword && params.has(n.name.text)) { eyeParams.add(n.name.text); }
    });
  }
  if (eyeParams.size === 0) {
    report('AF3-eye', eyes[0].stmt, '主卡眼睛按钮没挂调用方可给的 id（@Param，如 eyeId）——切换后焦点无处可回');
    return;
  }
  const table = staticTable(sf);
  const heroCalls = components(view).filter((c) => c.name === 'WalletHeroCard');
  if (heroCalls.length !== 1) {
    report('AF3-eye', view, '钱包页 WalletHeroCard 应恰一处，找到 ' + heroCalls.length + ' 处');
    return;
  }
  const obj = heroCalls[0].args[0] ? unwrap(heroCalls[0].args[0]) : null;
  let eyeId = null;
  for (const p of eyeParams) {
    const v = propValue(obj, p);
    const s = v ? single(v, table) : null;
    if (s) { eyeId = s; }
  }
  if (!eyeId) {
    report('AF3-eye', heroCalls[0].stmt, '钱包页没给眼睛按钮非空静态 id（' + [...eyeParams].join(' / ') + '）');
    return;
  }
  stats.eyeId = eyeId;
  const each = forEachBuilding(view, 'this.heroCard(');
  if (each.length !== 1) {
    report('AF3-stable', view, '构建主卡的 ForEach 应恰一个，找到 ' + each.length + ' 个');
    return;
  }
  const keyMasked = keyReads(each[0].arguments[2], view).idents.has('masked');
  const toggle = propValue(obj, 'onToggleHidden');
  const back = toggle ? collect(toggle, (n) => ts.isCallExpression(n) && calleeText(n) === 'CouliFocusReturn.to' && n.arguments.length >= 2 &&
    single(n.arguments[1], table) === eyeId) : [];
  if (keyMasked && back.length === 0) {
    report('AF3-stable', each[0].arguments[2], '主卡 ForEach 键仍含 masked（切换小眼睛整卡重建、焦点丢失），且 onToggleHidden 没有 ' +
      'CouliFocusReturn.to(…, \'' + eyeId + '\') 兜底');
  }
  stats.eyeStrategy = keyMasked ? 'focus-return' : 'no-rebuild';
}

// ---------------------------------------------------------------- AF3-mask（v2，Codex r1 S2-4）：金额隐藏时主卡 / 数字格不露数字
/**
 * WalletHeroCard：
 *   · amount / amountSpoken / amountHidden 是 @Param 且不是 @Once（不重建方案靠参数刷新；@Once 会冻住旧值）；
 *   · 主卡金额 Text（读屏名以 this.label 开头的那个）恰一个：显示值是以 this.amountHidden 为条件的三元，隐藏支 PriceTerms.amountMask、显示支 this.amount；
 *     读屏名里有同条件的三元，隐藏支 PriceTerms.amountHiddenSpoken、显示支 this.amountSpoken；
 *   · 卡内每处读 this.amount / this.amountSpoken 都在断言 this.amountHidden 为假的分支里（别处不露）；
 *   · 卡内 AmountGrid 的 masked 实参就是 this.amountHidden。
 * AmountGrid.cell：每处读 item.value / item.spoken 都在断言 this.hides(item)（或 this.masked）为假的分支里。
 * WalletView：WalletHeroCard 的 amountHidden 实参是 this.maskUi.masked，onToggleHidden 调 this.maskUi.toggle()。
 */
function checkMask() {
  const ds = parse(DS_WALLET);
  const sf = parse(WALLET);
  if (!ds || !sf) { return; }
  const hero = findStruct(ds, 'WalletHeroCard');
  const grid = findStruct(ds, 'AmountGrid');
  const view = findStruct(sf, 'WalletView');
  if (!hero || !grid || !view) { return; }
  for (const name of ['amount', 'amountSpoken', 'amountHidden']) {
    const mem = hero.members.find((m) => ts.isPropertyDeclaration(m) && memberName(m) === name);
    const ds2 = mem ? decorators(mem) : [];
    if (!mem || ds2.indexOf('Param') < 0 || ds2.indexOf('Once') >= 0) {
      report('AF3-mask', mem || hero, 'WalletHeroCard.' + name + ' 应是 @Param 且不带 @Once（主卡不重建，金额与隐藏状态只靠参数刷新）');
    }
  }
  const hiddenIs = (a, want) => a.pol === want && compact(a.e) === 'this.amountHidden';
  const branchOf = (cond) => {
    const as = litAtoms(cond, true);
    if (as.some((a) => hiddenIs(a, true))) { return 'true'; }
    if (as.some((a) => hiddenIs(a, false))) { return 'false'; }
    return null;
  };
  /** 三元 c：隐藏支、显示支分别是 hid、shown（按条件极性）。 */
  const maskTernary = (c, hid, shown) => {
    c = unwrap(c);
    if (!c || !ts.isConditionalExpression(c)) { return false; }
    const b = branchOf(c.condition);
    if (b === null) { return false; }
    const h = compact(b === 'true' ? c.whenTrue : c.whenFalse);
    const v = compact(b === 'true' ? c.whenFalse : c.whenTrue);
    return h === hid && v === shown;
  };
  const all = components(hero);
  const mains = all.filter((c) => c.name === 'Text' && attrCalls(c, 'accessibilityText').some((a) => a.args[0] &&
    compact(leftmost(a.args[0])) === 'this.label'));
  if (mains.length !== 1) {
    report('AF3-mask', hero, '主卡金额 Text（读屏名以 this.label 开头）应恰一个，找到 ' + mains.length + ' 个');
  } else {
    const main = mains[0];
    if (!main.args[0] || !maskTernary(main.args[0], 'PriceTerms.amountMask', 'this.amount')) {
      report('AF3-mask', main.stmt, '主卡金额 Text 显示值「' + (main.args[0] ? compact(main.args[0]) : '') + '」不是「this.amountHidden ? PriceTerms.amountMask : ' +
        'this.amount」（隐藏后可见数字仍在）');
    }
    const sp = attrCalls(main, 'accessibilityText')[0];
    const ternaries = collect(sp.args[0], (n) => ts.isConditionalExpression(n));
    if (!ternaries.some((t) => maskTernary(t, 'PriceTerms.amountHiddenSpoken', 'this.amountSpoken'))) {
      report('AF3-mask', sp.node, '主卡金额读屏名没有「this.amountHidden ? PriceTerms.amountHiddenSpoken : this.amountSpoken」（隐藏后读屏仍读金额）');
    }
  }
  const build = method(hero, 'build');
  for (const r of collect(build || hero, (n) => ts.isPropertyAccessExpression(n) && n.expression.kind === ts.SyntaxKind.ThisKeyword &&
    (n.name.text === 'amount' || n.name.text === 'amountSpoken'))) {
    if (!guardsPol(r, null).some((a) => hiddenIs(a, false))) {
      report('AF3-mask', r, '主卡里读 ' + compact(r) + ' 的地方不在「this.amountHidden 为假」的分支里（金额隐藏时会露出数字 / 读出金额）');
    }
  }
  const grids = all.filter((c) => c.name === 'AmountGrid');
  const gm = grids.length === 1 && grids[0].args[0] ? propValue(unwrap(grids[0].args[0]), 'masked') : null;
  if (!gm || compact(gm) !== 'this.amountHidden') {
    report('AF3-mask', grids[0] ? grids[0].stmt : hero, '主卡数字格 AmountGrid 的 masked 实参应恰为 this.amountHidden（隐藏时数字格也要 ****）');
  }
  const cell = method(grid, 'cell');
  if (cell) {
    const hideAtom = (a) => !a.pol && (/^this\.hides\(item\)$/.test(compact(a.e)) || compact(a.e) === 'this.masked');
    for (const r of collect(cell, (n) => ts.isPropertyAccessExpression(n) && compact(n.expression) === 'item' &&
      (n.name.text === 'value' || n.name.text === 'spoken'))) {
      if (!guardsPol(r, null).some(hideAtom)) {
        report('AF3-mask', r, 'AmountGrid 格里读 ' + compact(r) + ' 的地方不在「this.hides(item) 为假」的分支里（金额隐藏时格子露数字）');
      }
    }
  }
  const calls2 = components(view).filter((c) => c.name === 'WalletHeroCard');
  if (calls2.length === 1) {
    const obj = unwrap(calls2[0].args[0]);
    const ah = propValue(obj, 'amountHidden');
    if (!ah || compact(ah) !== 'this.maskUi.masked') {
      report('AF3-mask', calls2[0].stmt, '钱包页 WalletHeroCard 的 amountHidden 实参应为 this.maskUi.masked（实际「' + (ah ? compact(ah) : '') + '」）');
    }
    const tg = propValue(obj, 'onToggleHidden');
    if (!tg || collect(tg, (n) => ts.isCallExpression(n) && calleeText(n) === 'this.maskUi.toggle').length === 0) {
      report('AF3-mask', calls2[0].stmt, '钱包页 onToggleHidden 没有调 this.maskUi.toggle()');
    }
  }
}

// ---------------------------------------------------------------- AF4：二次验证标题读屏焦点
function checkStepUp() {
  const sf = parse(STEP_UP);
  if (!sf) { return; }
  const panel = findStruct(sf, 'StepUpPanel');
  if (!panel) { incomplete.push(STEP_UP + '：找不到 struct StepUpPanel'); return; }
  const table = staticTable(sf);
  const all = components(panel);
  const titles = all.filter((c) => idsOf(c, table).indexOf(ID_TITLE) >= 0);
  if (titles.length !== 1) {
    report('AF4-title', panel, '标题（id ' + ID_TITLE + '）应恰一个，找到 ' + titles.length + ' 个');
    return;
  }
  const title = titles[0];
  const focusTitle = (root, name) => collect(root, (n) => ts.isCallExpression(n) && calleeText(n) === 'CouliFocusReturn.' + name &&
    n.arguments.length >= 2 && single(n.arguments[1], table) === ID_TITLE);
  const appearOn = [title].concat(ancestors(title, all));
  let ok = 0;
  for (const c of appearOn) {
    for (const a of attrCalls(c, 'onAppear')) {
      if (a.args[0] && focusTitle(a.args[0], 'accessibilityFocus').length > 0) { ok++; }
    }
  }
  if (ok === 0) {
    report('AF4-title', title.stmt, '半屏打开时没有把读屏焦点移到标题（标题或其外层的 onAppear 里 CouliFocusReturn.accessibilityFocus(…, \'' + ID_TITLE + '\')）');
  }
  for (const t of focusTitle(sf, 'to')) {
    report('AF4-title', t, '对标题用了 CouliFocusReturn.to（会把键盘焦点从验证码框抢走；只能移读屏焦点）');
  }
  if (!attrCalls(title, 'focusable').some((c) => c.args[0] && isTrueLiteral(c.args[0]))) {
    report('AF4-title', title.stmt, '标题不再 focusable(true)（读屏焦点落不上）');
  }
  if (attrCalls(title, 'defaultFocus').length > 0) {
    report('AF4-code', title.stmt, '标题设了 defaultFocus（键盘默认焦点应仍在验证码框）');
  }
  const codes = all.filter((c) => c.name === 'TextInput' && idsOf(c, table).indexOf(ID_CODE) >= 0);
  if (codes.length !== 1 || !attrCalls(codes[0], 'defaultFocus').some((c) => c.args[0] && isTrueLiteral(c.args[0]))) {
    report('AF4-code', codes[0] ? codes[0].stmt : panel, '验证码框（' + ID_CODE + '）不再 defaultFocus(true)（外接键盘 / 输入法应照旧落在验证码框）');
  }
  stats.titleFocus = ok;
  // AF7-title（v2）：标题移焦若延时执行，执行时须复核面板仍在（关面板 / 重开后旧任务不发）。
  const st = staleFocus('AF7-title', panel, ID_TITLE, table, {});
  stats.titleFocusDeferred = st.deferred;
  stats.titleFocusRechecked = st.ok;
}

// ---------------------------------------------------------------- AF5：金额格标签只读一次
function checkLabels() {
  const ds = parse(DS_WALLET);
  if (!ds) { return; }
  const table = staticTable(ds);
  const grid = findStruct(ds, 'AmountGrid');
  const hero = findStruct(ds, 'WalletHeroCard');
  if (!grid) { incomplete.push(DS_WALLET + '：找不到 struct AmountGrid'); return; }
  if (!hero) { incomplete.push(DS_WALLET + '：找不到 struct WalletHeroCard'); return; }
  const cell = method(grid, 'cell');
  if (!cell) { incomplete.push(DS_WALLET + '：AmountGrid 找不到 cell'); return; }
  const labelCase = (where, container, labelExpr, valueMarker) => {
    const all = components(container);
    const labels = all.filter((c) => c.name === 'Text' && c.args[0] && compact(c.args[0]) === labelExpr);
    if (labels.length === 0) {
      report('AF5-dup', container, where + ' 找不到标签 Text(' + labelExpr + ')');
      return all;
    }
    for (const l of labels) {
      if (!surelyHidden(l, all, table)) {
        report('AF5-dup', l.stmt, where + ' 标签 Text(' + labelExpr + ') 读屏仍可读（金额读屏名已带标签，会读两遍；应 accessibilityLevel(\'no\')）');
      }
      for (const a of ancestors(l, all)) {
        for (const g of attrCalls(a, 'accessibilityGroup')) {
          if (!(g.args[0] && isFalseLiteral(g.args[0]))) {
            report('AF5-dup', g.node, where + ' 标签所在的 ' + a.name + ' 仍 accessibilityGroup(' + (g.args[0] ? compact(g.args[0]) : '') + ')（成组读出标签）');
          }
        }
      }
    }
    const valueTexts = all.filter((c) => c.name === 'Text' && c.args[0] && compact(c.args[0]).indexOf(valueMarker) >= 0);
    if (valueTexts.length === 0) {
      report('AF5-spoken', container, where + ' 找不到金额 Text（' + valueMarker + '）');
    }
    for (const v of valueTexts) {
      const sp = attrCalls(v, 'accessibilityText');
      const lm = sp.length === 1 && sp[0].args[0] ? leftmost(sp[0].args[0]) : null;
      if (!lm || compact(lm) !== labelExpr || maybeHidden(v, all, table)) {
        report('AF5-spoken', v.stmt, where + ' 金额 Text 的读屏名不再以标签（' + labelExpr + '）开头或被隐藏（去重不能把标签丢了）');
      }
    }
    return all;
  };
  const cellAll = labelCase('AmountGrid 格', cell, 'item.label', 'item.value');
  const helps = cellAll.filter((c) => (c.name === 'Button' || c.name === 'SymbolGlyph') && attrCalls(c, 'accessibilityText').some((a) => a.args[0] && compact(a.args[0]) === 'item.helpLabel'));
  if (helps.length !== 1) {
    report('AF5-help', cell, 'AmountGrid 格的问号按钮（accessibilityText(item.helpLabel)）应恰一个，找到 ' + helps.length + ' 个');
  } else if (maybeHidden(helps[0], cellAll, table) || !attrCalls(helps[0], 'focusable').some((c) => c.args[0] && isTrueLiteral(c.args[0]))) {
    report('AF5-help', helps[0].stmt, 'AmountGrid 格的问号按钮可能被读屏隐藏或不可聚焦（有问号的格问号仍要单独可读）');
  }
  labelCase('WalletHeroCard', hero, 'this.label', 'this.amount');
}

// ---------------------------------------------------------------- AF6：资金调用集合
function fundCalls(rel) {
  const sf = parse(rel);
  if (!sf) { return; }
  const receivers = FUND_RECEIVERS[rel];
  const out = [];
  walk(sf, (n) => {
    if (!ts.isCallExpression(n) || !ts.isPropertyAccessExpression(n.expression)) { return; }
    const recv = unwrap(n.expression.expression);
    let r = compact(recv);
    if (ts.isIdentifier(recv)) {
      const init = localConst(recv, recv.text);
      if (init) { r = compact(init); }
    }
    if (receivers.indexOf(r) < 0) { return; }
    const args = n.arguments.map((a) => compact(a)).join(',');
    out.push(r + '.' + n.expression.name.text + '(' + args + ')');
  });
  calls[rel] = out.sort();
}

checkWithdraw();
checkEye();
checkMask();
checkStepUp();
checkLabels();
for (const rel of Object.keys(FUND_RECEIVERS)) { fundCalls(rel); }
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete, calls: calls, stats: stats }));
