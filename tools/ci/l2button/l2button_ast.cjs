#!/usr/bin/env node
// HM-L2-BUTTON 宿主守卫的解析部分（书 §3「结构」B1–B6；由 check_l2_button.py 调用，不单独跑）。用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS，
// 判定全部走 AST（struct / 组件尾随闭包 / 属性链 / 类方法），不用正则切块，注释与字符串里的字不算。写法照 tools/ci/tabbar/tabbar_ast.cjs。
//   用法：node l2button_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>"}, "scan": ["<相对路径>", ...]}（files 含必查文件和 scan 列出的页面候选文件）
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."]}
'use strict';
const fs = require('fs');
const path = require('path');

const BASICS = 'common/designsystem/src/main/ets/components/Basics.ets';
const CONTROLS = 'common/designsystem/src/main/ets/components/Controls.ets';
const PRICE = 'common/designsystem/src/main/ets/components/Price.ets';
const CARD = 'common/designsystem/src/main/ets/components/ProductCard.ets';
const MODELS = 'common/designsystem/src/main/ets/format/PriceModels.ets';
const MAPPER = 'common/designsystem/src/main/ets/format/ProductCardMapper.ets';
const DS_LIST = 'common/designsystem/src/test/List.test.ets';
const CATALOG = 'entry/src/staging/ets/catalog/CatalogManifest.ets';
const DETAIL = 'entry/src/staging/ets/catalog/CatalogDetail.ets';

const tsDir = process.argv[2];
if (!tsDir) { console.error('l2button_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('l2button_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('l2button_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
    process.exit(3);
  }
  return { ets: cfg.compilerOptions.ets, etsLoaderPath: path.dirname(cfgPath) };
}
const ETS_OPTIONS = etsOptions();

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const violations = [];
const incomplete = [];
const parsed = new Map();

function parse(rel) {
  if (parsed.has(rel)) { return parsed.get(rel); }
  const text = input.files[rel];
  if (text === undefined) {
    incomplete.push(rel + '：文件不存在，无法判定');
    parsed.set(rel, null);
    return null;
  }
  const kind = rel.endsWith('.ets') ? ts.ScriptKind.ETS : ts.ScriptKind.TS;
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true, kind, ETS_OPTIONS);
  if (sf.parseDiagnostics.length > 0) {
    const d = sf.parseDiagnostics[0];
    incomplete.push(rel + ':' + (sf.getLineAndCharacterOfPosition(d.start).line + 1) + ' 语法错误：' + ts.flattenDiagnosticMessageText(d.messageText, ' '));
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
function rootName(root) {
  if (root && ts.isEtsComponentExpression(root)) { return root.expression.getText(); }
  if (root && ts.isCallExpression(root)) { return root.expression.getText(); }
  return root ? root.getText() : '';
}
function memberName(m) { return m.name && (ts.isIdentifier(m.name) || ts.isStringLiteral(m.name)) ? m.name.text : ''; }
function findStruct(sf, name) {
  let hit = null;
  ts.forEachChild(sf, (n) => { if (ts.isStructDeclaration(n) && n.name && n.name.text === name) { hit = n; } });
  return hit;
}
function findClass(sf, name) {
  let hit = null;
  ts.forEachChild(sf, (n) => { if (ts.isClassDeclaration(n) && n.name && n.name.text === name) { hit = n; } });
  return hit;
}
function methodOf(owner, name) {
  return owner.members.find((m) => ts.isMethodDeclaration(m) && memberName(m) === name) || null;
}
function moduleFunction(sf, name) {
  let hit = null;
  ts.forEachChild(sf, (n) => { if (ts.isFunctionDeclaration(n) && n.name && n.name.text === name) { hit = n; } });
  return hit;
}
function moduleConstString(sf, name) {
  let value = null;
  ts.forEachChild(sf, (n) => {
    if (!ts.isVariableStatement(n)) { return; }
    for (const d of n.declarationList.declarations) {
      if (ts.isIdentifier(d.name) && d.name.text === name && d.initializer && isStr(d.initializer)) { value = d.initializer.text; }
    }
  });
  return value;
}
function property(obj, name) {
  if (!obj || !ts.isObjectLiteralExpression(obj)) { return null; }
  return obj.properties.find((p) => p.name && (ts.isIdentifier(p.name) || ts.isStringLiteral(p.name)) && p.name.text === name) || null;
}

// ---------------------------------------------------------------- 静态求值：buttonStyle / controlSize 实参随枚举取值的映射
class Unknown extends Error {}

/** 在 env（标识符 / this.x → 枚举成员全名）下求表达式的值：枚举成员全名字符串、布尔或 Unknown。 */
function evalExpr(e, env, ctx, depth) {
  if (depth > 12) { throw new Unknown('递归太深'); }
  e = unwrap(e);
  const text = compact(e);
  if (env.has(text)) { return env.get(text); }
  if (ts.isPropertyAccessExpression(e) && ts.isIdentifier(e.expression)) { return text; }
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) { return !evalBool(e.operand, env, ctx, depth + 1); }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    if (op === ts.SyntaxKind.AmpersandAmpersandToken) { return evalBool(e.left, env, ctx, depth + 1) && evalBool(e.right, env, ctx, depth + 1); }
    if (op === ts.SyntaxKind.BarBarToken) { return evalBool(e.left, env, ctx, depth + 1) || evalBool(e.right, env, ctx, depth + 1); }
    const eq = [ts.SyntaxKind.EqualsEqualsEqualsToken, ts.SyntaxKind.EqualsEqualsToken].includes(op);
    const ne = [ts.SyntaxKind.ExclamationEqualsEqualsToken, ts.SyntaxKind.ExclamationEqualsToken].includes(op);
    if (eq || ne) {
      const same = evalExpr(e.left, env, ctx, depth + 1) === evalExpr(e.right, env, ctx, depth + 1);
      return eq ? same : !same;
    }
  }
  if (ts.isConditionalExpression(e)) {
    return evalBool(e.condition, env, ctx, depth + 1) ? evalExpr(e.whenTrue, env, ctx, depth + 1) : evalExpr(e.whenFalse, env, ctx, depth + 1);
  }
  if (ts.isCallExpression(e)) {
    let fn = null;
    const callee = e.expression;
    if (ts.isPropertyAccessExpression(callee) && callee.expression.kind === ts.SyntaxKind.ThisKeyword) { fn = methodOf(ctx.struct, callee.name.text); }
    else if (ts.isIdentifier(callee)) { fn = moduleFunction(ctx.sf, callee.text); }
    if (!fn || !fn.body) { throw new Unknown('调用 ' + callee.getText() + ' 找不到定义'); }
    const inner = new Map(env);
    fn.parameters.forEach((p, i) => {
      if (e.arguments[i]) { inner.set(p.name.getText(), evalExpr(e.arguments[i], env, ctx, depth + 1)); }
    });
    const out = execBlock(fn.body.statements, inner, ctx, depth + 1);
    if (out === undefined) { throw new Unknown(callee.getText() + ' 没有返回'); }
    return out;
  }
  throw new Unknown('无法静态判定：' + e.getText().slice(0, 60));
}
function evalBool(e, env, ctx, depth) {
  const v = evalExpr(e, env, ctx, depth);
  if (typeof v !== 'boolean') { throw new Unknown('条件不是布尔：' + e.getText().slice(0, 60)); }
  return v;
}
/** 顺序执行语句，遇 return 返回其值；没有 return 返回 undefined。 */
function execBlock(statements, env, ctx, depth) {
  for (const s of statements) {
    const r = execStmt(s, env, ctx, depth);
    if (r !== undefined) { return r; }
  }
  return undefined;
}
function execStmt(s, env, ctx, depth) {
  if (ts.isReturnStatement(s)) { return s.expression ? evalExpr(s.expression, env, ctx, depth) : undefined; }
  if (ts.isBlock(s)) { return execBlock(s.statements, env, ctx, depth); }
  if (ts.isIfStatement(s)) {
    if (evalBool(s.expression, env, ctx, depth)) { return execStmt(s.thenStatement, env, ctx, depth); }
    return s.elseStatement ? execStmt(s.elseStatement, env, ctx, depth) : undefined;
  }
  if (ts.isVariableStatement(s)) {
    for (const d of s.declarationList.declarations) { if (d.initializer) { env.set(d.name.getText(), evalExpr(d.initializer, env, ctx, depth)); } }
    return undefined;
  }
  if (ts.isSwitchStatement(s)) {
    const subject = evalExpr(s.expression, env, ctx, depth);
    const clauses = s.caseBlock.clauses;
    let start = clauses.findIndex((c) => ts.isCaseClause(c) && evalExpr(c.expression, env, ctx, depth) === subject);
    if (start < 0) { start = clauses.findIndex((c) => ts.isDefaultClause(c)); }
    if (start < 0) { return undefined; }
    for (let i = start; i < clauses.length; i++) {
      for (const st of clauses[i].statements) {
        if (st.kind === ts.SyntaxKind.BreakStatement) { return undefined; }
        const r = execStmt(st, env, ctx, depth);
        if (r !== undefined) { return r; }
      }
    }
    return undefined;
  }
  if (ts.isExpressionStatement(s)) { return undefined; }
  throw new Unknown('不支持的语句：' + s.getText().slice(0, 60));
}

// ---------------------------------------------------------------- B1 系统 Button + buttonStyle / controlSize / stateEffect / enabled
const STYLE_WANT = { 'CouliButtonVariant.PRIMARY': 'ButtonStyleMode.EMPHASIZED', 'CouliButtonVariant.ON_BRAND': 'ButtonStyleMode.EMPHASIZED',
  'CouliButtonVariant.SECONDARY': 'ButtonStyleMode.NORMAL', 'CouliButtonVariant.TEXT': 'ButtonStyleMode.TEXTUAL' };
const SIZE_WANT = { 'CouliButtonSize.COMPACT': 'ControlSize.SMALL', 'CouliButtonSize.REGULAR': 'ControlSize.NORMAL' };

function checkMapping(rule, call, subject, want, ctx) {
  for (const key of Object.keys(want)) {
    const env = new Map([[subject, key]]);
    let got;
    try { got = evalExpr(call.args[0], env, ctx, 0); } catch (e) {
      if (!(e instanceof Unknown)) { throw e; }
      report(rule, call.node, call.name + ' 的实参无法按 ' + subject + ' 静态判定（' + e.message + '）');
      return;
    }
    if (got !== want[key]) { report(rule, call.node, call.name + '：' + key + ' 应为 ' + want[key] + '，实际 ' + got); }
  }
}

function checkCouliButton() {
  const sf = parse(BASICS);
  if (!sf) { return; }
  const struct = findStruct(sf, 'CouliButton');
  if (!struct) { report('B1-root', null, 'Basics.ets 找不到 struct CouliButton', BASICS); return; }
  const build = methodOf(struct, 'build');
  const stmts = build && build.body ? build.body.statements : [];
  if (stmts.length !== 1 || !ts.isExpressionStatement(stmts[0])) {
    report('B1-root', build || struct, 'CouliButton.build 应只有一个根节点（系统 Button），实际 ' + stmts.length + ' 条语句');
    return;
  }
  const chain = chainOf(stmts[0].expression);
  if (rootName(chain.root) !== 'Button' || !ts.isEtsComponentExpression(chain.root)) {
    report('B1-root', stmts[0], 'CouliButton.build 根节点应是系统 Button(，实际 ' + rootName(chain.root));
    return;
  }
  const names = chain.calls.map((c) => c.name);
  const ctx = { sf: sf, struct: struct };
  for (const need of ['buttonStyle', 'controlSize', 'enabled']) {
    const hits = chain.calls.filter((c) => c.name === need);
    if (hits.length !== 1) { report('B1-chain', stmts[0], 'Button 链上 .' + need + '( 应恰好一处，实际 ' + hits.length); }
  }
  const style = chain.calls.find((c) => c.name === 'buttonStyle');
  if (style) { checkMapping('B1-style', style, 'this.variant', STYLE_WANT, ctx); }
  const size = chain.calls.find((c) => c.name === 'controlSize');
  if (size) { checkMapping('B1-size', size, 'this.buttonSize', SIZE_WANT, ctx); }
  // stateEffect：构造参数或链上，不能写死 false（按压要有系统反馈）。
  const opts = chain.root.arguments && chain.root.arguments[0];
  const effectProp = property(opts, 'stateEffect');
  const effectCall = chain.calls.find((c) => c.name === 'stateEffect');
  const effect = effectProp ? effectProp.initializer : (effectCall ? effectCall.args[0] : null);
  if (!effect) { report('B1-effect', chain.root, 'Button 没有 stateEffect（按压用系统 stateEffect）'); }
  else if (unwrap(effect).kind === ts.SyntaxKind.FalseKeyword) { report('B1-effect', effect, 'stateEffect 写死 false'); }
  const typeProp = property(opts, 'type');
  if (!typeProp || compact(typeProp.initializer) !== 'ButtonType.Normal') { report('B1-root', chain.root, 'Button 的 type 应为 ButtonType.Normal'); }
  // enabled：加载与禁用都要关（防连点）。
  const enabled = chain.calls.find((c) => c.name === 'enabled');
  if (enabled) { checkInactive('B1-enabled', enabled.args[0], struct, '.enabled(', true); }
  // onClick：只能挂在 Button 链上，回调里 onTap 前再判一次。
  const clicks = chain.calls.filter((c) => c.name === 'onClick');
  if (clicks.length !== 1) { report('B1-guard', stmts[0], 'Button 链上 .onClick 应恰好一处，实际 ' + clicks.length); }
  for (const click of clicks) {
    const taps = collect(click.node.arguments[0] || click.node, (n) => ts.isCallExpression(n) && compact(n.expression) === 'this.onTap');
    if (taps.length === 0) { report('B1-guard', click.node, 'onClick 里没有调用 this.onTap()'); }
    for (const tap of taps) {
      let guarded = false;
      for (let p = tap.parent; p && p !== click.node; p = p.parent) {
        if (ts.isIfStatement(p) && isInside(tap, p.thenStatement) && guardsInactive(p.expression, struct)) { guarded = true; }
      }
      if (!guarded) { report('B1-guard', tap, 'this.onTap() 前没有「加载 / 禁用」再判（加载防连点）'); }
    }
  }
  // 不得用 Row / Column 等容器 + onClick / 手势自画按钮。
  for (const call of collect(struct, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
    && ['onClick', 'onTouch', 'gesture', 'parallelGesture', 'priorityGesture'].includes(n.expression.name.text))) {
    if (!clicks.some((c) => c.node === call)) { report('B1-redraw', call, 'CouliButton 内 .' + call.expression.name.text + ' 不在系统 Button 链上（自画按钮）'); }
  }
  void names;
}
function isInside(node, container) { for (let p = node; p; p = p.parent) { if (p === container) { return true; } } return false; }
/** 条件里含「不在加载 / 禁用」：直接引用 this.loading（且 this.disabled），或调用的方法体同时引用两者。 */
function guardsInactive(cond, struct) {
  const text = compact(cond);
  const refs = (t) => t.includes('this.loading') && t.includes('this.disabled');
  if (refs(text)) { return true; }
  for (const call of collect(cond, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
    && n.expression.expression.kind === ts.SyntaxKind.ThisKeyword)) {
    const m = methodOf(struct, call.expression.name.text);
    if (m && m.body && refs(compact(m.body))) { return true; }
  }
  return false;
}
function checkInactive(rule, arg, struct, what) {
  if (!arg) { report(rule, null, what + ' 没有实参', BASICS); return; }
  const e = unwrap(arg);
  if (e.kind === ts.SyntaxKind.TrueKeyword) { report(rule, arg, what + ' 写死 true'); return; }
  if (!guardsInactive(arg, struct)) { report(rule, arg, what + ' 没同时看加载与禁用（loading / disabled）：' + arg.getText()); }
}

// ---------------------------------------------------------------- B2 页面不传 pressedPreview；注释改「目录专用」
function checkPressedPreview() {
  for (const rel of input.scan) {
    const sf = parse(rel);
    if (!sf) { continue; }
    for (const id of collect(sf, (n) => ts.isIdentifier(n) && n.text === 'pressedPreview')) {
      report('B2-page', id, '业务页传了目录专用参数 pressedPreview');
    }
  }
  for (const [rel, name] of [[BASICS, 'CouliButton'], [CONTROLS, 'CouliIconButton']]) {
    const sf = parse(rel);
    if (!sf) { continue; }
    const struct = findStruct(sf, name);
    const member = struct && struct.members.find((m) => ts.isPropertyDeclaration(m) && memberName(m) === 'pressedPreview');
    if (!member) { report('B2-doc', struct, name + ' 没有 pressedPreview 参数（名字参数不变）', rel); continue; }
    const text = sf.getFullText();
    const comments = (ts.getLeadingCommentRanges(text, member.getFullStart()) || []).map((r) => text.slice(r.pos, r.end)).join('\n');
    if (comments.indexOf('目录专用') < 0) { report('B2-doc', member, name + '.pressedPreview 的注释未写「目录专用」（书 §2.1 / §2.2）'); }
  }
}

// ---------------------------------------------------------------- B3 CouliButton 颜色只来自 CouliColors / Color.Transparent
const COLOR_RE = /^(?:#[0-9a-fA-F]{3,4}|#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?|rgba?\(.*\))$/;
const COLOR_SINKS = ['backgroundColor', 'color', 'fontColor', 'borderColor', 'selectedColor', 'shadow', 'linearGradient',
  'radialGradient', 'sweepGradient', 'foregroundColor'];
function allowedColor(e, struct, depth) {
  e = unwrap(e);
  const text = compact(e);
  if (/^CouliColors\.[A-Za-z0-9_]+$/.test(text) || text === 'Color.Transparent') { return true; }
  if (depth > 6) { return false; }
  if (ts.isConditionalExpression(e)) { return allowedColor(e.whenTrue, struct, depth + 1) && allowedColor(e.whenFalse, struct, depth + 1); }
  if (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression) && e.expression.expression.kind === ts.SyntaxKind.ThisKeyword
    && e.arguments.length === 0) {
    const m = methodOf(struct, e.expression.name.text);
    if (!m || !m.body) { return false; }
    const returns = collect(m.body, (n) => ts.isReturnStatement(n));
    return returns.length > 0 && returns.every((r) => r.expression && allowedColor(r.expression, struct, depth + 1));
  }
  return false;
}
function checkColors() {
  const sf = parse(BASICS);
  if (!sf) { return; }
  const struct = findStruct(sf, 'CouliButton');
  if (!struct) { return; }
  walk(struct, (n) => {
    if (isStr(n) && COLOR_RE.test(n.text.trim())) { report('B3-literal', n, '颜色字面量 ' + n.text); }
    if (n.kind === ts.SyntaxKind.NumericLiteral && /^0x/i.test(n.getText())) { report('B3-literal', n, '颜色数值 ' + n.getText()); }
    if (ts.isCallExpression(n) && compact(n.expression) === '$r') { report('B3-literal', n, '直接引用资源 ' + n.getText()); }
    if (ts.isIdentifier(n) && n.text === 'ColorMetrics') { report('B3-literal', n, 'ColorMetrics 自配颜色'); }
    if (ts.isPropertyAccessExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'Color' && n.name.text !== 'Transparent') {
      report('B3-literal', n, '命名色 ' + n.getText());
    }
    if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && COLOR_SINKS.includes(n.expression.name.text)) {
      const arg = n.arguments[0];
      if (!arg || !allowedColor(arg, struct, 0)) { report('B3-sink', n, '.' + n.expression.name.text + '( 的颜色不是 CouliColors / Color.Transparent：' + (arg ? arg.getText().slice(0, 60) : '')); }
    }
    if (ts.isPropertyAssignment(n) && memberName(n) === 'color') {
      if (!allowedColor(n.initializer, struct, 0)) { report('B3-sink', n, 'color: 不是 CouliColors / Color.Transparent：' + n.initializer.getText().slice(0, 60)); }
    }
    if (ts.isNewExpression(n) && compact(n.expression) === 'CouliTextModifier' && n.arguments && n.arguments[1]) {
      if (!allowedColor(n.arguments[1], struct, 0)) { report('B3-sink', n, 'CouliTextModifier 字色不是 CouliColors：' + n.arguments[1].getText().slice(0, 60)); }
    }
  });
}

// ---------------------------------------------------------------- B4 BuyButton 内是 CouliButton、label 走 stateLabel；按钮不加触感
function checkBuyButtonAndHaptics() {
  const sf = parse(PRICE);
  if (sf) {
    const struct = findStruct(sf, 'BuyButton');
    if (!struct) { report('B4-buy', null, 'Price.ets 找不到 struct BuyButton', PRICE); }
    else {
      const build = methodOf(struct, 'build');
      const comps = build ? collect(build, (n) => ts.isEtsComponentExpression(n) || (ts.isCallExpression(n) && ts.isIdentifier(n.expression))) : [];
      const names = comps.map((n) => n.expression.getText());
      if (names.indexOf('CouliButton') < 0) { report('B4-buy', build || struct, 'BuyButton.build 里没有 CouliButton'); }
      for (const bad of ['Button', 'Row', 'Column', 'Stack']) {
        if (names.indexOf(bad) >= 0) { report('B4-buy', build, 'BuyButton.build 里出现 ' + bad + '（应只包 CouliButton）'); }
      }
      const label = methodOf(struct, 'label');
      const calls = label ? collect(label, (n) => ts.isCallExpression(n) && compact(n.expression) === 'BuyButtonModel.stateLabel') : [];
      if (calls.length !== 1) { report('B4-label', label || struct, 'BuyButton.label() 应改调 BuyButtonModel.stateLabel（书 §2.4），实际 ' + calls.length + ' 处'); }
      const texts = build ? collect(build, (n) => ts.isPropertyAssignment(n) && memberName(n) === 'text') : [];
      if (texts.length !== 1 || compact(texts[0].initializer) !== 'this.label()') { report('B4-label', build, 'CouliButton 的 text 应为 this.label()'); }
    }
  }
  for (const rel of [PRICE, BASICS, CONTROLS]) {
    const f = parse(rel);
    if (!f) { continue; }
    const scope = rel === CONTROLS ? findStruct(f, 'CouliIconButton') : f;
    if (!scope) { continue; }
    walk(scope, (n) => {
      if (ts.isIdentifier(n) && ['CouliHaptics', 'HapticPlan', 'vibrator'].includes(n.text)) { report('B4-haptics', n, '按钮本身不加触感（README §3.2）：' + n.text); }
      if (ts.isImportDeclaration(n) && isStr(n.moduleSpecifier) && /SensorServiceKit|vibrator|CouliHaptics|HapticMoments/.test(n.moduleSpecifier.text)) {
        report('B4-haptics', n, '按钮文件引入触感模块 ' + n.moduleSpecifier.text);
      }
    });
  }
}

// ---------------------------------------------------------------- B5 下架 = DISABLED；ProductCard 透传 retryText
function checkOffShelf() {
  const sf = parse(MAPPER);
  if (sf) {
    const cls = findClass(sf, 'ProductCardMapper');
    const from = cls && methodOf(cls, 'fromCard');
    if (!from) { report('B5-mapper', null, 'ProductCardMapper.fromCard 找不到', MAPPER); }
    else {
      const ifs = collect(from, (n) => ts.isIfStatement(n) && /OFF_SHELF|'off_shelf'/.test(compact(n.expression)));
      if (ifs.length !== 1) { report('B5-mapper', from, '下架分支（条件含 OFF_SHELF）应恰好一处，实际 ' + ifs.length); }
      for (const branch of ifs) {
        if (!compact(branch.expression).includes('!d.priceUnavailable')) { report('B5-mapper', branch, '下架分支丢了「价格不可用优先」条件'); }
        const states = collect(branch.thenStatement, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken
          && compact(n.left) === 'd.buyState');
        if (states.length !== 1 || compact(states[0].right) !== 'BuyButtonState.DISABLED') {
          report('B5-mapper', branch, '下架分支应赋 d.buyState = BuyButtonState.DISABLED（D10-907），实际 ' + states.map((s) => s.right.getText()).join(' / '));
        }
        if (collect(branch.thenStatement, (n) => ts.isIdentifier(n) && n.text === 'RETRY_LATER').length > 0) { report('B5-mapper', branch, '下架分支里仍有 RETRY_LATER'); }
        const retry = collect(branch.thenStatement, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken
          && compact(n.left) === 'd.retryText');
        if (retry.length !== 1 || compact(retry[0].right) !== 'texts.text(ProductCardKeys.OFF_SHELF)') { report('B5-mapper', branch, '下架分支应赋 d.retryText = texts.text(ProductCardKeys.OFF_SHELF)'); }
        // 下架分支之后不得再改 buyState（例如平台状态盖过下架）。
        for (const later of collect(from, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken
          && compact(n.left) === 'd.buyState' && n.getStart() > branch.getEnd())) {
          report('B5-mapper', later, '下架分支之后又改了 d.buyState（下架文案应优先）');
        }
      }
    }
  }
  const card = parse(CARD);
  if (card) {
    const struct = findStruct(card, 'ProductCard');
    const buys = struct ? collect(struct, (n) => (ts.isEtsComponentExpression(n) || ts.isCallExpression(n)) && n.expression.getText() === 'BuyButton') : [];
    if (buys.length === 0) { report('B5-card', struct, 'ProductCard 里找不到 BuyButton(', CARD); }
    for (const b of buys) {
      const prop = property(b.arguments && b.arguments[0], 'retryText');
      if (!prop || compact(prop.initializer) !== 'this.data.retryText') {
        report('B5-card', prop || b, 'BuyButton 的 retryText 实参应是 this.data.retryText（去掉 BuyButtonModel.retryText 兜底），实际 ' + (prop ? prop.initializer.getText() : '缺'));
      }
    }
  }
}

// ---------------------------------------------------------------- B4-a11y / B5-hidden / B5-mask（测试 v3，评审 r1 S3-1）：组件层隐私接线
// 评审在真实树上做的 M1（spoken 非 NORMAL 读 this.base）、M2（accessibilityName: this.base）、M5（卡片把 CardAmountMask 遮罩后的
// 返利传给 BuyButton）、M6（卡片 amountHidden 写死 false）宿主 / 逻辑 / 设备三层都放过。BuyButtonModel 的 D10-871 回落靠
// namesAmount 拿「本卡金额」去比动词：传进来的返利若已遮罩（amountText「****」），已填好的「购买预估返 ¥2.69」就比不中，回落静默失效。
// ProductCard 自带的 this.rebate() 正是遮罩后的返利（给 RebateTag 用），所以 BuyButton 的 rebate 必须是未遮罩的 this.data.rebate。
const SPOKEN_CALL = 'BuyButtonModel.spoken(this.base,this.rebate,this.amountHidden,this.context)';
const STATE_LABEL_ARGS = 'this.state,this.base,this.retryText,this.rebate,this.amountHidden,this.context';

function enclosingOwner(node) {
  for (let p = node.parent; p; p = p.parent) {
    if (ts.isStructDeclaration(p) || ts.isClassDeclaration(p)) { return p; }
  }
  return null;
}
function enclosingFunction(node) {
  for (let p = node.parent; p; p = p.parent) {
    if (ts.isFunctionLike(p) && p.body) { return p; }
  }
  return null;
}
/** 本函数里名为 name 的局部变量初始化式（只认唯一的一处声明；参数、重复声明一律视为无法判定）。 */
function localInit(node, name) {
  const fn = enclosingFunction(node);
  if (!fn) { return null; }
  if (fn.parameters.some((p) => p.name.getText() === name)) { return null; }
  const decls = collect(fn.body, (n) => ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === name);
  return decls.length === 1 && decls[0].initializer ? decls[0].initializer : null;
}
/** expr 是否「就是」want（如 this.data.rebate）：原样；或同 struct 无参方法 this.m() 且其每个 return 都是 want；或唯一局部常量其初值是 want。 */
function resolvesTo(expr, want, owner, depth) {
  const e = unwrap(expr);
  if (!e || depth > 6) { return false; }
  if (compact(e) === want) { return true; }
  if (ts.isIdentifier(e)) {
    const init = localInit(e, e.text);
    return init ? resolvesTo(init, want, owner, depth + 1) : false;
  }
  if (owner && ts.isCallExpression(e) && e.arguments.length === 0 && ts.isPropertyAccessExpression(e.expression)
    && e.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
    const m = methodOf(owner, e.expression.name.text);
    if (!m || !m.body || m.parameters.length > 0) { return false; }
    const returns = collect(m.body, (n) => ts.isReturnStatement(n));
    return returns.length > 0 && returns.every((r) => r.expression && resolvesTo(r.expression, want, owner, depth + 1));
  }
  return false;
}
/** expr 是否经由 CardAmountMask 遮罩（直接出现；或经 this.m() / 局部变量间接得到）。 */
function maskedRebate(expr, owner, depth) {
  const e = unwrap(expr);
  if (!e || depth > 6) { return false; }
  if (collect(e, (n) => ts.isIdentifier(n) && n.text === 'CardAmountMask').length > 0) { return true; }
  for (const id of collect(e, (n) => ts.isIdentifier(n) && !(ts.isPropertyAccessExpression(n.parent) && n.parent.name === n))) {
    const init = localInit(id, id.text);
    if (init && maskedRebate(init, owner, depth + 1)) { return true; }
  }
  for (const call of collect(e, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
    && n.expression.expression.kind === ts.SyntaxKind.ThisKeyword)) {
    const m = owner ? methodOf(owner, call.expression.name.text) : null;
    if (m && m.body && collect(m.body, (n) => ts.isReturnStatement(n)).some((r) => r.expression && maskedRebate(r.expression, owner, depth + 1))) {
      return true;
    }
  }
  return false;
}
function buyButtonCalls(scope) {
  return collect(scope, (n) => (ts.isEtsComponentExpression(n) || ts.isCallExpression(n)) && n.expression.getText() === 'BuyButton'
    && n.arguments && n.arguments.length > 0 && ts.isObjectLiteralExpression(n.arguments[0]));
}

function checkHiddenWiring() {
  // B4-a11y：BuyButton 读屏名称不绕开 BuyButtonModel（M1 / M2）。
  const sf = parse(PRICE);
  const struct = sf ? findStruct(sf, 'BuyButton') : null;
  if (struct) {
    const label = methodOf(struct, 'label');
    for (const call of label ? collect(label, (n) => ts.isCallExpression(n) && compact(n.expression) === 'BuyButtonModel.stateLabel') : []) {
      const args = call.arguments.map((a) => compact(a)).join(',');
      if (args !== STATE_LABEL_ARGS) {
        report('B4-hidden', call, 'BuyButton.label() 调 stateLabel 的实参应原样透传 (' + STATE_LABEL_ARGS + ')，实际 (' + args + ')（金额隐藏不得写死 / 换源）');
      }
    }
    const spoken = methodOf(struct, 'spoken');
    if (!spoken || !spoken.body) { report('B4-a11y', struct, 'BuyButton 缺 spoken()（读屏名称，书 §2.4）'); }
    else {
      const returns = collect(spoken.body, (n) => ts.isReturnStatement(n));
      let toLabel = 0;
      let toModel = 0;
      for (const r of returns) {
        const t = r.expression ? compact(r.expression) : '';
        if (t === 'this.label()') { toLabel++; }
        else if (t === SPOKEN_CALL) { toModel++; }
        else {
          report('B4-a11y', r, 'BuyButton.spoken() 只能返回 this.label()（非 NORMAL，与可见文字同一回落）或 ' + SPOKEN_CALL
            + '（NORMAL），实际 return ' + (r.expression ? r.expression.getText().slice(0, 80) : '（空）') + '（评审 r1 M1：读屏读 base 会露金额）');
        }
      }
      if (toLabel === 0) { report('B4-a11y', spoken, 'BuyButton.spoken() 非 NORMAL 状态应返回 this.label()'); }
      if (toModel === 0) { report('B4-a11y', spoken, 'BuyButton.spoken() NORMAL 状态应返回 ' + SPOKEN_CALL); }
      const leaks = collect(spoken.body, (n) => ts.isCallExpression(n) && compact(n.expression) === 'BuyButtonModel.spoken'
        && compact(n) !== SPOKEN_CALL);
      for (const l of leaks) { report('B4-a11y', l, 'BuyButtonModel.spoken 实参应原样透传：' + l.getText().slice(0, 80)); }
    }
    const build = methodOf(struct, 'build');
    if (build) {
      const names = collect(build, (n) => ts.isPropertyAssignment(n) && memberName(n) === 'accessibilityName');
      if (names.length !== 1 || compact(names[0].initializer) !== 'this.spoken()') {
        report('B4-a11y', names[0] || build, 'BuyButton 传给 CouliButton 的 accessibilityName 应为 this.spoken()，实际 '
          + (names.length ? names.map((n) => n.initializer.getText()).join(' / ') : '缺') + '（评审 r1 M2）');
      }
      for (const c of collect(build, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
        && ['accessibilityText', 'accessibilityDescription'].includes(n.expression.name.text))) {
        report('B4-a11y', c, 'BuyButton.build 另挂 .' + c.expression.name.text + '(，会盖过 / 追加读屏名称（金额隐藏走不到回落）');
      }
    }
  }
  // B5-hidden：ProductCard 传给 BuyButton 的是未遮罩返利与真实开关（M5 / M6）。
  const card = parse(CARD);
  const cardStruct = card ? findStruct(card, 'ProductCard') : null;
  if (cardStruct) {
    for (const b of buyButtonCalls(cardStruct)) {
      const opts = b.arguments[0];
      const rebate = property(opts, 'rebate');
      if (!rebate || !resolvesTo(rebate.initializer, 'this.data.rebate', cardStruct, 0)) {
        const why = rebate && maskedRebate(rebate.initializer, cardStruct, 0)
          ? '（这是 CardAmountMask 遮罩后的返利，卡内 this.rebate() 就是它：namesAmount 比的是「****」，金额隐藏回落静默失效，评审 r1 M5）' : '';
        report('B5-hidden', rebate || b, 'ProductCard 传给 BuyButton 的 rebate 应是未遮罩的 this.data.rebate，实际 '
          + (rebate ? rebate.initializer.getText() : '缺') + why);
      }
      const hidden = property(opts, 'amountHidden');
      if (!hidden || !resolvesTo(hidden.initializer, 'this.data.amountHidden', cardStruct, 0)) {
        report('B5-hidden', hidden || b, 'ProductCard 传给 BuyButton 的 amountHidden 应是 this.data.amountHidden，实际 '
          + (hidden ? hidden.initializer.getText() : '缺') + '（评审 r1 M6）');
      }
    }
  }
  // B5-mask：产品代码（features/*/src/main、entry/src/main、common/*/src/main）任何 BuyButton 调用点都不得传遮罩后的返利。
  for (const rel of input.buyScan || []) {
    const f = parse(rel);
    if (!f) { continue; }
    for (const b of buyButtonCalls(f)) {
      const rebate = property(b.arguments[0], 'rebate');
      if (rebate && maskedRebate(rebate.initializer, enclosingOwner(b), 0)) {
        report('B5-mask', rebate, 'BuyButton 的 rebate 经 CardAmountMask 遮罩（' + rebate.initializer.getText().slice(0, 80)
          + '）：金额隐藏回落要拿未遮罩的本卡金额去比动词（D10-871 / D10-1177 ②）');
      }
    }
  }
}

// ---------------------------------------------------------------- B6 D10-871 回落走契约字典 btn.buy，不用 PriceTerms.buy
function checkFallback() {
  const sf = parse(MODELS);
  if (!sf) { return; }
  const cls = findClass(sf, 'BuyButtonModel');
  if (!cls) { report('B6-dict', null, 'PriceModels.ets 找不到 class BuyButtonModel', MODELS); return; }
  const fallbacks = collect(cls, (n) => {
    if (!ts.isCallExpression(n) || compact(n.expression) !== 'contractText' || n.arguments.length !== 1) { return false; }
    const a = unwrap(n.arguments[0]);
    const v = isStr(a) ? a.text : (ts.isIdentifier(a) ? moduleConstString(sf, a.text) : null);
    return v === 'btn.buy';
  });
  if (fallbacks.length === 0) { report('B6-dict', cls, 'BuyButtonModel 里没有 contractText(\'btn.buy\')（D10-871 回落走契约字典）'); }
  for (const n of collect(cls, (x) => ts.isPropertyAccessExpression(x) && compact(x) === 'PriceTerms.buy')) {
    report('B6-priceterms', n, 'BuyButtonModel 引用了 PriceTerms.buy（「去购买」，回落应取字典 btn.buy「购买」）');
  }
  const methods = new Map();
  for (const m of cls.members) { if (ts.isMethodDeclaration(m) && m.body) { methods.set(memberName(m), m); } }
  const holders = new Set();
  for (const call of fallbacks) {
    let m = call.parent;
    while (m && !ts.isMethodDeclaration(m)) { m = m.parent; }
    if (!m) { continue; }
    holders.add(memberName(m));
    const uses = collect(m.body, (n) => ts.isIdentifier(n) && n.text === 'amountHidden');
    if (uses.length === 0) { report('B6-gate', m, '回落所在方法 ' + memberName(m) + ' 不看 amountHidden（恒开或恒关）'); }
  }
  /** 方法 name 经 BuyButtonModel.x( / this.x( 调用能否到达回落所在方法。 */
  function reaches(name, seen) {
    if (holders.has(name)) { return true; }
    if (seen.has(name) || !methods.has(name)) { return false; }
    seen.add(name);
    return collect(methods.get(name).body, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
      && ['BuyButtonModel', 'this'].includes(n.expression.expression.getText()))
      .some((c) => reaches(c.expression.name.text, seen));
  }
  for (const entry of ['text', 'spoken', 'stateLabel']) {
    if (!methods.has(entry)) { report('B6-entry', cls, 'BuyButtonModel 没有 ' + entry + '（书 §2.3）'); continue; }
    if (holders.size > 0 && !reaches(entry, new Set())) { report('B6-entry', methods.get(entry), 'BuyButtonModel.' + entry + ' 没走 D10-871 回落'); }
  }
}

// ---------------------------------------------------------------- B8 逻辑套件已登记；B9 目录下架态与点按计数
function checkRegistration() {
  const sf = parse(DS_LIST);
  if (!sf) { return; }
  const imp = sf.statements.filter((s) => ts.isImportDeclaration(s) && isStr(s.moduleSpecifier) && s.moduleSpecifier.text === './L2Button.test'
    && s.importClause && s.importClause.name && s.importClause.name.text === 'l2ButtonTest');
  if (imp.length !== 1) { report('B8-register', null, 'designsystem List.test.ets 应 import l2ButtonTest from \'./L2Button.test\' 恰好一次', DS_LIST); }
  const suite = sf.statements.find((s) => ts.isFunctionDeclaration(s) && s.body);
  const direct = suite ? suite.body.statements.filter((s) => ts.isExpressionStatement(s) && compact(s.expression) === 'l2ButtonTest()') : [];
  const all = collect(sf, (n) => ts.isCallExpression(n) && compact(n.expression) === 'l2ButtonTest');
  if (direct.length !== 1 || all.length !== 1) { report('B8-register', suite, 'testsuite 里应直接调用 l2ButtonTest(); 恰好一次（实际直接 ' + direct.length + ' / 全部 ' + all.length + '）', DS_LIST); }
}
function checkCatalog() {
  const sf = parse(CATALOG);
  if (sf) {
    const buy = collect(sf, (n) => ts.isCallExpression(n) && compact(n.expression) === 'c' && n.arguments[0] && isStr(n.arguments[0])
      && n.arguments[0].text === 'BuyButton');
    let found = false;
    for (const call of buy) {
      for (const m of collect(call, (n) => ts.isCallExpression(n) && compact(n.expression) === 'm' && n.arguments.length === 2)) {
        const lits = (a) => ts.isArrayLiteralExpression(a) ? a.elements.filter(isStr).map((e) => e.text) : [];
        if (lits(m.arguments[0]).includes('single') && lits(m.arguments[1]).includes('off-shelf')) { found = true; }
      }
    }
    if (buy.length !== 1 || !found) { report('B9-catalog', buy[0] || null, '目录 BuyButton 缺 single × off-shelf 一行（书 §2.5 / README ⑨）', CATALOG); }
  }
  const detail = parse(DETAIL);
  if (detail) {
    for (const want of ['catalog-events/CouliButton', 'catalog-events/BuyButton']) {
      const ids = collect(detail, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === 'id'
        && collect(n, (x) => isStr(x) && x.text === want).length > 0);
      if (ids.length !== 1) { report('B9-events', null, '目录详情缺点按计数 .id(\'' + want + '\')（Ds02L2Ui 连点 0 回调用）', DETAIL); }
    }
  }
}

for (const rel of [BASICS, CONTROLS, PRICE, CARD, MODELS, MAPPER, DS_LIST, CATALOG, DETAIL]) { parse(rel); }
for (const rel of input.scan) { parse(rel); }
for (const rel of input.buyScan || []) { parse(rel); }
if (incomplete.length === 0) {
  checkCouliButton();
  checkPressedPreview();
  checkColors();
  checkBuyButtonAndHaptics();
  checkOffShelf();
  checkHiddenWiring();
  checkFallback();
  checkRegistration();
  checkCatalog();
}
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete }));
