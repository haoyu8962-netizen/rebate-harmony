#!/usr/bin/env node
// FU-HM-A11Y-AGENT-harmony 宿主守卫的解析部分（测试作者 v1，新鲜独立 Claude，先红）。由 check_a11y_agent.py 调用，不单独跑。
// 依据：NATIVE/FU-HM-A11Y/brief-AGENT.md §2、§3「结构」AG1–AG6；README 末节「编排裁定 D10-1248」（⑦ S3-2 并入本单；⑬ 行标识不加键）；
// QA-12b/harmony-audit.md FU-HM-A11Y-10 / 12 / 14 / 17 / 18 / 20。写法照 tools/ci/l2cell/l2cell_ast.cjs、tools/ci/loginphone/loginphone_ast.cjs：
// 用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS，判定全部走 AST，注释与字符串里的字不算。
//   用法：node a11yagent_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>"}, "scan": ["features/agent/src/main/ets 下的 .ets 相对路径", ...]}
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."]}
//
//   AG1 商品卡组件段（FU-10 组件部分 + PRODUCT-CELL S3-2）：LIST / AI / GRID 各在 openable=true 时，信息组（accessibilityGroup(true) +
//       accessibilityText(cellLabel)）带 accessibilityRole(BUTTON)，且自身 .onClick 恰调一次 this.onOpen()、不调 onBuy（读屏双击信息组 =
//       onOpen）；openable=false 时信息组不挂任何点击 / 手势 / 按压 / 角色 / 焦点属性，组内也没有（不吞页面外层 .onClick，与基线一致）。
//   AG2 AI 卡：AgentProductItem 的 ProductCard 传 openable: true，onOpen 走 port.tap(… detail)，onBuy 仍走 port.buy；本 struct 不再挂裸
//       .onClick / 手势（外层可点容器无名称 / 角色的根源）。
//   AG3 标签（FU-12）：Agent 输入框 TextInput id = agent_input，accessibilityText = this.t(固定键)，不随配额 / 状态三元切换，键在
//       AgentDraftTexts 里有非空文字且不等于两句占位；举报补充说明 TextArea id = agent_report_supplement，accessibilityText = 固定键、有字。
//   AG4 弹层焦点与标题（FU-14 / 20）：页面标题 agent_title、同意标题 agent_consent_title、举报标题 agent_report_title 都是 TITLE_BAR；
//       后两者 focusable(true) 且有 onAppear 把焦点移到自身（CouliFocusReturn.to / accessibilityFocus）；
//       AG4-return 同意弹窗 onDidDisappear 处理器调 CouliFocusReturn，id 恰解析到 {agent_input, agent_title}（两者都要有）；举报半屏
//       onDisappear 调 CouliFocusReturn，id 是运行时的触发 id（不是固定常量）；
//       AG4-return-early（v2，Codex r1 S2）系统返回 / 点遮罩关闭时回焦标记不得在 onDidDisappear 前被 close() 关掉（见该段注释）；
//       AG4-unique 举报读屏入口 id 不是固定串（每条回复唯一）；AG4-record 读屏入口 onClick、长按 onAction 打开举报时都把自己的 id 记下来
//       （调用实参或赋值右侧与该组件 .id(...) 的实参同值）；AG4-trigger 长按的回复气泡有非固定 id 且 focusable(true)（焦点回得去）；
//       AG4-reported「已举报」标签有非固定 id 且 focusable(true)（入口消失后的回焦落点）。
//   AG5 行标识（FU-17 AI 段）：AgentFeedbackBar 声明 @Param replyTag: string；赞 / 踩（含已赞 / 已踩两支）与读屏举报入口的 accessibilityText
//       都带 this.replyTag 且用 PriceTerms.comma 相接（可经 this.<方法>() 转一手）；AgentTurnItemView 传 replyTag: AgentReplyTag.of(…blocks…)。
//   AG6 装饰圆点（FU-18）：features/agent 下每个只含圆点的 Text（'•' 等）挂 accessibilityLevel('no' / 'no-hide-descendants')，
//       或所在行成组（accessibilityGroup(true)）且行读屏名里没有圆点。
'use strict';
const fs = require('fs');
const path = require('path');

const PC = 'common/designsystem/src/main/ets/components/ProductCard.ets';
const AC = 'features/agent/src/main/ets/AgentCards.ets';
const TR = 'features/agent/src/main/ets/AgentTabRoot.ets';
const CD = 'features/agent/src/main/ets/AgentConsentDialog.ets';
const DT = 'common/core/src/main/ets/agent/AgentDraftTexts.ets';

const tsDir = process.argv[2];
if (!tsDir) { console.error('a11yagent_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('a11yagent_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('a11yagent_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
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
  if (text === undefined || text === null) {
    incomplete.push(rel + '：文件不存在，无法判定');
    parsed.set(rel, null);
    return null;
  }
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, ETS_OPTIONS);
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
const seen = new Set();
function report(rule, node, msg, file) {
  const f = file || (node ? node.getSourceFile().fileName : '');
  const line = node ? lineOf(node) : 0;
  const key = rule + '|' + f + '|' + line + '|' + msg;
  if (seen.has(key)) { return; }
  seen.add(key);
  violations.push({ rule: rule, file: f, line: line, msg: msg });
}
function need(rel, what) {
  incomplete.push(rel + '：' + what + '，无法判定');
}
function walk(node, visit) { visit(node); ts.forEachChild(node, (c) => walk(c, visit)); }
function collect(node, pred) { const out = []; if (node) { walk(node, (n) => { if (pred(n)) { out.push(n); } }); } return out; }
function compact(node) { return node.getText().replace(/\s+/g, ''); }
function unwrap(e) {
  while (e && (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isNonNullExpression(e))) { e = e.expression; }
  return e;
}
function isStr(n) { return n && (ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)); }
function memberName(m) { return m && m.name && (ts.isIdentifier(m.name) || ts.isStringLiteral(m.name)) ? m.name.text : ''; }
function findStruct(sf, name) { return sf.statements.find((s) => ts.isStructDeclaration(s) && s.name && s.name.text === name) || null; }
function findClass(sf, name) { return sf.statements.find((s) => ts.isClassDeclaration(s) && s.name && s.name.text === name) || null; }
function methodOf(owner, name) {
  return owner ? owner.members.find((m) => ts.isMethodDeclaration(m) && memberName(m) === name) || null : null;
}
function decorators(m) {
  const list = (ts.getAllDecorators ? ts.getAllDecorators(m) : (m.decorators || [])) || [];
  return list.map((d) => d.expression.getText());
}
function isThis(e) { return e && e.kind === ts.SyntaxKind.ThisKeyword; }
function thisCallName(e) {
  e = unwrap(e);
  if (e && ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression) && isThis(e.expression.expression)) {
    return e.expression.name.text;
  }
  return null;
}
function property(obj, name) {
  if (!obj || !ts.isObjectLiteralExpression(obj)) { return null; }
  return obj.properties.find((p) => (ts.isPropertyAssignment(p) || ts.isShorthandPropertyAssignment(p)) && memberName(p) === name) || null;
}
function chainOf(expr) {
  const calls = [];
  let e = unwrap(expr);
  while (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression) && !isThis(e.expression.expression)) {
    calls.unshift({ name: e.expression.name.text, args: e.arguments, node: e });
    e = unwrap(e.expression.expression);
  }
  return { root: e, calls: calls };
}
function componentName(root) {
  if (!root) { return null; }
  if (ts.isEtsComponentExpression(root)) { return root.expression.getText(); }
  if (ts.isCallExpression(root) && ts.isIdentifier(root.expression)) { return root.expression.text; }
  return null;
}
function lastCall(calls, name) {
  const hits = calls.filter((c) => c.name === name);
  return hits.length > 0 ? hits[hits.length - 1] : null;
}
function isFn(e) { e = unwrap(e); return e && (ts.isArrowFunction(e) || ts.isFunctionExpression(e)); }
function enclosingFunction(node) {
  for (let p = node.parent; p; p = p.parent) {
    if (ts.isFunctionLike(p) && p.body) { return p; }
  }
  return null;
}
function enclosingOwner(node) {
  for (let p = node.parent; p; p = p.parent) {
    if (ts.isStructDeclaration(p) || ts.isClassDeclaration(p)) { return p; }
  }
  return null;
}
function localInit(node, name) {
  const fn = enclosingFunction(node);
  if (!fn) { return null; }
  if (fn.parameters.some((p) => p.name.getText() === name)) { return null; }
  const decls = collect(fn.body, (n) => ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === name);
  return decls.length === 1 && decls[0].initializer ? decls[0].initializer : null;
}
/** 由内向外找声明 name 的函数：参数 → { fn, param: true }；局部变量 → { init }；都没有 → null。 */
function declaring(node, name) {
  for (let p = node.parent; p; p = p.parent) {
    if (!(ts.isFunctionLike(p) && p.body)) { continue; }
    if (p.parameters.some((x) => x.name.getText() === name)) { return { fn: p, param: true, init: null }; }
    const decls = collect(p.body, (n) => ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === name);
    if (decls.length === 1 && decls[0].initializer) { return { fn: p, param: false, init: decls[0].initializer }; }
  }
  return null;
}
function moduleConst(sf, name) {
  for (const s of sf.statements) {
    if (!ts.isVariableStatement(s)) { continue; }
    for (const d of s.declarationList.declarations) {
      if (ts.isIdentifier(d.name) && d.name.text === name && d.initializer) { return d.initializer; }
    }
  }
  return null;
}
function staticInit(sf, cls, name) {
  const c = findClass(sf, cls);
  if (!c) { return null; }
  const m = c.members.find((x) => ts.isPropertyDeclaration(x) && memberName(x) === name
    && (x.modifiers || []).some((k) => k.kind === ts.SyntaxKind.StaticKeyword));
  return m && m.initializer ? m.initializer : null;
}
/** 函数（箭头 / 方法）的返回表达式：表达式体，或 return 语句（不进嵌套函数）。 */
function returnExprs(fn) {
  if (!fn || !fn.body) { return []; }
  if (!ts.isBlock(fn.body)) { return [fn.body]; }
  const out = [];
  (function visit(n) {
    if (n !== fn.body && ts.isFunctionLike(n)) { return; }
    if (ts.isReturnStatement(n) && n.expression) { out.push(n.expression); }
    ts.forEachChild(n, visit);
  })(fn.body);
  return out;
}

// ---------------------------------------------------------------- 字符串求值（集合；'?' = 运行时才知道）
const UNKNOWN = '?';
/** paramHook(name, callNode)：表达式里调用 / 引用了所在方法的参数时，交给调用方按调用点求值（返回 Set 或 null）。 */
function strValues(expr, depth, paramHook) {
  const e = unwrap(expr);
  const out = new Set();
  if (!e || depth > 10) { out.add(UNKNOWN); return out; }
  const add = (s) => { for (const v of s) { out.add(v); } };
  if (isStr(e)) { out.add(e.text); return out; }
  if (ts.isConditionalExpression(e)) {
    add(strValues(e.whenTrue, depth + 1, paramHook));
    add(strValues(e.whenFalse, depth + 1, paramHook));
    return out;
  }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.PlusToken) {
    const a = strValues(e.left, depth + 1, paramHook);
    const b = strValues(e.right, depth + 1, paramHook);
    if (a.has(UNKNOWN) || b.has(UNKNOWN) || a.size * b.size > 16) { out.add(UNKNOWN); return out; }
    for (const x of a) { for (const y of b) { out.add(x + y); } }
    return out;
  }
  const sf = e.getSourceFile();
  if (ts.isIdentifier(e)) {
    const d = declaring(e, e.text);
    if (d && d.param) {
      const hooked = paramHook ? paramHook(e.text, e, d.fn) : null;
      if (hooked) { return hooked; }
      out.add(UNKNOWN);
      return out;
    }
    const init = (d && d.init) || moduleConst(sf, e.text);
    if (init) { return strValues(init, depth + 1, paramHook); }
    out.add(UNKNOWN);
    return out;
  }
  if (ts.isPropertyAccessExpression(e) && ts.isIdentifier(e.expression)) {
    const init = staticInit(sf, e.expression.text, e.name.text);
    if (init && (isStr(unwrap(init)) || ts.isConditionalExpression(unwrap(init)))) { return strValues(init, depth + 1, paramHook); }
    out.add(UNKNOWN);
    return out;
  }
  if (ts.isCallExpression(e)) {
    const name = thisCallName(e);
    const owner = enclosingOwner(e);
    if (name !== null && owner && e.arguments.length === 0) {
      const m = methodOf(owner, name);
      if (m && m.body && m.parameters.length === 0) {
        const rets = returnExprs(m);
        if (rets.length === 0) { out.add(UNKNOWN); return out; }
        for (const r of rets) { add(strValues(r, depth + 1, paramHook)); }
        return out;
      }
    }
    if (ts.isIdentifier(e.expression)) {
      const d = declaring(e, e.expression.text);
      if (d && d.param) {
        const hooked = paramHook ? paramHook(e.expression.text, e, d.fn) : null;
        if (hooked) { return hooked; }
      }
    }
  }
  out.add(UNKNOWN);
  return out;
}
function constId(expr) {
  const v = strValues(expr, 0, null);
  return v.size === 1 && !v.has(UNKNOWN) ? [...v][0] : null;
}
function isConstant(expr) {
  const v = strValues(expr, 0, null);
  return !v.has(UNKNOWN);
}
/** 表达式文字 + 它经 this.<方法>() / 局部常量 / 同文件静态方法 用到的方法体文字（展开 3 层）：判「带没带某个记号」用。 */
function expandedText(expr, depth) {
  const e = unwrap(expr);
  if (!e || depth > 3) { return ''; }
  let text = compact(e);
  const owner = enclosingOwner(e);
  for (const call of collect(e, (n) => ts.isCallExpression(n))) {
    const name = thisCallName(call);
    if (name !== null && owner) {
      const m = methodOf(owner, name);
      if (m && m.body) { text += '|' + expandedText(m.body, depth + 1); }
    }
  }
  for (const id of collect(e, (n) => ts.isIdentifier(n) && !(ts.isPropertyAccessExpression(n.parent) && n.parent.name === n))) {
    const init = localInit(id, id.text);
    if (init) { text += '|' + expandedText(init, depth + 1); }
  }
  return text;
}
/** a 与 b 是否同值（文字相同；或经局部常量 / 无参 this.<方法>() 展开后相同）。 */
function sameValue(a, b) {
  const forms = (x) => {
    const out = new Set();
    let e = unwrap(x);
    for (let i = 0; e && i < 4; i++) {
      out.add(compact(e));
      if (ts.isIdentifier(e)) { e = localInit(e, e.text); continue; }
      const name = thisCallName(e);
      const owner = e ? enclosingOwner(e) : null;
      if (name !== null && owner && e.arguments.length === 0) {
        const m = methodOf(owner, name);
        const rets = m ? returnExprs(m) : [];
        e = rets.length === 1 ? unwrap(rets[0]) : null;
        continue;
      }
      break;
    }
    return out;
  };
  const fa = forms(a);
  for (const f of forms(b)) { if (fa.has(f)) { return true; } }
  return false;
}

// ---------------------------------------------------------------- 组件语句收集（每条：根组件名、属性链、语句节点）
function componentsIn(scope) {
  const out = [];
  for (const st of collect(scope, (n) => ts.isExpressionStatement(n))) {
    const { root, calls } = chainOf(st.expression);
    const name = componentName(root);
    if (name === null) { continue; }
    out.push({ name: name, root: root, calls: calls, stmt: st, args: root.arguments || [] });
  }
  return out;
}
/** 焦点移动调用：CouliFocusReturn.to(ui, id) / CouliFocusReturn.accessibilityFocus(ui, id)。返回 [{ call, id }]。 */
function focusCalls(scope) {
  return collect(scope, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
    && compact(n.expression.expression) === 'CouliFocusReturn' && ['to', 'accessibilityFocus'].includes(n.expression.name.text)
    && n.arguments.length >= 2).map((c) => ({ call: c, id: c.arguments[1] }));
}
/** 处理器体 + 它调用的同 owner 方法体（3 层）。 */
function bodiesOf(fn, owner, depth) {
  const out = [];
  if (!fn || depth > 3) { return out; }
  const body = fn.body || fn;
  out.push(body);
  for (const call of collect(body, (n) => ts.isCallExpression(n))) {
    const name = thisCallName(call);
    const m = name !== null ? methodOf(owner, name) : null;
    if (m && m.body) { out.push(...bodiesOf(m, owner, depth + 1)); }
  }
  return out;
}
function roleOf(calls) {
  const r = lastCall(calls, 'accessibilityRole');
  return r && r.args[0] ? compact(unwrap(r.args[0])) : null;
}
function focusTrue(calls) {
  const f = lastCall(calls, 'focusable');
  return !!(f && f.args[0] && unwrap(f.args[0]).kind === ts.SyntaxKind.TrueKeyword);
}

// ---------------------------------------------------------------- AG1：ProductCard 组件段（照 l2cell_ast.cjs 的可达界面遍历）
const CELL_LABEL = 'ProductCardA11y.cellLabel(this.data)';
const PRESS_ATTRS = ['onClick', 'onTouch', 'gesture', 'priorityGesture', 'parallelGesture', 'clickEffect', 'stateStyles', 'onHover',
  'onKeyEvent'];
const STATIC_FORBIDDEN = PRESS_ATTRS.concat(['accessibilityRole', 'focusable', 'onAccessibilityHover']);

function evalBool(expr, env, owner, depth) {
  const e = unwrap(expr);
  if (!e || depth > 8) { return null; }
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isPropertyAccessExpression(e) && isThis(e.expression) && e.name.text === 'openable') { return env.openable; }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) {
    const v = evalBool(e.operand, env, owner, depth + 1);
    return v === null ? null : !v;
  }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    if (op === ts.SyntaxKind.AmpersandAmpersandToken || op === ts.SyntaxKind.BarBarToken) {
      const a = evalBool(e.left, env, owner, depth + 1);
      const b = evalBool(e.right, env, owner, depth + 1);
      if (op === ts.SyntaxKind.AmpersandAmpersandToken) {
        if (a === false || b === false) { return false; }
        return a === true && b === true ? true : null;
      }
      if (a === true || b === true) { return true; }
      return a === false && b === false ? false : null;
    }
    const eq = op === ts.SyntaxKind.EqualsEqualsEqualsToken || op === ts.SyntaxKind.EqualsEqualsToken;
    const ne = op === ts.SyntaxKind.ExclamationEqualsEqualsToken || op === ts.SyntaxKind.ExclamationEqualsToken;
    if (eq || ne) {
      const l = compact(unwrap(e.left));
      const r = compact(unwrap(e.right));
      let other = null;
      if (l === 'this.variant') { other = r; } else if (r === 'this.variant') { other = l; }
      if (other !== null) {
        const m = /^ProductCardVariant\.(LIST|AI|GRID|LARGE)$/.exec(other);
        if (!m) { return null; }
        return eq ? env.variant === m[1] : env.variant !== m[1];
      }
      let flag = null;
      if (l === 'this.openable') { flag = r; } else if (r === 'this.openable') { flag = l; }
      if (flag === 'true' || flag === 'false') {
        const same = env.openable === (flag === 'true');
        return eq ? same : !same;
      }
    }
    return null;
  }
  const name = thisCallName(e);
  if (name !== null && owner && e.arguments.length === 0) {
    const m = methodOf(owner, name);
    if (m && m.body && m.parameters.length === 0) {
      const rets = returnExprs(m);
      if (rets.length === 0) { return null; }
      const vals = rets.map((r) => evalBool(r, env, owner, depth + 1));
      if (vals.every((v) => v === true)) { return true; }
      if (vals.every((v) => v === false)) { return false; }
    }
  }
  return null;
}
/** 属性实参按 env 取值：三元能判的取一支（undefined / null 视为不挂）。返回表达式或 null。 */
function pickArg(expr, env, owner) {
  let e = unwrap(expr);
  for (let i = 0; e && i < 6 && ts.isConditionalExpression(e); i++) {
    const c = evalBool(e.condition, env, owner, 0);
    if (c === null) { return e; }
    e = unwrap(c ? e.whenTrue : e.whenFalse);
  }
  if (!e || e.kind === ts.SyntaxKind.NullKeyword || (ts.isIdentifier(e) && e.text === 'undefined')) { return null; }
  return e;
}
function resolvesTo(expr, want, owner, depth) {
  const e = unwrap(expr);
  if (!e || depth > 6) { return false; }
  if (compact(e) === want) { return true; }
  if (ts.isIdentifier(e)) {
    const init = localInit(e, e.text);
    return init ? resolvesTo(init, want, owner, depth + 1) : false;
  }
  const name = thisCallName(e);
  if (owner && name !== null && e.arguments.length === 0) {
    const m = methodOf(owner, name);
    if (!m || !m.body || m.parameters.length > 0) { return false; }
    const rets = returnExprs(m);
    return rets.length > 0 && rets.every((r) => resolvesTo(r, want, owner, depth + 1));
  }
  return false;
}
function reach(owner, env) {
  const events = [];
  const build = methodOf(owner, 'build');
  if (!build || !build.body) { return events; }
  const builders = new Map();
  for (const m of owner.members) {
    if (ts.isMethodDeclaration(m) && m.body && decorators(m).includes('Builder')) { builders.set(memberName(m), m); }
  }
  function visitStatements(stmts, ctx, stack) { for (const s of stmts) { visitStatement(s, ctx, stack); } }
  function visitStatement(s, ctx, stack) {
    if (ts.isIfStatement(s)) {
      const c = evalBool(s.expression, env, owner, 0);
      if (c !== false) { visitStatement(s.thenStatement, ctx, stack); }
      if (c !== true && s.elseStatement) { visitStatement(s.elseStatement, ctx, stack); }
      return;
    }
    if (ts.isBlock(s)) { visitStatements(s.statements, ctx, stack); return; }
    if (ts.isExpressionStatement(s)) { visitExpression(s.expression, ctx, stack); }
  }
  function visitExpression(expr, ctx, stack) {
    const { root, calls } = chainOf(expr);
    const bname = thisCallName(root);
    if (bname !== null) {
      events.push({ kind: 'builder', name: bname, node: root, ctx: ctx, attrs: calls });
      const m = builders.get(bname);
      if (m && !stack.includes(bname)) { visitStatements(m.body.statements, ctx, stack.concat([bname])); }
      return;
    }
    const name = componentName(root);
    if (name === null) { return; }
    const ev = { kind: 'comp', name: name, node: root, args: root.arguments || [], ctx: ctx, attrs: calls };
    events.push(ev);
    let next = ctx;
    const groupCall = calls.find((c) => c.name === 'accessibilityGroup');
    if (groupCall) {
      const arg = groupCall.args[0] ? unwrap(groupCall.args[0]) : null;
      if (!(arg && arg.kind === ts.SyntaxKind.FalseKeyword)) {
        const textCall = lastCall(calls, 'accessibilityText');
        ev.cell = !!(textCall && textCall.args[0] && resolvesTo(textCall.args[0], CELL_LABEL, owner, 0));
        next = Object.assign({}, next, { groups: next.groups.concat([ev]) });
      }
    }
    if (name === 'ForEach' || name === 'LazyForEach') {
      const fn = ev.args[1];
      if (isFn(fn) && fn.body && ts.isBlock(fn.body)) { visitStatements(fn.body.statements, next, stack); }
      return;
    }
    if (ts.isEtsComponentExpression(root) && root.body && ts.isBlock(root.body)) {
      visitStatements(root.body.statements, next, stack);
    }
  }
  visitStatements(build.body.statements, { groups: [] }, ['build']);
  return events;
}
function handlerCallsOpenOnce(fnExpr) {
  const fn = unwrap(fnExpr);
  if (!isFn(fn)) { return false; }
  const opens = collect(fn.body, (n) => ts.isCallExpression(n) && compact(n.expression) === 'this.onOpen');
  const buys = collect(fn.body, (n) => ts.isCallExpression(n) && compact(n.expression) === 'this.onBuy');
  return opens.length === 1 && buys.length === 0;
}

function checkProductCard() {
  const sf = parse(PC);
  if (!sf) { return; }
  const owner = findStruct(sf, 'ProductCard');
  if (!owner) { need(PC, '找不到 struct ProductCard'); return; }
  for (const variant of ['LIST', 'AI', 'GRID']) {
    for (const open of [true, false]) {
      const env = { variant: variant, openable: open };
      const tag = variant + ' openable=' + open;
      const events = reach(owner, env);
      const infos = events.filter((e) => e.kind === 'comp' && e.cell);
      if (infos.length === 0) {
        report('AG1-group', owner, tag + '：可达界面里没有信息组（accessibilityGroup(true) + accessibilityText(ProductCardA11y.cellLabel(this.data))）', PC);
        continue;
      }
      for (const info of infos) {
        if (open) {
          const role = lastCall(info.attrs, 'accessibilityRole');
          const picked = role && role.args[0] ? pickArg(role.args[0], env, owner) : null;
          if (!picked || compact(picked) !== 'AccessibilityRoleType.BUTTON') {
            report('AG1-role', info.node, tag + '：信息组应带 .accessibilityRole(AccessibilityRoleType.BUTTON)（可打开的卡，读屏读「按钮」；FU-HM-A11Y-10）');
          }
          const clicks = info.attrs.filter((c) => c.name === 'onClick').map((c) => (c.args[0] ? pickArg(c.args[0], env, owner) : null))
            .filter((x) => x !== null);
          if (clicks.length !== 1 || !handlerCallsOpenOnce(clicks[0])) {
            report('AG1-open', info.node, tag + '：信息组自身应恰有一个 .onClick，处理器恰调一次 this.onOpen()、不调 onBuy（读屏双击信息组 = 打开详情；'
              + 'PRODUCT-CELL S3-2：双击不一定传到外壳 CouliCard 的点击）');
          }
        } else {
          for (const c of info.attrs) {
            if (!STATIC_FORBIDDEN.includes(c.name)) { continue; }
            const picked = c.args[0] ? pickArg(c.args[0], env, owner) : c.node;
            if (picked !== null) {
              report('AG1-static', c.node, tag + '：openable=false 时信息组不得挂 .' + c.name + '(…)（与基线一致：不接点击、不当按钮，'
                + '不吞页面外层 .onClick；首页 / 搜索 / 剪贴板卡由流程单再翻开关）');
            }
          }
          for (const ev of events) {
            if (ev.kind !== 'comp' || ev === info || !ev.ctx.groups.includes(info)) { continue; }
            for (const c of ev.attrs) {
              if (PRESS_ATTRS.includes(c.name) && (!c.args[0] || pickArg(c.args[0], env, owner) !== null)) {
                report('AG1-static', c.node, tag + '：openable=false 时信息组里的 ' + ev.name + ' 挂了 .' + c.name + '(…)（会吞页面外层点击）');
              }
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------- AG2：AI 卡切 openable
function checkAiCard() {
  const sf = parse(AC);
  if (!sf) { return; }
  const item = findStruct(sf, 'AgentProductItem');
  if (!item) { need(AC, '找不到 struct AgentProductItem'); return; }
  const build = methodOf(item, 'build');
  const cards = componentsIn(build).filter((c) => c.name === 'ProductCard');
  if (cards.length !== 1) { report('AG2-openable', build || item, 'AgentProductItem 应恰有一个 ProductCard 调用（实际 ' + cards.length + '）'); return; }
  const opts = cards[0].args[0];
  const openable = property(opts, 'openable');
  if (!openable || !ts.isPropertyAssignment(openable) || unwrap(openable.initializer).kind !== ts.SyntaxKind.TrueKeyword) {
    report('AG2-openable', cards[0].root, 'AI 卡 ProductCard 应传 openable: true（Agent 没有流程单，本单切；信息组随之成按钮、读屏可激活）');
  }
  const onOpen = property(opts, 'onOpen');
  const fn = onOpen && ts.isPropertyAssignment(onOpen) ? unwrap(onOpen.initializer) : null;
  const taps = isFn(fn) ? collect(fn.body, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
    && n.expression.name.text === 'tap' && /port/.test(compact(n.expression.expression))) : [];
  const detail = isFn(fn) && /\.detail\b/.test(fn.body.getText());
  const buyInOpen = isFn(fn) && collect(fn.body, (n) => ts.isPropertyAccessExpression(n) && n.name.text === 'buy').length > 0;
  if (taps.length !== 1 || !detail || buyInOpen) {
    report('AG2-onopen', onOpen || cards[0].root, 'AI 卡 onOpen 应恰调一次 port.tap(… detail)（原外层 .onClick 的打开详情），且不碰 buy');
  }
  const onBuy = property(opts, 'onBuy');
  const bfn = onBuy && ts.isPropertyAssignment(onBuy) ? unwrap(onBuy.initializer) : null;
  const buys = isFn(bfn) ? collect(bfn.body, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
    && n.expression.name.text === 'buy' && /port/.test(compact(n.expression.expression))) : [];
  if (buys.length !== 1) { report('AG2-buy', onBuy || cards[0].root, 'AI 卡 onBuy 应仍恰调一次 port.buy(…)（购买路径不变）'); }
  for (const comp of componentsIn(build)) {
    for (const c of comp.calls) {
      if (['onClick', 'onTouch', 'gesture', 'priorityGesture', 'parallelGesture'].includes(c.name)) {
        report('AG2-outer', c.node, 'AgentProductItem 的 ' + comp.name + ' 仍挂 .' + c.name + '(…)（外层裸点击容器无名称 / 角色，FU-HM-A11Y-10；'
          + '打开详情改走 ProductCard 的 onOpen）');
      }
    }
  }
}

// ---------------------------------------------------------------- AG3：输入框与补充说明的读屏名
function draftTexts() {
  const sf = parse(DT);
  const map = new Map();
  if (!sf) { return map; }
  for (const call of collect(sf, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
    && n.expression.name.text === 'set' && n.arguments.length === 2 && isStr(unwrap(n.arguments[0])))) {
    const v = unwrap(call.arguments[1]);
    map.set(unwrap(call.arguments[0]).text, isStr(v) ? v.text : UNKNOWN);
  }
  return map;
}
/** accessibilityText 的实参是否「固定键」：this.t(K)（K 解析为唯一字符串），整个实参里没有三元 / 逻辑或。返回键或 null。 */
function fixedKey(arg) {
  const e = unwrap(arg);
  if (!e || collect(e, (n) => ts.isConditionalExpression(n) || (ts.isBinaryExpression(n)
    && [ts.SyntaxKind.BarBarToken, ts.SyntaxKind.QuestionQuestionToken, ts.SyntaxKind.AmpersandAmpersandToken].includes(n.operatorToken.kind))).length > 0) {
    return null;
  }
  if (ts.isCallExpression(e) && compact(e.expression) === 'this.t' && e.arguments.length === 1) {
    return constId(e.arguments[0]);
  }
  if (ts.isIdentifier(e)) {
    const init = localInit(e, e.text);
    return init ? fixedKey(init) : null;
  }
  return null;
}
function checkLabels(drafts) {
  const sf = parse(TR);
  if (!sf) { return; }
  const root = findStruct(sf, 'AgentTabRoot');
  const sheet = findStruct(sf, 'AgentReportSheetContent');
  if (!root || !sheet) { need(TR, '找不到 struct AgentTabRoot / AgentReportSheetContent'); return; }
  const placeholders = ['agent.draft.input_placeholder', 'agent.draft.quota.input_disabled'].map((k) => drafts.get(k));
  const inputs = componentsIn(root).filter((c) => c.name === 'TextInput');
  if (inputs.length !== 1) { report('AG3-id', root, 'AgentTabRoot 应恰有一个 TextInput（实际 ' + inputs.length + '）'); }
  for (const input of inputs) {
    const id = lastCall(input.calls, 'id');
    if (!id || constId(id.args[0]) !== 'agent_input') {
      report('AG3-id', input.root, 'Agent 输入框应 .id(\'agent_input\')（设备用例与同意弹窗回焦定位用）');
    }
    const label = lastCall(input.calls, 'accessibilityText');
    const key = label && label.args[0] ? fixedKey(label.args[0]) : null;
    if (key === null) {
      report('AG3-label', label ? label.node : input.root, 'Agent 输入框应 .accessibilityText(this.t(固定键))：读屏名不随配额 / 禁用三元切换'
        + '（现在只有占位，占位在两句间切换；FU-HM-A11Y-12）');
    } else {
      const v = drafts.get(key);
      if (v === undefined || v === UNKNOWN || v.trim().length === 0) {
        report('AG3-key', label.node, '输入框读屏名键 ' + key + ' 在 AgentDraftTexts 里没有非空文字（书 §2.3：加 agent.draft.input_label）');
      } else if (placeholders.includes(v)) {
        report('AG3-label', label.node, '输入框读屏名「' + v + '」就是占位文字（应是固定的字段名，不等于任一占位）');
      }
    }
  }
  const areas = componentsIn(sheet).filter((c) => c.name === 'TextArea');
  if (areas.length !== 1) { report('AG3-id', sheet, 'AgentReportSheetContent 应恰有一个 TextArea（实际 ' + areas.length + '）'); }
  for (const area of areas) {
    const id = lastCall(area.calls, 'id');
    if (!id || constId(id.args[0]) !== 'agent_report_supplement') {
      report('AG3-id', area.root, '举报补充说明应 .id(\'agent_report_supplement\')（设备用例定位用）');
    }
    const label = lastCall(area.calls, 'accessibilityText');
    const key = label && label.args[0] ? fixedKey(label.args[0]) : null;
    const v = key === null ? undefined : drafts.get(key);
    if (key === null || v === undefined || v === UNKNOWN || v.trim().length === 0) {
      report('AG3-label', label ? label.node : area.root, '举报补充说明应 .accessibilityText(this.t(固定键))，键有非空文字（复用 agent.draft.report.supplement；FU-HM-A11Y-12）');
    }
  }
}

// ---------------------------------------------------------------- AG4：标题、打开移焦、关闭回焦、行唯一 id
function textOfKey(owner, key) {
  return componentsIn(owner).filter((c) => c.name === 'Text' && c.args[0] && compact(c.args[0]) === "this.t('" + key + "')");
}
function titleChecks(owner, key, id, needFocus, file, what) {
  const hits = textOfKey(owner, key);
  if (hits.length !== 1) { report('AG4-title', owner, what + '：找不到唯一的 Text(this.t(\'' + key + '\'))（实际 ' + hits.length + '）', file); return; }
  const t = hits[0];
  const idCall = lastCall(t.calls, 'id');
  if (!idCall || constId(idCall.args[0]) !== id) { report('AG4-title', t.root, what + '应 .id(\'' + id + '\')'); }
  if (roleOf(t.calls) !== 'AccessibilityRoleType.TITLE_BAR') {
    report('AG4-title', t.root, what + '应 .accessibilityRole(AccessibilityRoleType.TITLE_BAR)（只有 accessibilityLevel(\'yes\') 读屏不知道是标题；FU-HM-A11Y-20）');
  }
  if (!needFocus) { return; }
  if (!focusTrue(t.calls)) { report('AG4-title', t.root, what + '应 .focusable(true)（打开时焦点要能落上去）'); }
  const appearFocus = [];
  for (const comp of componentsIn(owner)) {
    for (const c of comp.calls.filter((x) => x.name === 'onAppear')) {
      for (const f of focusCalls(c.args[0])) { appearFocus.push(f); }
    }
  }
  if (!appearFocus.some((f) => constId(f.id) === id)) {
    report('AG4-title', t.root, what + '：打开时没有把焦点移到标题（.onAppear 里 CouliFocusReturn.to / accessibilityFocus(…, \'' + id + '\')；FU-HM-A11Y-14）');
  }
}
/** 同意弹窗 onDidDisappear 处理器：对象字面量里的 onDidDisappear 值 → 箭头；this.<字段> → 构造参数 → new 调用的实参。 */
function resolveHandlers(expr, sf, depth) {
  const e = unwrap(expr);
  if (!e || depth > 4) { return []; }
  if (isFn(e)) { return [e]; }
  if (ts.isIdentifier(e)) {
    const init = localInit(e, e.text);
    return init ? resolveHandlers(init, sf, depth + 1) : [];
  }
  if (ts.isPropertyAccessExpression(e) && isThis(e.expression)) {
    const owner = enclosingOwner(e);
    const field = e.name.text;
    const ctor = owner ? owner.members.find((m) => ts.isConstructorDeclaration(m)) : null;
    if (!ctor || !ctor.body) { return []; }
    const assign = collect(ctor.body, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken
      && compact(n.left) === 'this.' + field)[0];
    if (!assign || !ts.isIdentifier(unwrap(assign.right))) { return []; }
    const idx = ctor.parameters.findIndex((p) => p.name.getText() === unwrap(assign.right).text);
    if (idx < 0) { return []; }
    const out = [];
    for (const n of collect(sf, (x) => ts.isNewExpression(x) && x.expression.getText() === owner.name.text)) {
      if (n.arguments && n.arguments[idx]) { out.push(...resolveHandlers(n.arguments[idx], sf, depth + 1)); }
    }
    return out;
  }
  return [];
}
/** AgentConsentHost.open 的函数型参数在 AgentTabRoot 调用点的实参求值（host.open(…, () => this.x())）。 */
function consentParamHook(trSf) {
  return (name, node, fn) => {
    const method = fn;
    if (!ts.isMethodDeclaration(method) || memberName(method) !== 'open') { return null; }
    const idx = method.parameters.findIndex((p) => p.name.getText() === name);
    if (idx < 0 || !trSf) { return null; }
    const calls = collect(trSf, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
      && n.expression.name.text === 'open' && n.arguments.length > idx);
    if (calls.length === 0) { return null; }
    const out = new Set();
    for (const call of calls) {
      const arg = unwrap(call.arguments[idx]);
      const callsParam = ts.isCallExpression(node) && node.expression.getText() === name;
      if (callsParam && isFn(arg)) {
        const rets = returnExprs(arg);
        if (rets.length === 0) { out.add(UNKNOWN); }
        for (const r of rets) { for (const v of strValues(r, 0, null)) { out.add(v); } }
      } else if (!callsParam) {
        for (const v of strValues(arg, 0, null)) { out.add(v); }
      } else {
        out.add(UNKNOWN);
      }
    }
    return out;
  };
}
function checkConsentReturn() {
  const sf = parse(CD);
  const trSf = parse(TR);
  if (!sf || !trSf) { return; }
  const host = findClass(sf, 'AgentConsentHost');
  if (!host) { need(CD, '找不到 class AgentConsentHost'); return; }
  const props = collect(sf, (n) => ts.isPropertyAssignment(n) && memberName(n) === 'onDidDisappear');
  if (props.length === 0) { report('AG4-return', host, '同意弹窗找不到 onDidDisappear（关闭后要回焦）', CD); return; }
  const handlers = [];
  for (const p of props) { handlers.push(...resolveHandlers(p.initializer, sf, 0)); }
  if (handlers.length === 0) { report('AG4-return', props[0], '同意弹窗 onDidDisappear 的处理器求不出来（应是箭头函数，或经构造参数传入的箭头函数）'); return; }
  const hook = consentParamHook(trSf);
  checkConsentEarlyCancel(sf, host, handlers);
  for (const h of handlers) {
    const owner = enclosingOwner(h);
    const calls = [];
    for (const b of bodiesOf(h, owner, 0)) { calls.push(...focusCalls(b)); }
    if (calls.length === 0) {
      report('AG4-return', h, '同意弹窗关闭后没有回焦（onDidDisappear 里没有 CouliFocusReturn.to；:184 注释写「关闭后焦点回原位」；FU-HM-A11Y-14）');
      continue;
    }
    const values = new Set();
    for (const c of calls) { for (const v of strValues(c.id, 0, hook)) { values.add(v); } }
    const want = ['agent_input', 'agent_title'];
    const extra = [...values].filter((v) => !want.includes(v));
    if (extra.length > 0 || !want.every((w) => values.has(w))) {
      report('AG4-return', calls[0].call, '同意弹窗关闭后的回焦 id 应恰在 {agent_input, agent_title} 里且两者都有（输入框可用回输入框，否则回页面标题；书 §2.4），'
        + '实际可能取值 ' + JSON.stringify([...values].map((v) => (v === UNKNOWN ? '（无法静态判定）' : v))));
    }
  }
}
// ---------------------------------------------------------------- AG4-return-early（测试 v2，Codex r1 S2）
// 系统返回 / 点遮罩关闭：onWillDismiss 提交 consentDismissed → 状态同步（AgentTabRoot.syncConsent）看到票据没了、openSerial 仍是本实例 →
// host.close() → 回焦标记被关 → onDidDisappear 不回焦。结构判据（执行级判据见 run-logic.cjs ③）：
//   close()（展开同类方法 3 层）里把 onDidDisappear 回焦守卫用到的标记写成布尔字面量、且这次写入不以「onWillDismiss 写过的名字」为条件时，
//   onWillDismiss 处理器必须在调 consentDismissed 之前把本实例从承载方摘下（.release( / .cancel(，可经同类方法），或根本不在 onWillDismiss
//   里提交（挪到消失后）。三种合理修法（提交前摘实例、close 按用户关闭记号跳过、提交挪到消失后）都放行。
/** 表达式里出现的名字（标识符、属性名）；局部常量再展开一层初值。 */
function namesIn(expr) {
  const out = new Set();
  for (const id of collect(expr, (n) => ts.isIdentifier(n))) {
    out.add(id.text);
    const init = localInit(id, id.text);
    if (init) { for (const x of collect(init, (n) => ts.isIdentifier(n))) { out.add(x.text); } }
  }
  return out;
}
/** node 到 stop 之间所有 if / 三元 / && || 的条件里的名字（node 在其分支里）。 */
function guardNames(node, stop) {
  const out = new Set();
  for (let p = node.parent, child = node; p && p !== stop; child = p, p = p.parent) {
    if (ts.isIfStatement(p) && child !== p.expression) { for (const n of namesIn(p.expression)) { out.add(n); } }
    if (ts.isConditionalExpression(p) && child !== p.condition) { for (const n of namesIn(p.condition)) { out.add(n); } }
    if (ts.isBinaryExpression(p) && child === p.right && [ts.SyntaxKind.AmpersandAmpersandToken, ts.SyntaxKind.BarBarToken]
      .includes(p.operatorToken.kind)) { for (const n of namesIn(p.left)) { out.add(n); } }
  }
  return out;
}
function lastName(e) {
  e = unwrap(e);
  if (ts.isIdentifier(e)) { return e.text; }
  if (ts.isPropertyAccessExpression(e)) { return e.name.text; }
  return '';
}
function isBoolLit(e) { e = unwrap(e); return e && (e.kind === ts.SyntaxKind.TrueKeyword || e.kind === ts.SyntaxKind.FalseKeyword); }
/** 在 limit 之前（源码位置）调用 .release( / .cancel(，或调用的同类方法里有。 */
function detachesBefore(body, owner, limit) {
  for (const call of collect(body, (n) => ts.isCallExpression(n) && n.getStart() < limit)) {
    if (ts.isPropertyAccessExpression(call.expression) && ['release', 'cancel'].includes(call.expression.name.text)
      && compact(call.expression.expression) !== 'action') { return true; }
    const name = thisCallName(call);
    const m = name !== null ? methodOf(owner, name) : null;
    if (m && m.body && bodiesOf(m, owner, 1).some((b) => collect(b, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
      && ['release', 'cancel'].includes(n.expression.name.text)).length > 0)) { return true; }
  }
  return false;
}
function checkConsentEarlyCancel(sf, host, didHandlers) {
  const closeM = methodOf(host, 'close');
  if (!closeM || !closeM.body) { return; }
  const guard = new Set();
  for (const h of didHandlers) {
    const owner = enclosingOwner(h);
    for (const b of bodiesOf(h, owner, 0)) {
      for (const c of focusCalls(b)) { for (const n of guardNames(c.call, h.parent)) { guard.add(n); } }
    }
  }
  if (guard.size === 0) { return; }
  const willProps = collect(sf, (n) => ts.isPropertyAssignment(n) && memberName(n) === 'onWillDismiss');
  const willHandlers = [];
  for (const p of willProps) { willHandlers.push(...resolveHandlers(p.initializer, sf, 0)); }
  if (willHandlers.length === 0) { return; }
  const written = new Set();
  for (const h of willHandlers) {
    for (const b of bodiesOf(h, enclosingOwner(h), 0)) {
      for (const as of collect(b, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken)) {
        written.add(lastName(as.left));
      }
    }
  }
  const unguarded = [];
  for (const b of bodiesOf(closeM, host, 0)) {
    for (const as of collect(b, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken)) {
      if (!guard.has(lastName(as.left)) || !isBoolLit(as.right)) { continue; }
      const conds = guardNames(as, b.parent);
      if (![...conds].some((n) => written.has(n))) { unguarded.push(as); }
    }
  }
  if (unguarded.length === 0) { return; }
  for (const h of willHandlers) {
    const owner = enclosingOwner(h);
    const submits = collect(h.body || h, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
      && n.expression.name.text === 'consentDismissed');
    if (submits.length === 0) { continue; }
    const limit = Math.min(...submits.map((c) => c.getStart()));
    if (detachesBefore(h.body || h, owner, limit)) { continue; }
    report('AG4-return-early', submits[0], '系统返回 / 点遮罩关闭同意弹窗：onWillDismiss 提交 consentDismissed 时本实例仍挂在承载方（openSerial 不为 0），'
      + '随后的状态同步调 close()，而 close() 在 ' + CD + ':' + lineOf(unguarded[0]) + ' 无条件关掉回焦标记「' + unguarded[0].getText()
      + '」→ onDidDisappear 不回焦（Codex r1 S2；内存探针回焦 0 次）。应在提交前把本实例从承载方摘下，或让 close() 跳过已由用户关闭的实例，或把提交挪到消失后');
  }
}
/** 举报触发处：读屏入口（hitTestBehavior None 的 Button，onClick 调 reportOpen）与长按（LongPressGesture onAction 调 reportOpen）。 */
function triggerSites(sf) {
  const sites = [];
  for (const comp of componentsIn(sf)) {
    for (const c of comp.calls) {
      if (c.name === 'onClick' && isFn(c.args[0]) && /reportOpen\(/.test(c.args[0].getText())) {
        sites.push({ kind: 'entry', comp: comp, handler: unwrap(c.args[0]) });
      }
      if (c.name === 'gesture' || c.name === 'parallelGesture' || c.name === 'priorityGesture') {
        for (const on of collect(c.node, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
          && n.expression.name.text === 'onAction' && /LongPressGesture/.test(n.expression.expression.getText()))) {
          if (isFn(on.arguments[0]) && /reportOpen\(/.test(on.arguments[0].getText())) {
            sites.push({ kind: 'longpress', comp: comp, handler: unwrap(on.arguments[0]) });
          }
        }
      }
    }
  }
  return sites;
}
function recordsId(handler, idArg) {
  for (const call of collect(handler.body, (n) => ts.isCallExpression(n))) {
    if (/reportOpen$/.test(compact(call.expression))) { continue; }
    if (call.arguments.some((a) => sameValue(a, idArg))) { return true; }
  }
  for (const as of collect(handler.body, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken)) {
    if (sameValue(as.right, idArg)) { return true; }
  }
  return false;
}
function checkReport() {
  const sf = parse(AC);
  const trSf = parse(TR);
  if (!sf || !trSf) { return; }
  const sites = triggerSites(sf);
  for (const kind of ['entry', 'longpress']) {
    if (!sites.some((s) => s.kind === kind)) {
      report('AG4-record', null, (kind === 'entry' ? '读屏举报入口 .onClick' : '回复气泡长按 onAction') + ' 里找不到打开举报的 reportOpen(…)', AC);
    }
  }
  for (const s of sites) {
    const idCall = lastCall(s.comp.calls, 'id');
    const what = s.kind === 'entry' ? '读屏举报入口' : '长按的回复气泡';
    if (!idCall || !idCall.args[0]) {
      report(s.kind === 'entry' ? 'AG4-unique' : 'AG4-trigger', s.comp.root, what + '没有 .id(…)（举报半屏关闭后焦点回不去）');
      continue;
    }
    if (isConstant(idCall.args[0])) {
      report(s.kind === 'entry' ? 'AG4-unique' : 'AG4-trigger', idCall.node, what + '的 id 是固定串 ' + JSON.stringify([...strValues(idCall.args[0], 0, null)])
        + '：每条回复都一样，回焦会落到别的回复上（应带回复键，如 \'agent_report_a11y_entry_\' + messageId）');
    }
    if (s.kind === 'longpress' && !focusTrue(s.comp.calls)) {
      report('AG4-trigger', s.comp.root, '长按的回复气泡应 .focusable(true)（不可聚焦的容器 requestFocus 落空，回焦失败）');
    }
    if (!recordsId(s.handler, idCall.args[0])) {
      report('AG4-record', s.handler, what + '打开举报时没有记下自己的 id（处理器里应有一处调用实参 / 赋值右侧与 .id(…) 同值，半屏关闭时回到它；FU-HM-A11Y-14）');
    }
  }
  // 「已举报」标签：入口消失后的回焦落点。
  const bar = findStruct(sf, 'AgentFeedbackBar');
  const reported = bar ? textOfKey(bar, 'agent.draft.report.reported') : [];
  if (reported.length !== 1) {
    report('AG4-reported', bar, 'AgentFeedbackBar 找不到唯一的「已举报」Text(this.t(\'agent.draft.report.reported\'))', AC);
  } else {
    const idCall = lastCall(reported[0].calls, 'id');
    if (!idCall || !idCall.args[0] || isConstant(idCall.args[0]) || !focusTrue(reported[0].calls)) {
      report('AG4-reported', reported[0].root, '「已举报」标签应有带回复键的 .id(…) 且 .focusable(true)（读屏入口举报后随之消失，回焦落到本条「已举报」）');
    }
  }
  // 举报半屏 onDisappear 回焦到运行时记下的触发 id。
  const root = findStruct(trSf, 'AgentTabRoot');
  const binds = root ? collect(root, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)
    && n.expression.name.text === 'bindSheet') : [];
  if (binds.length !== 1) { report('AG4-return', root, 'AgentTabRoot 应恰有一个举报 bindSheet（实际 ' + binds.length + '）', TR); return; }
  const opts = binds[0].arguments[2];
  const dis = property(opts, 'onDisappear');
  const handler = dis && ts.isPropertyAssignment(dis) ? unwrap(dis.initializer) : null;
  const calls = [];
  if (isFn(handler)) { for (const b of bodiesOf(handler, root, 0)) { calls.push(...focusCalls(b)); } }
  if (calls.length === 0) {
    report('AG4-return', dis || binds[0], '举报半屏关闭后没有回焦（onDisappear 里没有 CouliFocusReturn.to；FU-HM-A11Y-14）');
    return;
  }
  if (calls.every((c) => isConstant(c.id))) {
    report('AG4-return', calls[0].call, '举报半屏关闭后回焦到固定 id ' + JSON.stringify([...strValues(calls[0].id, 0, null)])
      + '：应回到打开它的那条回复的触发处（读屏入口或长按气泡；已举报时回「已举报」）');
  }
}
function checkTitles() {
  const trSf = parse(TR);
  const cdSf = parse(CD);
  if (trSf) {
    const root = findStruct(trSf, 'AgentTabRoot');
    const sheet = findStruct(trSf, 'AgentReportSheetContent');
    if (root) { titleChecks(root, 'agent.name', 'agent_title', false, TR, '页面标题「AI 助手」'); }
    if (sheet) { titleChecks(sheet, 'agent.draft.report.title', 'agent_report_title', true, TR, '举报半屏标题'); }
  }
  if (cdSf) {
    const panel = findStruct(cdSf, 'AgentConsentPanel');
    if (!panel) { need(CD, '找不到 struct AgentConsentPanel'); return; }
    titleChecks(panel, 'agent.draft.consent.title', 'agent_consent_title', true, CD, '同意弹窗标题');
  }
}

// ---------------------------------------------------------------- AG5：行标识
function nameCarriesTag(arg) {
  const e = unwrap(arg);
  if (!e) { return false; }
  if (ts.isConditionalExpression(e)) { return nameCarriesTag(e.whenTrue) && nameCarriesTag(e.whenFalse); }
  const text = expandedText(e, 0);
  return text.includes('this.replyTag') && text.includes('PriceTerms.comma');
}
function checkRowTag() {
  const sf = parse(AC);
  if (!sf) { return; }
  const bar = findStruct(sf, 'AgentFeedbackBar');
  const turn = findStruct(sf, 'AgentTurnItemView');
  if (!bar || !turn) { need(AC, '找不到 struct AgentFeedbackBar / AgentTurnItemView'); return; }
  const decl = bar.members.find((m) => ts.isPropertyDeclaration(m) && memberName(m) === 'replyTag');
  if (!decl || !decorators(decl).includes('Param') || !decl.type || decl.type.getText() !== 'string') {
    report('AG5-param', decl || bar, 'AgentFeedbackBar 应声明 @Param replyTag: string（本条回复的行标识，FU-HM-A11Y-17）');
  }
  const thumb = methodOf(bar, 'thumb');
  const sites = [];
  if (thumb) {
    for (const c of componentsIn(thumb)) { const t = lastCall(c.calls, 'accessibilityText'); if (t) { sites.push({ what: '赞 / 踩', call: t }); } }
  }
  for (const s of triggerSites(sf).filter((x) => x.kind === 'entry')) {
    const t = lastCall(s.comp.calls, 'accessibilityText');
    if (t) { sites.push({ what: '读屏举报入口「更多操作，举报」', call: t }); }
  }
  if (!sites.some((s) => s.what === '赞 / 踩')) { report('AG5-name', thumb || bar, '赞 / 踩按钮找不到 accessibilityText', AC); }
  if (!sites.some((s) => s.what !== '赞 / 踩')) { report('AG5-name', bar, '读屏举报入口找不到 accessibilityText', AC); }
  for (const s of sites) {
    if (!s.call.args[0] || !nameCarriesTag(s.call.args[0])) {
      report('AG5-name', s.call.node, s.what + '的读屏名应 = 原名 + PriceTerms.comma + this.replyTag（含已赞 / 已踩那一支；每条回复同名分不清是哪条，'
        + 'README ⑬ 不加键）');
    }
  }
  const uses = componentsIn(turn).filter((c) => c.name === 'AgentFeedbackBar');
  if (uses.length === 0) { report('AG5-caller', turn, 'AgentTurnItemView 里找不到 AgentFeedbackBar 调用', AC); }
  for (const u of uses) {
    const p = property(u.args[0], 'replyTag');
    const v = p && ts.isPropertyAssignment(p) ? unwrap(p.initializer) : null;
    if (!v || isConstant(v) || !/AgentReplyTag\.of\(/.test(compact(v)) || !/blocks/.test(compact(v))) {
      report('AG5-caller', p || u.root, 'AgentFeedbackBar 应传 replyTag: AgentReplyTag.of(this.turn.blocks)（本条回复正文摘要，纯函数由逻辑用例钉）');
    }
  }
}

// ---------------------------------------------------------------- AG6：装饰圆点
const BULLET_RE = /^[\s•●◦▪·∙⋅]+$/;
function parentComponentStmt(node) {
  for (let p = node.parent; p; p = p.parent) {
    if (ts.isEtsComponentExpression(p) && p.body) {
      let st = p;
      while (st.parent && !ts.isExpressionStatement(st)) { st = st.parent; }
      return ts.isExpressionStatement(st) ? chainOf(st.expression) : null;
    }
  }
  return null;
}
function checkBullets(scan) {
  for (const rel of scan) {
    const sf = parse(rel);
    if (!sf) { continue; }
    for (const comp of componentsIn(sf)) {
      if (comp.name !== 'Text' || !comp.args[0] || !isStr(unwrap(comp.args[0])) || !BULLET_RE.test(unwrap(comp.args[0]).text)) { continue; }
      const level = lastCall(comp.calls, 'accessibilityLevel');
      const lv = level && level.args[0] ? constId(level.args[0]) : null;
      if (lv === 'no' || lv === 'no-hide-descendants') { continue; }
      const parent = parentComponentStmt(comp.root);
      const grouped = parent && parent.calls.some((c) => c.name === 'accessibilityGroup' && c.args[0]
        && unwrap(c.args[0]).kind === ts.SyntaxKind.TrueKeyword);
      const ptext = parent ? lastCall(parent.calls, 'accessibilityText') : null;
      if (grouped && ptext && ptext.args[0] && !/[•●◦▪·∙⋅]/.test(expandedText(ptext.args[0], 0))) { continue; }
      report('AG6-bullet', comp.root, '装饰圆点 Text(' + unwrap(comp.args[0]).getText() + ') 没对读屏隐藏（应 .accessibilityLevel(\'no\')，'
        + '或所在行成组且行读屏名不含圆点；FU-HM-A11Y-18）');
    }
  }
}

// ---------------------------------------------------------------- 主流程
for (const rel of [PC, AC, TR, CD, DT].concat(input.scan || [])) { parse(rel); }
if (incomplete.length === 0) {
  const drafts = draftTexts();
  checkProductCard();
  checkAiCard();
  checkLabels(drafts);
  checkTitles();
  checkConsentReturn();
  checkReport();
  checkRowTag();
  checkBullets(input.scan || []);
}
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete }));
