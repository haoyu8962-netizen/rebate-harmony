#!/usr/bin/env node
// FU-HM-LOGIN-PHONE-LAYOUT-harmony 宿主守卫的解析部分（由 check_login_phone.py 调用，不单独跑）。用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS，
// 判定全部走 AST（struct / 组件尾随闭包 / 属性链 / @Builder 调用点 / 类方法），不用正则切块，注释与字符串里的字不算。写法照 tools/ci/l2button。
//   用法：node loginphone_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>"}}（LoginView.ets、BindPhoneView.ets）
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."]}
// 规则编号见 check_login_phone.py 文件头。
'use strict';
const fs = require('fs');
const path = require('path');

const LOGIN = 'features/auth/src/main/ets/LoginView.ets';
const BIND = 'features/auth/src/main/ets/BindPhoneView.ets';

const tsDir = process.argv[2];
if (!tsDir) { console.error('loginphone_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('loginphone_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('loginphone_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
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
function findStruct(sf, name) {
  let hit = null;
  ts.forEachChild(sf, (n) => { if (ts.isStructDeclaration(n) && n.name && n.name.text === name) { hit = n; } });
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
  return null;
}
/** 模块级 const 的字面量值（字符串 / 数字）。 */
function moduleConsts(sf) {
  const out = new Map();
  ts.forEachChild(sf, (n) => {
    if (!ts.isVariableStatement(n) || !(n.declarationList.flags & ts.NodeFlags.Const)) { return; }
    for (const d of n.declarationList.declarations) {
      if (!ts.isIdentifier(d.name) || !d.initializer) { continue; }
      const init = unwrap(d.initializer);
      if (isStr(init)) { out.set(d.name.text, init.text); }
      else if (ts.isNumericLiteral(init)) { out.set(d.name.text, Number(init.text)); }
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
/**
 * 表达式可能取到的字符串 / 数字值集合；判不了为 null。v2：可带「路径事实」facts（见 guardFacts），三元条件在事实下能定真假时只取那一支
 * （例：fieldError 里 phoneError 的赋值在 if (phone) 分支，焦点 id = phone ? ID_PHONE : ID_CODE 在该路径上只取 ID_PHONE）。
 */
function values(e, consts, depth, facts) {
  depth = depth || 0;
  if (depth > 8 || !e) { return null; }
  e = unwrap(e);
  if (isStr(e)) { return new Set([e.text]); }
  if (ts.isNumericLiteral(e)) { return new Set([Number(e.text)]); }
  if (ts.isConditionalExpression(e)) {
    const c = facts ? evalBool(e.condition, facts) : null;
    if (c === true) { return values(e.whenTrue, consts, depth + 1, facts); }
    if (c === false) { return values(e.whenFalse, consts, depth + 1, facts); }
    const a = values(e.whenTrue, consts, depth + 1, facts);
    const b = values(e.whenFalse, consts, depth + 1, facts);
    return a && b ? new Set([...a, ...b]) : null;
  }
  if (ts.isIdentifier(e)) {
    const local = localConst(e, e.text);
    if (local) { return values(local, consts, depth + 1, facts); }
    if (consts.has(e.text)) { return new Set([consts.get(e.text)]); }
    return null;
  }
  return null;
}

// ---------------------------------------------------------------- 路径事实（v2：T2 焦点交叉、I1 验证码步手机号错误）
// facts = { atoms: Map<紧凑文本, bool>, eq: Map<左侧紧凑文本, 右侧紧凑文本> }。原子按紧凑文本比较（同一方法里同名变量即同一个）；
// 相等原子规范成 "a===b"（左右排序），!== / != 取反。eq 记「已知 a 等于某个静态记号」，用于 a === 另一个静态记号 → false。

function newFacts() { return { atoms: new Map(), eq: new Map() }; }
function cloneFacts(f) { return { atoms: new Map(f.atoms), eq: new Map(f.eq) }; }
const EQ_OPS = new Set([ts.SyntaxKind.EqualsEqualsEqualsToken, ts.SyntaxKind.EqualsEqualsToken]);
const NE_OPS = new Set([ts.SyntaxKind.ExclamationEqualsEqualsToken, ts.SyntaxKind.ExclamationEqualsToken]);
function eqKey(a, b) { const x = compact(a); const y = compact(b); return x < y ? x + '===' + y : y + '===' + x; }
/** 静态记号：字符串 / 数字字面量、null、大写开头类的静态成员（LoginModel.STEP_PHONE）、全大写模块常量。 */
function staticToken(n) {
  n = unwrap(n);
  if (isStr(n) || ts.isNumericLiteral(n) || n.kind === ts.SyntaxKind.NullKeyword) { return true; }
  if (ts.isPropertyAccessExpression(n) && ts.isIdentifier(n.expression) && /^[A-Z]/.test(n.expression.text)) { return true; }
  return ts.isIdentifier(n) && /^[A-Z][A-Z0-9_]+$/.test(n.text);
}
function addFact(f, expr, pol) {
  const e = unwrap(expr);
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) { addFact(f, e.operand, !pol); return; }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    if (op === ts.SyntaxKind.AmpersandAmpersandToken && pol) { addFact(f, e.left, true); addFact(f, e.right, true); return; }
    if (op === ts.SyntaxKind.BarBarToken && !pol) { addFact(f, e.left, false); addFact(f, e.right, false); return; }
    if (EQ_OPS.has(op) || NE_OPS.has(op)) {
      const isEq = EQ_OPS.has(op) ? pol : !pol;
      f.atoms.set(eqKey(e.left, e.right), isEq);
      if (isEq && staticToken(e.right) && !staticToken(e.left)) { f.eq.set(compact(e.left), compact(e.right)); }
      if (isEq && staticToken(e.left) && !staticToken(e.right)) { f.eq.set(compact(e.right), compact(e.left)); }
      return;
    }
  }
  f.atoms.set(compact(e), pol);
}
/** 三值：true / false / null（判不了）。 */
function evalBool(expr, f) {
  const e = unwrap(expr);
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) {
    const v = evalBool(e.operand, f);
    return v === null ? null : !v;
  }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    if (op === ts.SyntaxKind.AmpersandAmpersandToken || op === ts.SyntaxKind.BarBarToken) {
      const a = evalBool(e.left, f);
      const b = evalBool(e.right, f);
      if (op === ts.SyntaxKind.AmpersandAmpersandToken) {
        if (a === false || b === false) { return false; }
        return a === true && b === true ? true : null;
      }
      if (a === true || b === true) { return true; }
      return a === false && b === false ? false : null;
    }
    if (EQ_OPS.has(op) || NE_OPS.has(op)) {
      let v = f.atoms.has(eqKey(e.left, e.right)) ? f.atoms.get(eqKey(e.left, e.right)) : null;
      if (v === null) {
        const pairs = [[e.left, e.right], [e.right, e.left]];
        for (const [x, y] of pairs) {
          if (staticToken(y) && f.eq.has(compact(x))) { v = f.eq.get(compact(x)) === compact(y); break; }
        }
      }
      if (v === null) { return null; }
      return EQ_OPS.has(op) ? v : !v;
    }
  }
  return f.atoms.has(compact(e)) ? f.atoms.get(compact(e)) : null;
}
/** node 在所在函数里的 if 条件（then = 真、else = 假）记成事实；只到 stopAt（含）为止。 */
function guardFacts(node, f, stopAt) {
  const out = f || newFacts();
  let cur = node;
  while (cur && cur.parent && cur !== stopAt) {
    const p = cur.parent;
    if (ts.isIfStatement(p) && cur !== p.expression) { addFact(out, p.expression, cur === p.thenStatement); }
    if (p === stopAt || ts.isMethodDeclaration(p) || ts.isFunctionDeclaration(p) || ts.isConstructorDeclaration(p)) { break; }
    cur = p;
  }
  return out;
}

// ---------------------------------------------------------------- 组件索引：struct 里每个组件语句、所在容器（跨 @Builder 调用点）

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

function indexStruct(struct) {
  const comps = [];
  const byRoot = new Map();
  walk(struct, (n) => {
    if (!ts.isExpressionStatement(n)) { return; }
    const ch = chainOf(n.expression);
    // 内置组件解析成 EtsComponentExpression；自定义组件（CouliButton 等）是首字母大写的普通调用。
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
  // this.<builder>(...) 调用语句
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

/** 组件所在的容器链（由内到外，每条调用路径一条；到 Scroll（含）或 build 为止）。 */
function containerPaths(idx, comp, stopAtScroll) {
  const out = [];
  function up(node, acc, seen, depth) {
    if (depth > 30) { out.push(acc); return; }
    let n = node;
    for (;;) {
      const p = n.parent;
      if (!p) { out.push(acc); return; }
      if (ts.isEtsComponentExpression(p) && p.body === n) {
        const c = idx.byRoot.get(p);
        const next = c ? acc.concat([c]) : acc;
        if (c && stopAtScroll && c.name === 'Scroll') { out.push(next); return; }
        n = c ? c.stmt : p;
        acc = next;
        continue;
      }
      if (ts.isMethodDeclaration(p)) {
        const name = memberName(p);
        const calls = idx.builderCalls.get(name) || [];
        if (name === 'build' || calls.length === 0) { out.push(acc); return; }
        for (const s of calls) {
          if (seen.has(s)) { continue; }
          const s2 = new Set(seen); s2.add(s);
          up(s, acc, s2, depth + 1);
        }
        return;
      }
      if (ts.isStructDeclaration(p) || ts.isSourceFile(p)) { out.push(acc); return; }
      n = p;
    }
  }
  up(comp.stmt, [], new Set(), 0);
  return out;
}

function idValues(comp, consts) {
  if (comp.name === 'CouliButton') {
    const v = propValue(comp.args[0], 'buttonId');
    return v ? (values(v, consts) || new Set()) : new Set();
  }
  const out = new Set();
  for (const c of comp.call('id')) {
    const v = values(c.args[0], consts);
    if (v) { for (const x of v) { out.add(x); } }
  }
  return out;
}

/** CouliButtonVariant 实参的可能取值；缺省 = PRIMARY；判不了为 null。 */
function variantValues(expr) {
  if (!expr) { return new Set(['PRIMARY']); }
  const e = unwrap(expr);
  if (ts.isPropertyAccessExpression(e) && ts.isIdentifier(e.expression) && e.expression.text === 'CouliButtonVariant') {
    return new Set([e.name.text]);
  }
  if (ts.isConditionalExpression(e)) {
    const a = variantValues(e.whenTrue);
    const b = variantValues(e.whenFalse);
    return a && b ? new Set([...a, ...b]) : null;
  }
  return null;
}

const SHRINK_ATTRS = ['maxFontScale', 'minFontScale', 'minFontSize', 'maxFontSize', 'heightAdaptivePolicy', 'maxLines', 'textOverflow'];

function isPercent(arg) {
  const e = unwrap(arg);
  return isStr(e) && /^\s*\d+(\.\d+)?%\s*$/.test(e.text);
}

/** onClick 处理函数里调到 needle（如 sendCode / tapResend）的属性链调用。 */
function onClickCalling(idx, needle) {
  const hits = [];
  for (const c of idx.comps) {
    if (c.name === 'CouliButton') { continue; }
    for (const call of c.call('onClick')) {
      const found = collect(call.args[0] || call.node, (n) => ts.isPropertyAccessExpression(n) && n.name.text === needle);
      if (found.length > 0) { hits.push({ comp: c, node: call.node }); }
    }
  }
  return hits;
}

function argsText(comp) { return comp.args.map((a) => compact(a)).join(','); }

/** LP1 / LP6：发码 / 重新获取必须是系统按钮（CouliButton 非 TEXT 变体、禁用接线），不得裸 Text + onClick。 */
function checkSystemButton(rule, file, idx, consts, id, needle, labelMarks) {
  const buttons = idx.comps.filter((c) => c.name === 'CouliButton' && idValues(c, consts).has(id));
  if (buttons.length === 0) {
    report(rule + '-button', idx.struct, '没有 buttonId 为 ' + id + ' 的 CouliButton（应是 L2 系统按钮）', file);
  }
  // 换行判定（LP2）除了系统按钮，也看现有的裸 id 节点与光秃文字节点（现树 Row 不换行导致截断的写法照样判红）。
  const placed = new Set();
  for (const c of idx.comps) {
    if (c.name !== 'CouliButton' && idValues(c, consts).has(id)) {
      report(rule + '-bare', c.root, c.name + ' 挂了 id ' + id + '：发码 / 重新获取不是系统按钮（裸 ' + c.name + ' + onClick）', file);
      placed.add(c);
    }
  }
  for (const h of onClickCalling(idx, needle)) {
    report(rule + '-bare', h.node, h.comp.name + '.onClick 里调 ' + needle + '：应由 CouliButton 的 onTap 触发', file);
  }
  for (const c of idx.comps) {
    if (c.name === 'CouliButton') { continue; }
    const text = argsText(c);
    for (const mark of labelMarks) {
      if (text.indexOf(mark) >= 0) {
        report(rule + '-label', c.root, c.name + ' 直接显示 ' + mark + '（倒计时 / 发码文字是光秃文字，应是系统按钮的文字）', file);
        placed.add(c);
      }
    }
  }
  if (buttons.length > 0 && labelMarks.length > 0) {
    const covered = buttons.some((b) => {
      const t = propValue(b.args[0], 'text');
      if (!t) { return false; }
      const raw = compact(t);
      if (labelMarks.some((m) => raw.indexOf(m) >= 0)) { return true; }
      // 经 this.<方法>() 取文字：方法体里出现标记也算
      return collect(t, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
        n.expression.expression.kind === ts.SyntaxKind.ThisKeyword).some((call) => {
        const m = idx.methods.get(call.expression.name.text);
        return m && labelMarks.some((mk) => compact(m).indexOf(mk) >= 0);
      });
    });
    if (!covered) {
      report(rule + '-label', buttons[0].root, '系统按钮的 text 不显示 ' + labelMarks.join(' / ') + '（倒计时没进按钮）', file);
    }
  }
  for (const b of buttons) {
    const obj = b.args[0];
    const vs = variantValues(propValue(obj, 'variant'));
    if (vs === null) {
      report(rule + '-variant', b.root, 'variant 无法静态判定（只认 CouliButtonVariant.X 或其三元组合）', file);
    } else if (vs.has('TEXT')) {
      report(rule + '-variant', b.root, 'variant 可能是 TEXT（文字按钮无底无框，折行后就是光秃文字，没有按钮外观）', file);
    }
    const dis = propValue(obj, 'disabled');
    if (!dis || dis.kind === ts.SyntaxKind.FalseKeyword) {
      report(rule + '-disabled', b.root, '没有接 disabled（倒计时 / 限流期间按钮应禁用）', file);
    }
    for (const a of SHRINK_ATTRS.concat(['height'])) {
      if (b.has(a)) { report(rule + '-shrink', b.call(a)[0].node, 'CouliButton 上挂 .' + a + '（缩字 / 定高 / 截断）', file); }
    }
    placed.add(b);
  }
  // 同一容器只报一次
  const seen = new Set();
  for (const c of placed) { checkWrapPath('LP2', file, idx, c, consts, id, seen); }
  return buttons;
}

/** LP2：按钮所在容器（到 Scroll 为止）不得是不换行的 Row / Flex，不得定高，不得缩字截断。 */
function checkWrapPath(rule, file, idx, comp, consts, id, seen) {
  for (const p of containerPaths(idx, comp, true)) {
    for (const c of p) {
      if (seen.has(c)) { continue; }
      seen.add(c);
      if (c.name === 'Row') {
        report(rule + '-row', c.root, id + ' 在不换行的 Row 里（放不下会被挤出 / 截断；应可换行：Flex wrap 或 Column）', file);
      } else if (c.name === 'Flex') {
        const wrap = propValue(c.args[0], 'wrap');
        const ok = wrap && /^FlexWrap\.(Wrap|WrapReverse)$/.test(compact(wrap));
        if (!ok) { report(rule + '-nowrap', c.root, id + ' 所在 Flex 没有 wrap: FlexWrap.Wrap', file); }
      } else if (c.name === 'RelativeContainer' || c.name === 'GridRow') {
        report(rule + '-container', c.root, id + ' 在 ' + c.name + ' 里（无法静态判定能否换行）', file);
      }
      if (c.name !== 'Scroll') {
        for (const h of c.call('height')) {
          if (!isPercent(h.args[0])) { report(rule + '-height', h.node, id + ' 所在 ' + c.name + ' 定高（折行后会被裁）', file); }
        }
        for (const a of SHRINK_ATTRS) {
          if (c.has(a)) { report(rule + '-shrink', c.call(a)[0].node, id + ' 所在 ' + c.name + ' 挂 .' + a, file); }
        }
      }
    }
  }
}

/** LP3 / LP5：手机号（与验证码）输入框单行、高度随字号长（最小 52）、不定高、不缩字；所在容器不定高。 */
function checkInput(file, idx, consts, id, mustTextInput) {
  const hits = idx.comps.filter((c) => c.name !== 'CouliButton' && idValues(c, consts).has(id));
  if (hits.length !== 1) {
    report('LP3-missing', idx.struct, 'id ' + id + ' 的输入框应恰有 1 个，实际 ' + hits.length, file);
    return null;
  }
  const c = hits[0];
  if (mustTextInput && c.name !== 'TextInput') {
    report('LP5-input', c.root, id + ' 是 ' + c.name + '（手机号必须是单行 TextInput，任何字号宽度不在数字中间断）', file);
  }
  for (const h of c.call('height')) {
    report('LP3-height', h.node, id + ' 固定 .height（200% 字号下数字被裁；应 constraintSize minHeight 随字号长）', file);
  }
  const cs = c.call('constraintSize');
  let min = null;
  for (const h of cs) {
    const v = propValue(h.args[0], 'minHeight');
    if (v) { min = values(v, consts); }
    if (propValue(h.args[0], 'maxHeight')) { report('LP3-max', h.node, id + ' constraintSize 带 maxHeight（会再次封顶裁字）', file); }
  }
  if (!min || !min.has(52) || min.size !== 1) {
    report('LP3-min', c.root, id + ' 没有 constraintSize({ minHeight: 52 })（最小 52vp，随字号长）', file);
  }
  for (const a of SHRINK_ATTRS) {
    if (c.has(a)) { report('LP3-shrink', c.call(a)[0].node, id + ' 挂 .' + a + '（不准缩字 / 截断）', file); }
  }
  for (const p of containerPaths(idx, c, true)) {
    for (const k of p) {
      if (k.name === 'Scroll') { continue; }
      for (const h of k.call('height')) {
        if (!isPercent(h.args[0])) { report('LP3-container', h.node, id + ' 所在 ' + k.name + ' 定高（框随字号长不起来）', file); }
      }
    }
  }
  return c;
}

/** 调用里（含嵌套箭头函数），以及经 this.<方法>() 展开的方法体里，找满足 pred 的调用。 */
/**
 * 与赋值「同路执行」的语句：从赋值所在语句向外逐层取同一语句列表里的兄弟语句，但跳过分支语句（if / switch：另一条路径），
 * 到 case 分支或函数体为止。例：绑定页 fieldError 里 if 分支赋值、分支外 say + 移焦 → 算；登录 field_error 里 phone 分支赋值、
 * 旁边 code 分支里有 say → 不算。
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

function reachableCalls(idx, scope, pred) {
  const out = [];
  const seen = new Set();
  function scan(node, depth) {
    walk(node, (n) => {
      if (!ts.isCallExpression(n)) { return; }
      if (pred(n)) { out.push(n); }
      if (depth < 4 && ts.isPropertyAccessExpression(n.expression) && n.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
        const m = idx.methods.get(n.expression.name.text);
        if (m && !seen.has(m) && m.body) { seen.add(m); scan(m.body, depth + 1); }
      }
    });
  }
  for (const s of (Array.isArray(scope) ? scope : [scope])) { scan(s, 0); }
  return out;
}
function isStaticCall(n, cls, method) {
  return ts.isPropertyAccessExpression(n.expression) && ts.isIdentifier(n.expression.expression) &&
    n.expression.expression.text === cls && n.expression.name.text === method;
}

// T4：说明实参的取值。值是 字符串 / 数字 / 布尔；OPAQUE 字符（\u0002）表示「未知文字，但不是该错误」；null = 判不了。
const OPAQUE = '\u0002';
const MARK = '\u0001ERR\u0001';
function descValue(e, err, idx, depth) {
  if (depth > 6 || !e) { return null; }
  e = unwrap(e);
  if (isStr(e)) { return e.text; }
  if (ts.isNumericLiteral(e)) { return Number(e.text); }
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isTemplateExpression(e)) {
    let s = e.head.text;
    for (const span of e.templateSpans) {
      const v = descValue(span.expression, err, idx, depth + 1);
      if (v === null) { return null; }
      s += String(v) + span.literal.text;
    }
    return s;
  }
  if (ts.isPropertyAccessExpression(e)) {
    if (/^this\.model$|^model$/.test(compact(e.expression))) { return e.name.text === err ? MARK : OPAQUE; }
    if (e.name.text === 'length') {
      const v = descValue(e.expression, err, idx, depth + 1);
      return typeof v === 'string' && v.indexOf(OPAQUE) < 0 ? v.length : null;
    }
    return OPAQUE;
  }
  if (ts.isCallExpression(e)) {
    // this.<方法>()（无参、方法体只有一句 return）：展开；其它调用：实参带该错误就算带（转述 / 拼接），否则当作别的文字。
    if (ts.isPropertyAccessExpression(e.expression) && e.expression.expression.kind === ts.SyntaxKind.ThisKeyword && e.arguments.length === 0) {
      const m = idx.methods.get(e.expression.name.text);
      if (m && m.body && m.body.statements.length === 1 && ts.isReturnStatement(m.body.statements[0])) {
        return descValue(m.body.statements[0].expression, err, idx, depth + 1);
      }
    }
    const carries = e.arguments.some((a) => { const v = descValue(a, err, idx, depth + 1); return typeof v === 'string' && v.indexOf(MARK) >= 0; });
    return carries ? MARK + OPAQUE : OPAQUE;
  }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) {
    const v = descValue(e.operand, err, idx, depth + 1);
    return typeof v === 'boolean' ? !v : null;
  }
  if (ts.isConditionalExpression(e)) {
    const c = descValue(e.condition, err, idx, depth + 1);
    if (c === true) { return descValue(e.whenTrue, err, idx, depth + 1); }
    if (c === false) { return descValue(e.whenFalse, err, idx, depth + 1); }
    const a = descValue(e.whenTrue, err, idx, depth + 1);
    const b = descValue(e.whenFalse, err, idx, depth + 1);
    return typeof a === 'string' && typeof b === 'string' && a.indexOf(MARK) >= 0 && b.indexOf(MARK) >= 0 ? a : null;
  }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    const a = descValue(e.left, err, idx, depth + 1);
    if (op === ts.SyntaxKind.QuestionQuestionToken) { return a; }
    const b = descValue(e.right, err, idx, depth + 1);
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

/**
 * LP4：出错时播报、焦点移到出错的框、错误说明关联到输入框（FU-HM-A11Y-01 / 02，D10-1231 共性 ②；主会话 06:24 ③ 只认输入框）。
 * v2：焦点目标只认该输入框（T1，不再收错误提示 Text）；按赋值所在路径的 if 条件求焦点 id，每个移焦调用在该路径上只能解析到该输入框（T2，
 * 防「手机号错移到验证码框」交叉）；说明实参在「有错误」时的取值必须带该错误（T4，不只看记号）。
 */
function checkA11y(file, idx, consts, fields) {
  for (const f of fields) {
    const input = idx.comps.find((c) => c.name !== 'CouliButton' && idValues(c, consts).has(f.input));
    if (!input) {
      report('LP4-desc', idx.struct, '找不到输入框 ' + f.input, file);
      continue;
    }
    const desc = input.call('accessibilityDescription');
    if (desc.length === 0 || desc[desc.length - 1].args.length === 0) {
      report('LP4-desc', input.root, f.input + ' 没有 accessibilityDescription（错误没关联到输入框）', file);
    } else {
      // 链上多次设置以最后一次为准
      const v = descValue(desc[desc.length - 1].args[0], f.err, idx, 0);
      if (v === null) {
        report('LP4-desc', input.root, f.input + ' 的 accessibilityDescription 实参无法静态判定是否在出错时带 ' + f.err, file);
      } else if (typeof v !== 'string' || v.indexOf(MARK) < 0) {
        report('LP4-desc', input.root, f.input + ' 的 accessibilityDescription 在 ' + f.err + ' 非空时不带这句错误（错误没关联到输入框）', file);
      }
    }
    const sets = collect(idx.struct, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      ts.isPropertyAccessExpression(n.left) && n.left.name.text === f.err && /^this\.model$|^model$/.test(compact(n.left.expression)));
    const nonEmpty = sets.filter((n) => { const r = unwrap(n.right); return !(isStr(r) && r.text.length === 0); });
    if (nonEmpty.length === 0) {
      report('LP4-none', idx.struct, '没有给 ' + f.err + ' 赋错误文字的地方（错误显示被删了？）', file);
    }
    for (const a of nonEmpty) {
      const scope = unconditionalScope(a);
      if (scope.length === 0) { continue; }
      const says = reachableCalls(idx, scope, (n) => isStaticCall(n, 'CouliAnnounce', 'say'));
      if (says.length === 0) {
        report('LP4-say', a, f.err + ' 出错时没有 CouliAnnounce.say 播报（读屏听不到）', file);
      }
      const focus = reachableCalls(idx, scope, (n) => isStaticCall(n, 'CouliFocusReturn', 'accessibilityFocus') ||
        isStaticCall(n, 'CouliFocusReturn', 'to'));
      if (focus.length === 0) {
        report('LP4-focus', a, f.err + ' 出错时没有把读屏焦点移到出错的框（CouliFocusReturn.accessibilityFocus / to）', file);
        continue;
      }
      const facts = guardFacts(a);
      for (const call of focus) {
        const v = values(call.arguments[1], consts, 0, facts);
        if (v === null) {
          report('LP4-focus', a, f.err + ' 出错时的焦点 id 无法静态判定（' + lineOf(call) + ' 行；应只移到 ' + f.input + '）', file);
        } else {
          const wrong = [...v].filter((x) => x !== f.input);
          if (wrong.length > 0) {
            report('LP4-focus', a, f.err + ' 出错时焦点可能移到 ' + wrong.join(' / ') + '（' + lineOf(call) +
              ' 行；只认出错的输入框 ' + f.input + '，不认错误提示、不认另一个框）', file);
          }
        }
      }
    }
  }
}

/** disabled 实参按顶层 || 拆开（经无参、只有一句 return 的 this.<方法>() 展开）。 */
function disjuncts(e, idx, depth) {
  e = unwrap(e);
  if (depth > 4 || !e) { return []; }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.BarBarToken) {
    return disjuncts(e.left, idx, depth + 1).concat(disjuncts(e.right, idx, depth + 1));
  }
  if (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression) && e.expression.expression.kind === ts.SyntaxKind.ThisKeyword &&
    e.arguments.length === 0) {
    const m = idx.methods.get(e.expression.name.text);
    if (m && m.body && m.body.statements.length === 1 && ts.isReturnStatement(m.body.statements[0])) {
      return disjuncts(m.body.statements[0].expression, idx, depth + 1);
    }
  }
  return [e];
}

/** T3（LP1-pending）：绑定页待确认（model.pending 非空）时发码按钮必须禁用——Core sendCode 与视图 sendCode 都不判 pending，只靠这一条。 */
function checkPendingDisabled(rule, file, idx, buttons) {
  for (const b of buttons) {
    const dis = propValue(b.args[0], 'disabled');
    const ok = dis && disjuncts(dis, idx, 0).some((d) => ts.isBinaryExpression(d) && NE_OPS.has(d.operatorToken.kind) &&
      [[d.left, d.right], [d.right, d.left]].some(([x, y]) => /^(this\.)?model\.pending$/.test(compact(x)) && unwrap(y).kind === ts.SyntaxKind.NullKeyword));
    if (!ok) {
      report(rule, b.root, '发码按钮的 disabled 没有（以 || 并列）接 model.pending !== null：待确认卡显示期间仍能发码', file);
    }
  }
}

// ---------------------------------------------------------------- LP7（I1 先红）：登录验证码步遇手机号错误
const TOAST_LIKE = (n) => isStaticCall(n, 'CouliToast', 'show') || isStaticCall(n, 'CouliAnnounce', 'say') ||
  (ts.isPropertyAccessExpression(n.expression) && n.expression.expression.kind === ts.SyntaxKind.ThisKeyword && n.expression.name.text === 'toast');

function enclosingMethod(node) {
  let n = node.parent;
  while (n && !ts.isMethodDeclaration(n)) { n = n.parent; }
  return n || null;
}
function stmtOf(node) {
  let n = node;
  while (n && !(n.parent && (ts.isBlock(n.parent) || ts.isCaseClause(n.parent) || ts.isDefaultClause(n.parent)))) { n = n.parent; }
  return n;
}
function contains(outer, inner) { return inner.pos >= outer.pos && inner.end <= outer.end; }
/** 语句是否让页面回到手机号步：this.model.step = LoginModel.STEP_PHONE，或（经 this.<方法>() 展开 3 层）调了 pageFlow.backToPhone()。 */
function backToPhoneStmt(idx, s) {
  if (ts.isIfStatement(s) || ts.isSwitchStatement(s)) { return false; }
  let hit = false;
  const seen = new Set();
  function scan(node, depth) {
    walk(node, (n) => {
      if (hit) { return; }
      if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken && /^(this\.)?model\.step$/.test(compact(n.left)) &&
        /^LoginModel\.STEP_PHONE$/.test(compact(n.right))) { hit = true; }
      if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)) {
        if (n.expression.name.text === 'backToPhone' && /pageFlow$/.test(compact(n.expression.expression))) { hit = true; }
        if (depth < 3 && n.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
          const m = idx.methods.get(n.expression.name.text);
          if (m && m.body && !seen.has(m)) { seen.add(m); scan(m.body, depth + 1); }
        }
      }
    });
  }
  scan(s, 0);
  return hit;
}
/** 路径事实：node 所在各层 if 条件 + 同一（及外层）语句列表里排在它前面的「回手机号步」语句。 */
function pathFacts(idx, node, facts) {
  const f = guardFacts(node, facts);
  let cur = stmtOf(node);
  while (cur && cur.parent && !ts.isMethodDeclaration(cur.parent)) {
    const p = cur.parent;
    if (ts.isBlock(p) || ts.isCaseClause(p) || ts.isDefaultClause(p)) {
      for (const s of p.statements) {
        if (s === cur) { break; }
        if (backToPhoneStmt(idx, s)) { f.eq.set('this.model.step', 'LoginModel.STEP_PHONE'); }
      }
    }
    cur = p;
  }
  return f;
}
/** a、b 在同一方法里能否在同一次执行中都走到（不看 if 条件，只看 return / throw / break 与 switch 分支）。 */
function bothReach(a, b) {
  const [first, second] = a.pos <= b.pos ? [a, b] : [b, a];
  let cur = stmtOf(first);
  while (cur && cur.parent && !ts.isMethodDeclaration(cur.parent)) {
    const p = cur.parent;
    if (ts.isBlock(p) || ts.isCaseClause(p) || ts.isDefaultClause(p)) {
      const i = p.statements.indexOf(cur);
      for (const s of p.statements.slice(i + 1)) {
        if (contains(s, second)) { return true; }
        if (ts.isReturnStatement(s) || ts.isThrowStatement(s) || ts.isBreakStatement(s)) { return false; }
      }
      if (ts.isCaseClause(p) || ts.isDefaultClause(p)) { return false; }
    }
    if (contains(p, second) && (ts.isIfStatement(p) || ts.isConditionalExpression(p))) {
      // first 在 then、second 在 else（或反过来）：互斥，由条件事实判
      return true;
    }
    cur = p;
  }
  return false;
}

/** 事实下页面是否确定在手机号步（step 只有 STEP_PHONE / STEP_CODE 两值）。 */
function onPhoneStep(f) {
  const k = (x, y) => (x < y ? x + '===' + y : y + '===' + x);
  const phone = k('this.model.step', 'LoginModel.STEP_PHONE');
  const code = k('this.model.step', 'LoginModel.STEP_CODE');
  if (f.atoms.has(phone)) { return f.atoms.get(phone); }
  if (f.atoms.has(code)) { return !f.atoms.get(code); }
  if (f.eq.has('this.model.step')) { return f.eq.get('this.model.step') === 'LoginModel.STEP_PHONE'; }
  return null;
}

/**
 * LP7（I1，先红）：登录页 phoneError 出错时页面必须在手机号步（login_phone 只在手机号步挂载，否则移焦落空），且同一路径上不再另弹 toast /
 * 播报（否则读屏读两遍）。路径事实：出错点（fieldError(true, …) 的调用点，或直接赋值处）所在各层 if 条件 + 前面的「回手机号步」语句。
 * 认可两种改法：①只在 this.model.step === LoginModel.STEP_PHONE 时 fieldError，验证码步只 toast；②先 this.backToPhone() 再 fieldError。
 */
function checkCodeStepPhoneError(file, idx) {
  const assigns = collect(idx.struct, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
    ts.isPropertyAccessExpression(n.left) && n.left.name.text === 'phoneError' && /^this\.model$|^model$/.test(compact(n.left.expression)) &&
    !(isStr(unwrap(n.right)) && unwrap(n.right).text.length === 0));
  const reported = new Set();
  for (const a of assigns) {
    const m = enclosingMethod(a);
    if (!m) { continue; }
    const inner = guardFacts(a);
    const params = m.parameters.map((p) => ts.isIdentifier(p.name) ? p.name.text : '');
    const guardedByParam = params.some((p) => p && inner.atoms.has(p));
    // 出错点：赋值在以参数选字段的辅助方法里（fieldError(phone, text)）→ 取各调用点；否则就是赋值本身。
    let points = [{ node: a, facts: pathFacts(idx, a) }];
    if (guardedByParam) {
      points = [];
      for (const call of collect(idx.struct, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
        n.expression.expression.kind === ts.SyntaxKind.ThisKeyword && n.expression.name.text === memberName(m))) {
        const excluded = params.some((p, i) => {
          if (!p || !inner.atoms.has(p) || !call.arguments[i]) { return false; }
          const lit = unwrap(call.arguments[i]).kind;
          const v = lit === ts.SyntaxKind.TrueKeyword ? true : lit === ts.SyntaxKind.FalseKeyword ? false : null;
          return v !== null && v !== inner.atoms.get(p);
        });
        if (!excluded) { points.push({ node: call, facts: pathFacts(idx, call) }); }
      }
    }
    for (const pt of points) {
      const key = pt.node.pos;
      if (reported.has(key)) { continue; }
      reported.add(key);
      const onPhone = onPhoneStep(pt.facts);
      if (onPhone !== true) {
        report('LP7-step', pt.node, 'phoneError 出错时不能确定页面在手机号步（验证码步没有 login_phone，移焦落空）：' +
          '应只在 this.model.step === LoginModel.STEP_PHONE 时 fieldError（验证码步只 toast），或先 this.backToPhone()', file);
      }
      const pm = enclosingMethod(pt.node);
      const toasts = collect(pm, (n) => ts.isCallExpression(n) && TOAST_LIKE(n) && !contains(pt.node, n));
      // 直接赋值的写法：与赋值同路执行的那次 CouliAnnounce.say 就是出错播报本身，不算重复
      const own = pt.node === a ? unconditionalScope(a) : [];
      for (const t of toasts) {
        if (own.some((s) => contains(s, t) && isStaticCall(t, 'CouliAnnounce', 'say')) || !bothReach(pt.node, t)) { continue; }
        const tf = guardFacts(t, null, pm);
        let contradicted = false;
        for (const [k, v] of tf.atoms) {
          // 用 t 的每个条件原子在出错点事实下求值
          const ev = pt.facts.atoms.has(k) ? pt.facts.atoms.get(k) : null;
          if (ev !== null && ev !== v) { contradicted = true; }
        }
        let g = t;
        while (!contradicted && g && g !== pm) {
          const p = g.parent;
          if (p && ts.isIfStatement(p) && g !== p.expression) {
            const ev = evalBool(p.expression, pt.facts);
            if (ev !== null && ev !== (g === p.thenStatement)) { contradicted = true; }
          }
          g = p;
        }
        if (!contradicted) {
          report('LP7-dup', pt.node, 'phoneError 出错（fieldError 已播报）的同一路径上 ' + lineOf(t) + ' 行还会 toast / 播报：读屏读两遍', file);
        }
      }
    }
  }
}

/** LP5：脱敏号码所在 Text 不得设成任意字符处断行。 */
function checkMaskedText(file, idx) {
  const hits = idx.comps.filter((c) => c.name === 'Text' && /sentTo|CODE_SENT_TO/.test(argsText(c)));
  if (hits.length === 0) {
    report('LP5-sentto', idx.struct, '找不到「验证码已发送至 {phone}」的 Text', file);
  }
  for (const c of hits) {
    for (const w of c.call('wordBreak')) {
      if (/BREAK_ALL|HYPHENATION/.test(compact(w.node))) {
        report('LP5-wordbreak', w.node, '脱敏号码所在 Text 设了 ' + compact(w.args[0] || w.node) + '（会在数字中间断）', file);
      }
    }
    for (const a of ['maxFontScale', 'minFontSize', 'heightAdaptivePolicy']) {
      if (c.has(a)) { report('LP5-shrink', c.call(a)[0].node, '脱敏号码所在 Text 挂 .' + a + '（不准缩字）', file); }
    }
  }
}

// ---------------------------------------------------------------- 主流程

const login = parse(LOGIN);
const bind = parse(BIND);
if (login && bind) {
  const ls = findStruct(login, 'LoginView');
  const bs = findStruct(bind, 'BindPhoneView');
  if (!ls) { incomplete.push(LOGIN + '：找不到 struct LoginView'); }
  if (!bs) { incomplete.push(BIND + '：找不到 struct BindPhoneView'); }
  if (ls && bs) {
    const lc = moduleConsts(login);
    const bc = moduleConsts(bind);
    const li = indexStruct(ls);
    const bi = indexStruct(bs);
    // ① 绑定手机号页发码
    const sendButtons = checkSystemButton('LP1', BIND, bi, bc, 'bind_phone_send', 'sendCode', ['countdownText(', 'BindPhoneKeys.GET_CODE']);
    checkPendingDisabled('LP1-pending', BIND, bi, sendButtons);
    // ② 短信登录页手机号框；绑定页两个框钉住不回退
    checkInput(LOGIN, li, lc, 'login_phone', true);
    checkInput(BIND, bi, bc, 'bind_phone_phone', true);
    checkInput(BIND, bi, bc, 'bind_phone_code', false);
    // ③ 短信登录页验证码步「N 秒后可重新获取 / 重新获取」
    checkSystemButton('LP6', LOGIN, li, lc, 'login_resend', 'tapResend', ['LoginKeys.CODE_COUNTDOWN']);
    // ④ FU-HM-A11Y-01 / 02（登录）；绑定页同口径钉住
    checkA11y(LOGIN, li, lc, [{ err: 'phoneError', input: 'login_phone' }, { err: 'codeError', input: 'login_code' }]);
    checkA11y(BIND, bi, bc, [{ err: 'phoneError', input: 'bind_phone_phone' }, { err: 'codeError', input: 'bind_phone_code' }]);
    // 判据 1
    checkMaskedText(LOGIN, li);
    // I1（v2 先红）：验证码步遇手机号错误不重复播报、焦点不落空
    checkCodeStepPhoneError(LOGIN, li);
  }
}
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete }));
