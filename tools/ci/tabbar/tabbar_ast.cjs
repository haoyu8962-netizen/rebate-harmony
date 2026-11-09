#!/usr/bin/env node
// FU-HM-TAB-BAR 宿主守卫的解析部分（书 §3.1；由 check_tab_bar.py 调用，不单独跑）。用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS，
// 判定全部走 AST（struct / 组件尾随闭包 / 装饰器 / 属性链），不用正则切块，注释与字符串里的字不算。
//   用法：node tabbar_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>"}, "scan": ["<相对路径>", ...]}（files 含必查文件和 scan 列出的全仓候选文件）
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."]}
// 规则编号对应书 §3.1 的 1–7：T1 系统样式与符号表、T2 TabBar 内禁用项、T3 选中色、T4 TabBarItem 与全仓残留、T5 外壳材质、T6 无本地选中态、T7 目录。
// 测试 v3 收紧：T1-source（图标来自符号表函数，按项 icon 分支，防四项同一图标）、T5-background（底栏外层、TabBar、Tabs 上任何底色）、T8-register（套件注册）。
'use strict';
const fs = require('fs');
const path = require('path');

const NAV = 'common/designsystem/src/main/ets/components/Navigation.ets';
const SHELL = 'entry/src/main/ets/shell/AppShell.ets';
const CATALOG = 'entry/src/staging/ets/catalog/CatalogManifest.ets';
const LIST = 'entry/src/ohosTest/ets/test/List.test.ets';

const tsDir = process.argv[2];
if (!tsDir) { console.error('tabbar_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('tabbar_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('tabbar_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
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

function lineOf(node) {
  return node.getSourceFile().getLineAndCharacterOfPosition(node.getStart()).line + 1;
}
function report(rule, node, msg, file) {
  violations.push({ rule: rule, file: file || (node ? node.getSourceFile().fileName : ''), line: node ? lineOf(node) : 0, msg: msg });
}
function walk(node, visit) {
  visit(node);
  ts.forEachChild(node, (c) => walk(c, visit));
}
function collect(node, pred) {
  const out = [];
  walk(node, (n) => { if (pred(n)) { out.push(n); } });
  return out;
}
function compact(node) {
  return node.getText().replace(/\s+/g, '');
}
function unwrap(e) {
  while (e && (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isNonNullExpression(e))) { e = e.expression; }
  return e;
}
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
function decoratorsOf(node) {
  const list = ts.getAllDecorators ? ts.getAllDecorators(node) : (node.decorators || []);
  return Array.from(list || []).map((d) => {
    const x = ts.isCallExpression(d.expression) ? d.expression.expression : d.expression;
    return x.getText();
  });
}
function findStruct(sf, name) {
  let hit = null;
  ts.forEachChild(sf, (n) => { if (ts.isStructDeclaration(n) && n.name && n.name.text === name) { hit = n; } });
  return hit;
}
function memberName(m) {
  return m.name && (ts.isIdentifier(m.name) || ts.isStringLiteral(m.name)) ? m.name.text : '';
}
function methodOf(struct, name) {
  return struct.members.find((m) => ts.isMethodDeclaration(m) && memberName(m) === name) || null;
}
function propName(p) {
  return p.name && (ts.isIdentifier(p.name) || ts.isStringLiteral(p.name)) ? p.name.text : '';
}
/** 方法体里的 const / let 初始值（不进嵌套函数）。 */
function localsOf(method) {
  const locals = new Map();
  function go(n) {
    if (ts.isFunctionLike(n) && n !== method) { return; }
    if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.initializer) { locals.set(n.name.text, n.initializer); }
    ts.forEachChild(n, go);
  }
  go(method);
  return locals;
}
function returnsOf(method) {
  const out = [];
  function go(n) {
    if (ts.isFunctionLike(n) && n !== method) { return; }
    if (ts.isReturnStatement(n)) { out.push(n); }
    ts.forEachChild(n, go);
  }
  go(method);
  return out;
}
function resolve(expr, locals) {
  let e = unwrap(expr);
  const seen = new Set();
  while (e && ts.isIdentifier(e) && locals.has(e.text) && !seen.has(e.text)) {
    seen.add(e.text);
    e = unwrap(locals.get(e.text));
  }
  return e;
}
/** 对象字面量的属性值（含简写）；没有为 undefined。 */
function objProp(obj, name) {
  for (const p of obj.properties) {
    if (propName(p) !== name) { continue; }
    if (ts.isPropertyAssignment(p)) { return p.initializer; }
    if (ts.isShorthandPropertyAssignment(p)) { return p.name; }
  }
  return undefined;
}

// ---------------------------------------------------------------- T1 / T2 / T3 / T6（Navigation.ets 的 struct TabBar）

const SYMBOL_MAP = {
  home: ['house', 'house_fill'], chat: ['ellipsis_message', 'ellipsis_message_fill'], orders: ['doc_plaintext', 'doc_plaintext_fill'],
  user: ['person', 'person_fill'], search: ['magnifyingglass', null]
};
const FORBIDDEN = ['Builder', 'CouliIcon', 'Badge', 'badgeIndex', 'animationDuration', 'divider', 'barBackgroundColor',
  'barBackgroundBlurStyle', 'accessibilityDescription', 'accessibilitySelected', 'accessibilityGroup'];

/** T1-source：new SymbolGlyphModifier 的实参必须是「符号表函数(项.icon)」结果的 .normal / .selected。返回 { fn } 或 { err }。 */
function symbolSource(ctor, key, method, locals) {
  const args = Array.from(ctor.arguments || []);
  const param = method.parameters.length === 1 && ts.isIdentifier(method.parameters[0].name) ? method.parameters[0].name.text : null;
  if (args.length !== 1 || param === null) { return { err: 'new SymbolGlyphModifier 须恰好一个实参，方法须恰好一个项参数' }; }
  const a = resolve(args[0], locals);
  if (!ts.isPropertyAccessExpression(a) || a.name.text !== key) { return { err: key + ' 的符号必须取自符号表结果的 .' + key + '，实际：' + compact(a).slice(0, 60) }; }
  const call = resolve(a.expression, locals);
  if (!ts.isCallExpression(call) || !ts.isIdentifier(call.expression) || call.arguments.length !== 1 || compact(call.arguments[0]) !== param + '.icon') {
    return { err: '符号必须来自 <符号表函数>(' + param + '.icon)（否则四项可以同一图标），实际：' + compact(call).slice(0, 60) };
  }
  return { fn: call.expression.text };
}

/** 符号表函数必须是模块级函数，函数体只有一个 switch，且按第一个形参分支。返回函数节点或 null（已报 T1-source）。 */
function mapperOf(sf, name, at) {
  let fn = null;
  ts.forEachChild(sf, (n) => { if (ts.isFunctionDeclaration(n) && n.name && n.name.text === name) { fn = n; } });
  if (fn === null || !fn.body) { report('T1-source', at, '符号表函数 ' + name + ' 不是本文件的模块级函数'); return null; }
  const sw = fn.body.statements.length === 1 ? fn.body.statements[0] : null;
  const first = fn.parameters.length > 0 && ts.isIdentifier(fn.parameters[0].name) ? fn.parameters[0].name.text : null;
  if (sw === null || !ts.isSwitchStatement(sw) || !ts.isIdentifier(unwrap(sw.expression)) || unwrap(sw.expression).text !== first) {
    report('T1-source', fn, '符号表函数 ' + name + ' 的函数体必须只有一个按形参分支的 switch');
    return null;
  }
  return fn;
}

function checkStyle(style, method, locals, mappers) {
  // style = { root: NewExpression | BottomTabBarStyle.of 的 call, args, calls }
  const icon = style.args.length > 0 ? resolve(style.args[0], locals) : undefined;
  if (!icon || !ts.isObjectLiteralExpression(icon)) {
    report('T1-symbol', style.root, 'BottomTabBarStyle 第一个实参不是 { normal, selected } 对象字面量（TabBarSymbol）：' +
      (icon ? compact(icon).slice(0, 60) : '缺失'));
  } else {
    for (const key of ['normal', 'selected']) {
      const raw = objProp(icon, key);
      if (raw === undefined) { report('T1-symbol', icon, '图标实参缺 ' + key); continue; }
      const value = resolve(raw, locals);
      const chain = chainOf(value);
      if (!ts.isNewExpression(chain.root) || chain.root.expression.getText() !== 'SymbolGlyphModifier') {
        report('T1-symbol', value, key + ' 不是 new SymbolGlyphModifier(...)：' + compact(value).slice(0, 60));
        continue;
      }
      const src = symbolSource(chain.root, key, method, locals);
      if (src.err) { report('T1-source', value, src.err); } else { mappers.add(src.fn); }
      const expect = key === 'normal' ? 'CouliColors.textSecondary' : 'CouliColors.brandPrimary';
      const colors = chain.calls.filter((c) => c.name === 'fontColor');
      const ok = colors.length === 1 && colors[0].args.length === 1 && ts.isArrayLiteralExpression(colors[0].args[0]) &&
        colors[0].args[0].elements.length === 1 && compact(colors[0].args[0].elements[0]) === expect;
      if (!ok) {
        report('T3-fontcolor', value, key + ' 的图标色必须是 .fontColor([' + expect + '])：' + compact(value).slice(0, 90));
      }
    }
  }
  const label = style.calls.filter((c) => c.name === 'labelStyle');
  if (label.length !== 1 || label[0].args.length !== 1 || !ts.isObjectLiteralExpression(unwrap(label[0].args[0]))) {
    report('T3-label', style.root, 'BottomTabBarStyle 必须恰好调用一次 labelStyle({ selectedColor, unselectedColor })');
    return;
  }
  const obj = unwrap(label[0].args[0]);
  const keys = obj.properties.map(propName).sort().join(',');
  const sel = objProp(obj, 'selectedColor');
  const unsel = objProp(obj, 'unselectedColor');
  if (keys !== 'selectedColor,unselectedColor') {
    report('T3-label', obj, 'labelStyle 只能有 selectedColor / unselectedColor（不传 font、字重，D10-909 ④），实际：' + keys);
  }
  if (!sel || compact(sel) !== 'CouliColors.textLink') {
    report('T3-label', obj, 'labelStyle.selectedColor 必须是 CouliColors.textLink');
  }
  if (!unsel || compact(unsel) !== 'CouliColors.textSecondary') {
    report('T3-label', obj, 'labelStyle.unselectedColor 必须是 CouliColors.textSecondary');
  }
}

function checkTabBar() {
  const sf = parse(NAV);
  if (sf === null) { return; }
  const struct = findStruct(sf, 'TabBar');
  if (struct === null) { report('T1-locate', null, 'Navigation.ets 里没有 struct TabBar', NAV); return; }
  const build = methodOf(struct, 'build');
  if (build === null) { report('T1-locate', struct, 'struct TabBar 没有 build()'); return; }

  // T1：每个 .tabBar( 实参来自返回 BottomTabBarStyle 的方法（不是 @Builder）
  const tabBarCalls = collect(build, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
    n.expression.name.text === 'tabBar');
  if (tabBarCalls.length === 0) { report('T1-bar-method', build, 'build() 里没有 TabContent().tabBar(...)'); }
  let styled = 0;
  const mappers = new Set();
  for (const call of tabBarCalls) {
    const arg = call.arguments.length === 1 ? unwrap(call.arguments[0]) : null;
    const isThisCall = arg && ts.isCallExpression(arg) && ts.isPropertyAccessExpression(arg.expression) &&
      arg.expression.expression.kind === ts.SyntaxKind.ThisKeyword;
    if (!isThisCall) { report('T1-bar-method', call, '.tabBar 实参必须是 this.<方法>(...)，实际：' + (arg ? compact(arg).slice(0, 60) : '无')); continue; }
    const name = arg.expression.name.text;
    const method = methodOf(struct, name);
    if (method === null) { report('T1-bar-method', call, '.tabBar 调的 this.' + name + ' 不是 struct 里的方法'); continue; }
    // ForEach 的项参数原样传入（this.bar(this.items[0]) 会让四项同一图标同一文字）。
    let owner = call.parent;
    while (owner && !ts.isFunctionLike(owner)) { owner = owner.parent; }
    const itemParam = owner && owner.parameters.length > 0 && ts.isIdentifier(owner.parameters[0].name) ? owner.parameters[0].name.text : null;
    if (arg.arguments.length !== 1 || !ts.isIdentifier(unwrap(arg.arguments[0])) || unwrap(arg.arguments[0]).text !== itemParam) {
      report('T1-source', call, '.tabBar 必须把 ForEach 的项参数原样传给 this.' + name + '，实际：' + compact(arg).slice(0, 60));
    }
    if (decoratorsOf(method).includes('Builder')) { report('T1-bar-method', method, 'this.' + name + ' 仍是 @Builder 自绘 tabBar'); continue; }
    if (!method.type || method.type.getText() !== 'BottomTabBarStyle') {
      report('T1-bar-method', method, 'this.' + name + ' 的返回类型必须写成 BottomTabBarStyle');
      continue;
    }
    const locals = localsOf(method);
    const rets = returnsOf(method);
    if (rets.length === 0) { report('T1-style', method, 'this.' + name + ' 没有 return'); continue; }
    for (const ret of rets) {
      if (!ret.expression) { report('T1-style', ret, 'return 没有返回值'); continue; }
      const chain = chainOf(resolve(ret.expression, locals));
      let args = null;
      let calls = chain.calls;
      if (ts.isNewExpression(chain.root) && chain.root.expression.getText() === 'BottomTabBarStyle') {
        args = Array.from(chain.root.arguments || []);
      } else if (ts.isIdentifier(chain.root) && chain.root.text === 'BottomTabBarStyle' && calls.length > 0 && calls[0].name === 'of') {
        args = calls[0].args;
        calls = calls.slice(1);
      }
      if (args === null) { report('T1-style', ret, 'this.' + name + ' 返回的不是 new BottomTabBarStyle(...) / BottomTabBarStyle.of(...)：' + compact(ret.expression).slice(0, 70)); continue; }
      styled++;
      checkStyle({ root: chain.root, args: args, calls: calls }, method, locals, mappers);
    }
  }
  if (styled === 0) {
    // 现状（@Builder）走不到选中色判定：T3 同样要红，不能因 T1 红就漏报。
    report('T3-label', struct, '没有可判定的 BottomTabBarStyle：labelStyle 未设置');
    report('T3-fontcolor', struct, '没有可判定的 BottomTabBarStyle：图标 fontColor 未设置');
  }

  // T1：符号表（$r 字面量）。认得出符号表函数时只看它自己的 switch（文件里别处的诱饵 switch 不算）；认不出时（已报 T1-source 或现状自绘）退回全文件。
  const mapperNodes = Array.from(mappers).map((name) => mapperOf(sf, name, struct)).filter((fn) => fn !== null);
  const clauses = new Map();
  for (const sw of [].concat(...(mapperNodes.length > 0 ? mapperNodes : [sf]).map((scope) => collect(scope, (n) => ts.isSwitchStatement(n))))) {
    for (const clause of sw.caseBlock.clauses) {
      if (!ts.isCaseClause(clause) || !ts.isStringLiteralLike(clause.expression)) { continue; }
      const syms = collect(clause, (n) => ts.isCallExpression(n) && n.expression.getText() === '$r' && n.arguments.length === 1 &&
        ts.isStringLiteralLike(n.arguments[0])).map((n) => n.arguments[0].text);
      const key = clause.expression.text;
      if (!clauses.has(key)) { clauses.set(key, []); }
      clauses.get(key).push(syms);
    }
  }
  for (const [icon, pair] of Object.entries(SYMBOL_MAP)) {
    const lists = clauses.get(icon) || [];
    const all = [].concat(...lists);
    const normal = 'sys.symbol.' + pair[0];
    if (!all.includes(normal)) { report('T1-map', struct, 'icon「' + icon + '」的 switch 分支没有 ' + normal, NAV); continue; }
    if (pair[1] === null) {
      if (all.some((s) => s.endsWith('_fill'))) { report('T1-map', struct, 'icon「' + icon + '」没有实心变体，不该出现 _fill：' + all.join(','), NAV); }
      continue;
    }
    const fill = 'sys.symbol.' + pair[1];
    if (!all.includes(fill)) { report('T1-map', struct, 'icon「' + icon + '」的选中项必须用 ' + fill + '（实心）', NAV); continue; }
    for (const syms of lists) {
      if (syms.includes(normal) && syms.includes(fill) && syms.indexOf(normal) > syms.indexOf(fill)) {
        report('T1-map', struct, 'icon「' + icon + '」normal / selected 写反：' + syms.join(','), NAV);
      }
    }
  }

  // T2：TabBar 内禁用项
  const seen = new Set();
  walk(struct, (n) => {
    if (ts.isIdentifier(n) && FORBIDDEN.includes(n.text) && !seen.has(n.text)) {
      seen.add(n.text);
      report('T2-forbidden', n, 'TabBar 内不许出现 ' + n.text);
    }
    if ((ts.isPropertyAssignment(n) || ts.isShorthandPropertyAssignment(n)) && propName(n) === 'font') {
      report('T2-forbidden', n, 'TabBar 内不许出现 font:（标签用系统默认字号，D10-909 ④）');
    }
  });

  // T6：无本地选中态
  for (const m of struct.members) {
    if (!ts.isPropertyDeclaration(m)) { continue; }
    const decos = decoratorsOf(m);
    for (const bad of ['Local', 'Trace', 'Provider', 'Consumer']) {
      if (decos.includes(bad)) { report('T6-local-state', m, 'TabBar 不许声明 @' + bad + ' 状态（选中只跟宿主）：' + memberName(m)); }
    }
    if (memberName(m) === 'selectedIndex' && (!decos.includes('Param') || decos.includes('Once'))) {
      report('T6-local-state', m, 'selectedIndex 必须是 @Param 且不带 @Once（@Once 等于本地选中态）');
    }
  }
  if (!struct.members.some((m) => ts.isPropertyDeclaration(m) && memberName(m) === 'selectedIndex')) {
    report('T6-local-state', struct, 'TabBar 缺 @Param selectedIndex');
  }
  const isSelectedRef = (e) => ts.isPropertyAccessExpression(e) && e.name.text === 'selectedIndex' && e.expression.kind === ts.SyntaxKind.ThisKeyword;
  const ASSIGN = new Set([ts.SyntaxKind.EqualsToken, ts.SyntaxKind.PlusEqualsToken, ts.SyntaxKind.MinusEqualsToken, ts.SyntaxKind.AsteriskEqualsToken,
    ts.SyntaxKind.SlashEqualsToken, ts.SyntaxKind.PercentEqualsToken, ts.SyntaxKind.QuestionQuestionEqualsToken, ts.SyntaxKind.BarBarEqualsToken,
    ts.SyntaxKind.AmpersandAmpersandEqualsToken]);
  walk(struct, (n) => {
    const write = (ts.isBinaryExpression(n) && ASSIGN.has(n.operatorToken.kind) && isSelectedRef(unwrap(n.left))) ||
      ((ts.isPrefixUnaryExpression(n) || ts.isPostfixUnaryExpression(n)) &&
        (n.operator === ts.SyntaxKind.PlusPlusToken || n.operator === ts.SyntaxKind.MinusMinusToken) && isSelectedRef(unwrap(n.operand)));
    if (write) { report('T6-write', n, 'TabBar 不许写 selectedIndex：' + compact(n).slice(0, 60)); }
  });
}

// ---------------------------------------------------------------- T4

function checkTabBarItem() {
  const sf = parse(NAV);
  if (sf === null) { return; }
  let cls = null;
  ts.forEachChild(sf, (n) => { if (ts.isClassDeclaration(n) && n.name && n.name.text === 'TabBarItem') { cls = n; } });
  if (cls === null) { report('T4-ctor', null, 'Navigation.ets 里没有 class TabBarItem', NAV); return; }
  const ctor = cls.members.find((m) => ts.isConstructorDeclaration(m));
  const params = ctor ? ctor.parameters.map((p) => p.name.getText()) : [];
  if (params.join(',') !== 'label,icon') { report('T4-ctor', ctor || cls, 'TabBarItem 构造只能有 label, icon，实际：' + params.join(', ')); }
  if (cls.members.some((m) => memberName(m) === 'accessibilityHint')) { report('T4-ctor', cls, 'TabBarItem 不许留 accessibilityHint 字段'); }
}

function checkResidue() {
  for (const rel of input.scan || []) {
    const sf = parse(rel);
    if (sf === null) { continue; }
    walk(sf, (n) => {
      if (ts.isIdentifier(n) && (n.text === 'tabPosition' || n.text === 'badgeIndex')) { report('T4-residue', n, '全仓不许再有 ' + n.text); }
    });
  }
}

// ---------------------------------------------------------------- T5

function isNamedCall(n, name) {
  return (ts.isCallExpression(n) || ts.isEtsComponentExpression(n)) && n.expression && n.expression.getText() === name;
}
/** 组件节点上的修饰链：从组件表达式往外爬。 */
function modifiersOf(component) {
  const calls = [];
  let cur = component;
  for (;;) {
    const p = cur.parent;
    if (p && ts.isPropertyAccessExpression(p) && p.expression === cur && p.parent && ts.isCallExpression(p.parent) && p.parent.expression === p) {
      calls.push({ name: p.name.text, args: Array.from(p.parent.arguments), node: p.parent });
      cur = p.parent;
      continue;
    }
    return calls;
  }
}
function countMaterial(struct) {
  return collect(struct, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
    n.expression.name.text === 'backgroundBlurStyle').length;
}

// 测试 v3（评审 S3-2）：这些修饰器都会把材质盖住；书 §3.1-5 只禁 surface，这里按评审加严。
const OPAQUE_BACKGROUND = ['backgroundColor', 'background', 'backgroundImage', 'linearGradient', 'sweepGradient', 'radialGradient'];

function reportOpaque(mods, where) {
  for (const m of mods) {
    if (OPAQUE_BACKGROUND.includes(m.name)) {
      report('T5-background', m.node, where + ' 不许有 ' + m.name + '（底色由外层 Column 的系统材质负责）：' + compact(m.node).slice(0, 70));
    }
  }
}

function checkShell() {
  const sf = parse(SHELL);
  if (sf === null) { return; }
  const shell = findStruct(sf, 'AppShell');
  const build = shell ? methodOf(shell, 'build') : null;
  if (build === null) { report('T5-locate', null, 'AppShell.ets 里找不到 struct AppShell 的 build()', SHELL); return; }
  const tabBars = collect(build, (n) => isNamedCall(n, 'TabBar'));
  if (tabBars.length !== 1) { report('T5-locate', build, 'AppShell.build 里 TabBar( 应恰好一处，实际 ' + tabBars.length); return; }
  let column = tabBars[0].parent;
  while (column && !(ts.isEtsComponentExpression(column) && column.expression.getText() === 'Column')) { column = column.parent; }
  if (!column) { report('T5-locate', tabBars[0], 'TabBar 外层没有 Column'); return; }
  const mods = modifiersOf(column);
  reportOpaque(mods, '底栏外层 Column');
  reportOpaque(modifiersOf(tabBars[0]), '外壳的 TabBar');
  const material = mods.filter((m) => m.name === 'backgroundBlurStyle');
  if (material.length !== 1 || material[0].args.length < 1 || compact(material[0].args[0]) !== 'BlurStyle.COMPONENT_THICK') {
    report('T5-material', column, '底栏外层 Column 必须恰好一处 backgroundBlurStyle(BlurStyle.COMPONENT_THICK)，实际 ' + material.length + ' 处');
  }
  const navSf = parse(NAV);
  const tabStruct = navSf ? findStruct(navSf, 'TabBar') : null;
  if (tabStruct) {
    const tabsBuild = methodOf(tabStruct, 'build');
    for (const t of tabsBuild ? collect(tabsBuild, (n) => isNamedCall(n, 'Tabs')) : []) { reportOpaque(modifiersOf(t), 'struct TabBar 的 Tabs'); }
  }
  const total = countMaterial(shell) + (tabStruct ? countMaterial(tabStruct) : 0);
  if (total > 1) { report('T5-material', column, 'backgroundBlurStyle 有且仅一处（AppShell + TabBar 合计），实际 ' + total + ' 处（材质叠两层）'); }
  const safe = mods.filter((m) => m.name === 'expandSafeArea');
  const safeOk = safe.length === 1 && safe[0].args.length === 2 && compact(safe[0].args[0]) === '[SafeAreaType.SYSTEM]' &&
    compact(safe[0].args[1]) === '[SafeAreaEdge.BOTTOM]';
  if (!safeOk) { report('T5-safearea', column, '底栏外层 Column 必须保留 expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])'); }
}

// ---------------------------------------------------------------- T7（清单文件；inventory 由 check_tab_bar.py 判）

function checkCatalog() {
  const sf = parse(CATALOG);
  if (sf === null) { return; }
  const entries = collect(sf, (n) => ts.isCallExpression(n) && n.arguments.length > 0 && ts.isStringLiteralLike(n.arguments[0]) &&
    n.arguments[0].text === 'TabBar' && ts.isIdentifier(n.expression));
  if (entries.length !== 1) { report('T7-catalog', null, "CatalogManifest 里 c('TabBar', ...) 应恰好一处，实际 " + entries.length, CATALOG); return; }
  const entry = entries[0];
  const strings = collect(entry, (n) => ts.isStringLiteralLike(n)).filter((n) => n !== entry.arguments[0]);
  for (const s of strings) {
    if (s.text.includes('只接图片')) { report('T7-catalog', s, 'TabBar 目录说明不许再写「只接图片」'); }
    if (s.text.includes('badge')) { report('T7-catalog', s, 'TabBar 目录条目不许再有 badge：' + s.text.slice(0, 30)); }
  }
  if (!strings.some((s) => s.text === 'symbol')) { report('T7-catalog', entry, "TabBar 目录变体必须是 'symbol'"); }
}

// ---------------------------------------------------------------- T8（套件注册；device-test.sh 由 check_tab_bar.py 判）

function checkRegistration() {
  const sf = parse(LIST);
  if (sf === null) { return; }
  const imported = sf.statements.filter((n) => ts.isImportDeclaration(n) && n.importClause && n.importClause.name &&
    n.importClause.name.text === 'tabBarShellUiTest' && n.moduleSpecifier.text === './TabBarShellUi.test');
  if (imported.length !== 1) { report('T8-register', null, "List.test.ets 必须恰好一处 import tabBarShellUiTest from './TabBarShellUi.test'，实际 " + imported.length, LIST); }
  // 只认 testsuite 函数体的直接语句：包进 if / 回调、写在注释里都不算注册。
  let calls = 0;
  for (const fn of sf.statements.filter((n) => ts.isFunctionDeclaration(n) && n.body)) {
    calls += fn.body.statements.filter((st) => ts.isExpressionStatement(st) && ts.isCallExpression(st.expression) &&
      st.expression.expression.getText() === 'tabBarShellUiTest' && st.expression.arguments.length === 0).length;
  }
  if (calls !== 1) { report('T8-register', null, 'List.test.ets 的 testsuite 必须恰好一处直接调用 tabBarShellUiTest();，实际 ' + calls, LIST); }
}

checkTabBar();
checkTabBarItem();
checkResidue();
checkShell();
checkCatalog();
checkRegistration();
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete }));
