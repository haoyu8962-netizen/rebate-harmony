#!/usr/bin/env node
// HM-L2-PRODUCT-CELL 宿主守卫的解析部分（书 brief-PRODUCT-CELL.md §3「结构」P1–P5；README 末节编排裁定 D10-1177 ⑥ 与 FREEZE 集成备忘；
// 测试作者 v1，新鲜独立 Claude，先红）。由 check_l2_cell.py 调用，不单独跑。用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS，判定全部走 AST，
// 注释与字符串里的字不算。写法照 tools/ci/l2button/l2button_ast.cjs、tools/ci/l2card/l2card_ast.cjs。
//   用法：node l2cell_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>"}, "scan": ["<页面候选相对路径>", ...]}
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."], "facts": {...}}
//
// 核心做法：从 ProductCard.build() 出发，对每个 (variant ∈ LIST / AI / GRID / LARGE) × (openable ∈ false / true) 做一次「可达界面」遍历：
// 只认 this.variant === ProductCardVariant.X、this.openable 及其 ! / && / || 组合（含只 return 一个表达式的无参方法），其余条件两支都走
// （保守）；@Builder 方法调用跟进去；记下每个组件调用及其所处的「读屏组」「CouliCard 外壳」上下文。规则都在这些事件上判：
//   P1 外壳：卡壳经 CouliCard（无内联 shadow(CouliShadow.card) / backgroundSurface / radius.card）；openable=true 时 LIST / AI / GRID 有
//      CouliCard TAPPABLE（press BOUNCE、onTap 调 this.onOpen()）；网格 inset 透传；@Param openable = false / @Event onOpen 声明。
//   P2 不吞点击：openable=false 时每个可达 CouliCard 的 kind 静态求值恰为 STATIC（求值不了算红）；整个 ProductCard.ets 不得出现
//      onClick / onTouch / 手势 / clickEffect / stateStyles / CouliPressable（按压只能经 CouliCard 可点版、且受 openable 管）；
//      页面（features/*/src/main、entry/src/main）调用 ProductCard 不传 openable / onOpen（README ⑥ 页面零改动，流程单再切换）。
//   P3 预估返后：LIST / AI / GRID 可达界面无 EstNetLine、不读 estNet；LARGE 保留 EstNetLine（详情归 HM-FLOW-DETAIL / U2）。
//   P4 读屏：LIST / AI / GRID 的 CouliCard 传 groupAccessibility: false；信息区是 .accessibilityGroup(true) +
//      .accessibilityText(ProductCardA11y.cellLabel(this.data))（可经无参 this.m() 转一手）；标题、PriceTag、RebateTag、价格不可用提示都在
//      这个组里；BuyButton 不在任何读屏组里；口径 i（DisclaimerFooter / gridInfo / 带 lines 的 GridRebateBlock）不在信息组里；
//      组外的 GridRebateBlock 传 spoken: false（返利已在组读屏名里，不重读）。
//      P4-nobutton（HM-BATCH1-DEVFIX swap3，编排 D10-1296，#24 只加）：信息组里不得有任何按钮 / 可点组件（不只购买按钮与口径 i；
//      含与购买按钮同文字的非购买按钮、经 @Builder / 同文件 struct 间接放进去的）。组整体读一项，组内按钮读屏够不着，设备读屏
//      项数判据看不出（swap2 §3.3 / 复核 S2-1），只能由宿主结构管。读屏口径（cellLabel、组的划分）不动。
//      测试 v3（swap3 复核 S2-1，#24 只加）：可达遍历另展开 Repeat(...).each / .template 的子树与 @LocalBuilder 方法（原来只展开
//      ForEach / LazyForEach 与 @Builder），经这两种 V2 写法塞进信息组的按钮 P4-nobutton / P4-buy 同样要红。
//   P5 无触感；图片段（image 构建方法）与基线逐字节相同（批 2 PRODUCT-IMAGE 再动）。
//   P7 隐私接线（BUTTON 评审 r1 S3-1，与 l2button B5-hidden 同口径、在新卡结构下再钉一次）：ProductCard.ets 里每个 BuyButton 的 rebate
//      解析到未遮罩的 this.data.rebate、amountHidden 解析到 this.data.amountHidden；按钮 onTap 只回调 onBuy、不碰 onOpen。
//   P8 目录：CatalogSampleViews 里有传 openable / onOpen 的 ProductCard 样例、页面外层点击模拟（同 struct 有 .onClick）、
//      catalog-events/ProductCard 计数 id。
//   P9 登记：designsystem List.test.ets 登记 l2ProductCellTest；Ds02L2Ui 的 cell 段（段函数、常量下标注册、段边界分支）。
'use strict';
const fs = require('fs');
const path = require('path');

const PRODUCT = 'common/designsystem/src/main/ets/components/ProductCard.ets';
const SAMPLES = 'entry/src/staging/ets/catalog/CatalogSampleViews.ets';
const DS_LIST = 'common/designsystem/src/test/List.test.ets';
const SUITE = 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets';
const FILES = [PRODUCT, SAMPLES, DS_LIST, SUITE];

const tsDir = process.argv[2];
if (!tsDir) { console.error('l2cell_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('l2cell_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('l2cell_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
    process.exit(3);
  }
  return { ets: cfg.compilerOptions.ets, etsLoaderPath: path.dirname(cfgPath) };
}
const ETS_OPTIONS = etsOptions();

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const violations = [];
const incomplete = [];
const facts = {};
const parsed = new Map();

function parse(rel) {
  if (parsed.has(rel)) { return parsed.get(rel); }
  const text = input.files[rel];
  if (text === undefined || text === null) {
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
const seen = new Set();
function report(rule, node, msg, file) {
  const f = file || (node ? node.getSourceFile().fileName : '');
  const line = node ? lineOf(node) : 0;
  const key = rule + '|' + f + '|' + line + '|' + msg;
  if (seen.has(key)) { return; }
  seen.add(key);
  violations.push({ rule: rule, file: f, line: line, msg: msg });
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
function findStruct(sf, name) { return sf.statements.find((s) => ts.isStructDeclaration(s) && s.name && s.name.text === name) || null; }
function findClass(sf, name) { return sf.statements.find((s) => ts.isClassDeclaration(s) && s.name && s.name.text === name) || null; }
function methodOf(owner, name) {
  return owner.members.find((m) => ts.isMethodDeclaration(m) && memberName(m) === name) || null;
}
function decorators(m) {
  const list = (ts.getAllDecorators ? ts.getAllDecorators(m) : (m.decorators || [])) || [];
  return list.map((d) => d.expression.getText());
}
function isThis(e) { return e && e.kind === ts.SyntaxKind.ThisKeyword; }
/** this.m() 的方法名（无参或有参都认）；不是返回 null。 */
function thisCallName(e) {
  e = unwrap(e);
  if (e && ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression) && isThis(e.expression.expression)) {
    return e.expression.name.text;
  }
  return null;
}
function property(obj, name) {
  if (!obj || !ts.isObjectLiteralExpression(obj)) { return null; }
  return obj.properties.find((p) => ts.isPropertyAssignment(p) && memberName(p) === name) || null;
}
/** 属性链拆成 { root, calls: [{ name, args, node }] }（calls 按书写顺序）；this.m() 是根，不当属性。 */
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
  if (ts.isEtsComponentExpression(root)) { return root.expression.getText(); }
  if (ts.isCallExpression(root) && ts.isIdentifier(root.expression)) { return root.expression.text; }
  return null;
}

// ---------------------------------------------------------------- 静态求值（三值：true / false / null = 不知道）
const VARIANTS = { LIST: 'LIST', AI: 'AI', GRID: 'GRID', LARGE: 'LARGE' };

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
      const rets = returnsOf(m.body, env, owner, depth + 1);
      if (rets.length === 0) { return null; }
      const vals = rets.map((r) => evalBool(r, env, owner, depth + 1));
      if (vals.every((v) => v === true)) { return true; }
      if (vals.every((v) => v === false)) { return false; }
    }
  }
  return null;
}
/** 方法体里按 env 可达的 return 表达式（if 能判的剪枝，判不了两支都收）。 */
function returnsOf(block, env, owner, depth) {
  const out = [];
  function visit(stmts) {
    for (const s of stmts) {
      if (ts.isReturnStatement(s)) { if (s.expression) { out.push(s.expression); } return true; }
      if (ts.isIfStatement(s)) {
        const c = evalBool(s.expression, env, owner, depth + 1);
        let thenEnds = false;
        let elseEnds = false;
        if (c !== false) { thenEnds = visit(ts.isBlock(s.thenStatement) ? s.thenStatement.statements : [s.thenStatement]); }
        if (c !== true && s.elseStatement) {
          elseEnds = visit(ts.isBlock(s.elseStatement) ? s.elseStatement.statements : [s.elseStatement]);
        }
        if (c === true && thenEnds) { return true; }
        if (c === false && elseEnds) { return true; }
        if (c === null && thenEnds && elseEnds) { return true; }
        continue;
      }
      if (ts.isBlock(s)) { if (visit(s.statements)) { return true; } continue; }
      // 其他语句里若藏 return（switch / 循环），保守全收。
      for (const r of collect(s, (n) => ts.isReturnStatement(n))) { if (r.expression) { out.push(r.expression); } }
    }
    return false;
  }
  visit(block.statements);
  return out;
}
/** 本函数里名为 name 的局部变量初始化式（只认唯一的一处声明）。 */
function enclosingFunction(node) {
  for (let p = node.parent; p; p = p.parent) {
    if (ts.isFunctionLike(p) && p.body) { return p; }
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
/** CouliCard 的 kind 可能取值：集合含 'STATIC' / 'TAPPABLE' / '?'（求值不了）。 */
function evalKind(expr, env, owner, depth) {
  const e = unwrap(expr);
  if (!e || depth > 8) { return new Set(['?']); }
  const t = compact(e);
  if (t === 'CouliCardKind.STATIC') { return new Set(['STATIC']); }
  if (t === 'CouliCardKind.TAPPABLE') { return new Set(['TAPPABLE']); }
  if (ts.isConditionalExpression(e)) {
    const c = evalBool(e.condition, env, owner, depth + 1);
    if (c === true) { return evalKind(e.whenTrue, env, owner, depth + 1); }
    if (c === false) { return evalKind(e.whenFalse, env, owner, depth + 1); }
    const s = evalKind(e.whenTrue, env, owner, depth + 1);
    for (const k of evalKind(e.whenFalse, env, owner, depth + 1)) { s.add(k); }
    return s;
  }
  if (ts.isIdentifier(e)) {
    const init = localInit(e, e.text);
    return init ? evalKind(init, env, owner, depth + 1) : new Set(['?']);
  }
  const name = thisCallName(e);
  if (name !== null && owner && e.arguments.length === 0) {
    const m = methodOf(owner, name);
    if (m && m.body && m.parameters.length === 0) {
      const rets = returnsOf(m.body, env, owner, depth + 1);
      if (rets.length === 0) { return new Set(['?']); }
      const s = new Set();
      for (const r of rets) { for (const k of evalKind(r, env, owner, depth + 1)) { s.add(k); } }
      return s;
    }
  }
  return new Set(['?']);
}
/** expr 是否「就是」want：原样；或同 struct 无参方法 this.m() 且其每个 return 都是 want；或唯一局部常量其初值是 want。 */
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
    const returns = collect(m.body, (n) => ts.isReturnStatement(n));
    return returns.length > 0 && returns.every((r) => r.expression && resolvesTo(r.expression, want, owner, depth + 1));
  }
  return false;
}
/** expr 是否经由 CardAmountMask 遮罩（直接出现；或经 this.m() / 局部变量间接得到）。同 l2button_ast.cjs maskedRebate。 */
function maskedRebate(expr, owner, depth) {
  const e = unwrap(expr);
  if (!e || depth > 6) { return false; }
  if (collect(e, (n) => ts.isIdentifier(n) && n.text === 'CardAmountMask').length > 0) { return true; }
  for (const id of collect(e, (n) => ts.isIdentifier(n) && !(ts.isPropertyAccessExpression(n.parent) && n.parent.name === n))) {
    const init = localInit(id, id.text);
    if (init && maskedRebate(init, owner, depth + 1)) { return true; }
  }
  for (const call of collect(e, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && isThis(n.expression.expression))) {
    const m = owner ? methodOf(owner, call.expression.name.text) : null;
    if (m && m.body && collect(m.body, (n) => ts.isReturnStatement(n)).some((r) => r.expression && maskedRebate(r.expression, owner, depth + 1))) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------- 可达界面遍历
const CELL_LABEL = 'ProductCardA11y.cellLabel(this.data)';

/** 从 build() 起，按 env 收集可达的组件 / 构建方法事件。事件：{ kind: 'comp' | 'builder', name, node, args, ctx, attrs }。 */
function reach(owner, env) {
  const events = [];
  const build = methodOf(owner, 'build');
  if (!build || !build.body) { return events; }
  const builders = new Map();
  for (const m of owner.members) {
    if (ts.isMethodDeclaration(m) && m.body && decorators(m).includes('Builder')) { builders.set(memberName(m), m); }
    // HM-BATCH1-DEVFIX 测试 v3（swap3 复核 S2-1，#24 只加）：@LocalBuilder 方法（V2 常用写法）同 @Builder 跟进去。
    if (ts.isMethodDeclaration(m) && m.body && decorators(m).includes('LocalBuilder')) { builders.set(memberName(m), m); }
  }
  function visitStatements(stmts, ctx, stack) {
    for (const s of stmts) { visitStatement(s, ctx, stack); }
  }
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
      events.push({ kind: 'builder', name: bname, node: root, args: root.arguments, ctx: ctx, attrs: calls });
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
      const off = arg && arg.kind === ts.SyntaxKind.FalseKeyword;
      if (!off) {
        const textCall = calls.find((c) => c.name === 'accessibilityText');
        const cell = !!(textCall && textCall.args[0] && resolvesTo(textCall.args[0], CELL_LABEL, owner, 0));
        next = Object.assign({}, next, { groups: next.groups.concat([{ node: root, cell: cell }]) });
      }
    }
    if (name === 'CouliCard') {
      const opts = ev.args[0];
      const kindProp = property(opts, 'kind');
      ev.cardKinds = kindProp ? evalKind(kindProp.initializer, env, owner, 0) : new Set(['STATIC']);
      next = Object.assign({}, next, { cards: next.cards.concat([ev]) });
    }
    if (name === 'ForEach' || name === 'LazyForEach') {
      const fn = ev.args[1];
      if (fn && (ts.isArrowFunction(fn) || ts.isFunctionExpression(fn)) && fn.body && ts.isBlock(fn.body)) {
        visitStatements(fn.body.statements, next, stack);
      }
      return;
    }
    // HM-BATCH1-DEVFIX 测试 v3（swap3 复核 S2-1，#24 只加）：Repeat(...).each(fn) / .template(type, fn) 的子树照 ForEach 展开
    // （箭头函数块体或表达式体都认）；其它链上调用（key / templateId / virtualScroll 等）不含子组件。
    if (name === 'Repeat') {
      for (const c of calls) {
        const fn = c.name === 'each' ? c.args[0] : (c.name === 'template' ? c.args[1] : null);
        if (!fn || !(ts.isArrowFunction(fn) || ts.isFunctionExpression(fn)) || !fn.body) { continue; }
        if (ts.isBlock(fn.body)) { visitStatements(fn.body.statements, next, stack); } else { visitExpression(fn.body, next, stack); }
      }
      return;
    }
    if (ts.isEtsComponentExpression(root) && root.body && ts.isBlock(root.body)) {
      visitStatements(root.body.statements, next, stack);
    }
  }
  visitStatements(build.body.statements, { groups: [], cards: [] }, ['build']);
  return events;
}

// ---------------------------------------------------------------- 图片段基线（eb9db90 / 2139368 ProductCard.ets:241-269，批 2 PRODUCT-IMAGE 前不得改）
const IMAGE_BASELINE = [
  '@Builder',
  '  image(size: Length) {',
  '    Stack() {',
  '      if (ProductCardA11y.showsPlaceholder(this.data.imageUrl, this.imageLoaded, this.imageFailed)) {',
  '        Text(this.data.imageLabel)',
  '          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))',
  '      }',
  '      if (this.data.imageUrl.length > 0 && !this.imageFailed) {',
  '        Image(this.data.imageUrl)',
  "          .width('100%')",
  "          .height('100%')",
  '          .objectFit(ImageFit.Cover)',
  '          .draggable(false)',
  '          .onComplete(() => {',
  '            this.imageLoaded = true;',
  '          })',
  '          .onError(() => {',
  '            this.imageFailed = true;',
  '          })',
  '      }',
  '    }',
  '    .width(size)',
  '    .aspectRatio(1)',
  '    .clip(true)',
  '    .backgroundColor(CouliColors.backgroundPlaceholder)',
  '    .border({ width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderSubtle })',
  '    .borderRadius(CouliRadius.small)',
  "    .accessibilityLevel('no')",
  '  }'
].join('\n');

const PRESS_ATTRS = ['onClick', 'onTouch', 'gesture', 'priorityGesture', 'parallelGesture', 'clickEffect', 'stateStyles', 'onHover'];
const PRESS_IDS = ['TapGesture', 'LongPressGesture', 'PanGesture', 'SwipeGesture', 'PinchGesture', 'RotationGesture', 'GestureGroup',
  'CouliPressable'];

// P4-nobutton（HM-BATCH1-DEVFIX swap3，编排 D10-1296，#24 只加）：信息组里的按钮 / 可点组件。
// 名字以 Button（或 ButtonV2 等）结尾的组件一律算按钮（Button / BuyButton / CouliButton / CouliIconButton / TabSegmentButtonV2）；
// 另列系统可点控件与 designsystem 里内含 Button / Toggle / Checkbox / onClick 的组件（61421dc 逐个 grep 核过）。
const BUTTON_NAME = /Button(V\d+)?$/;
const BUTTON_COMPS = ['Toggle', 'Checkbox', 'CheckboxGroup', 'Radio', 'Select', 'CouliPressable', 'DisclaimerFooter', 'CouliCheckbox',
  'CouliCheckboxRow', 'CouliRadio', 'CouliSwitch', 'FilterChip', 'Segmented', 'ListRow', 'DisclosureRow', 'AmountGrid', 'WalletHeroCard',
  'EntryGrid'];
function isButtonName(name) { return BUTTON_NAME.test(name) || BUTTON_COMPS.includes(name); }
/** 组件事件 e 是不是（或内含）按钮：返回命中的组件名，否则 null。同文件 struct / 顶层函数（全局 @Builder）按语法全扫（保守）；
 *  GridRebateBlock 同 P4-buy 口径：lines 不是 [] 时内含口径 i 按钮。 */
function buttonIn(sf, e, stack) {
  if (isButtonName(e.name)) { return e.name; }
  if (e.name === 'GridRebateBlock') {
    const lines = property(e.args && e.args[0], 'lines');
    return !lines || compact(lines.initializer) !== '[]' ? 'GridRebateBlock（带口径 i）' : null;
  }
  if (stack.includes(e.name)) { return null; }
  const decl = sf.statements.find((s) => (ts.isStructDeclaration(s) || ts.isFunctionDeclaration(s)) && s.name && s.name.text === e.name);
  if (!decl) { return null; }
  for (const n of collect(decl, (x) => ts.isEtsComponentExpression(x) || (ts.isCallExpression(x) && ts.isIdentifier(x.expression)))) {
    const name = componentName(n);
    if (name === null) { continue; }
    const hit = buttonIn(sf, { name: name, args: n.arguments || [] }, stack.concat([e.name]));
    if (hit !== null) { return e.name + ' 内的 ' + hit; }
  }
  return null;
}

function checkProductCard() {
  const sf = parse(PRODUCT);
  if (!sf) { return; }
  const owner = findStruct(sf, 'ProductCard');
  if (!owner) { report('P1-decl', null, 'ProductCard.ets 找不到 struct ProductCard', PRODUCT); return; }

  // P1-decl：@Param openable: boolean = false、@Event onOpen: () => void（README ⑥ / D10-1177）。
  const openable = owner.members.find((m) => ts.isPropertyDeclaration(m) && memberName(m) === 'openable');
  if (!openable || !decorators(openable).includes('Param') || !openable.type || openable.type.getText() !== 'boolean'
    || !openable.initializer || openable.initializer.kind !== ts.SyntaxKind.FalseKeyword) {
    report('P1-decl', openable || owner, 'ProductCard 应声明 @Param openable: boolean = false（默认不可点，页面零改动，README ⑥）');
  }
  const onOpen = owner.members.find((m) => ts.isPropertyDeclaration(m) && memberName(m) === 'onOpen');
  if (!onOpen || !decorators(onOpen).includes('Event') || !onOpen.type || compact(onOpen.type) !== '()=>void') {
    report('P1-decl', onOpen || owner, 'ProductCard 应声明 @Event onOpen: () => void（整卡打开回调，README ⑥）');
  }

  // P1-inline：外壳的白底 / 圆角 / 阴影只来自 CouliCard（书 §2.1「去掉三处内联底 / 圆角 / 阴影」）。
  for (const n of collect(owner, (x) => ts.isPropertyAccessExpression(x)
    && ['CouliShadow.card', 'CouliColors.backgroundSurface', 'CouliRadius.card'].includes(compact(x)))) {
    report('P1-inline', n, 'ProductCard 仍内联卡片外壳 ' + compact(n) + '（应由 CouliCard 画白底 / 圆角 / 阴影）');
  }
  for (const n of collect(owner, (x) => ts.isIdentifier(x) && x.text === 'CouliShadow')) {
    if (!(ts.isPropertyAccessExpression(n.parent) && compact(n.parent) === 'CouliShadow.card')) {
      report('P1-inline', n, 'ProductCard 引用 CouliShadow（卡片阴影应由 CouliCard 给）');
    }
  }

  // P2-click：整个文件不接按压 / 点击（防吞页面外层 .onClick：SearchView / HomeCards / ClipboardViews，书 §7）。
  for (const n of collect(sf, (x) => ts.isCallExpression(x) && ts.isPropertyAccessExpression(x.expression)
    && PRESS_ATTRS.includes(x.expression.name.text) && !isThis(x.expression.expression))) {
    report('P2-click', n, 'ProductCard.ets 出现 .' + n.expression.name.text + '(（组件内接点击 / 按压会吞掉页面外层 .onClick；整卡按压只经 CouliCard 可点版、受 openable 管）');
  }
  for (const n of collect(sf, (x) => ts.isIdentifier(x) && PRESS_IDS.includes(x.text)
    && !(ts.isImportSpecifier(x.parent)))) {
    report('P2-click', n, 'ProductCard.ets 出现 ' + n.text + '（同上：不得自接手势 / CouliPressable）');
  }

  // P5-haptics：外跳不加触感（README §3.2）。
  for (const n of collect(sf, (x) => ts.isIdentifier(x) && ['CouliHaptics', 'vibrator'].includes(x.text))) {
    report('P5-haptics', n, 'ProductCard.ets 出现 ' + n.text + '（外跳不加触感，README §3.2）');
  }
  for (const s of sf.statements.filter((x) => ts.isImportDeclaration(x) && isStr(x.moduleSpecifier)
    && (/CouliHaptics$/.test(x.moduleSpecifier.text) || x.moduleSpecifier.text === '@kit.SensorServiceKit'))) {
    report('P5-haptics', s, 'ProductCard.ets import ' + s.moduleSpecifier.text + '（外跳不加触感）');
  }
  // P5-image：图片段逐字节不变。
  const image = methodOf(owner, 'image');
  if (!image || image.getText() !== IMAGE_BASELINE) {
    report('P5-image', image || owner, 'ProductCard 的 image 构建方法与基线（2139368 ProductCard.ets:241-269）不再逐字节相同（图片段归批 2 PRODUCT-IMAGE，本单不动）');
  }

  // P4-fn：ProductCardA11y.cellLabel(data) 存在（纯函数，L2ProductCell.test.ets 钉行为）。
  const a11y = findClass(sf, 'ProductCardA11y');
  const cellFn = a11y ? a11y.members.find((m) => ts.isMethodDeclaration(m) && memberName(m) === 'cellLabel') : null;
  if (!cellFn || !(cellFn.modifiers || []).some((x) => x.kind === ts.SyntaxKind.StaticKeyword) || cellFn.parameters.length !== 1
    || !cellFn.type || cellFn.type.getText() !== 'string') {
    report('P4-fn', cellFn || a11y, 'ProductCardA11y 应有 static cellLabel(data: ProductCardData): string（信息区整块读屏名「平台，标题，价格，返利」）', PRODUCT);
  }

  // 可达界面：4 变体 × openable 两值。
  for (const variant of Object.keys(VARIANTS)) {
    for (const open of [false, true]) {
      const env = { variant: variant, openable: open };
      const tag = variant + (open ? ' openable=true' : ' openable=false');
      const events = reach(owner, env);
      const comps = (name) => events.filter((e) => e.kind === 'comp' && e.name === name);
      const builds = (name) => events.filter((e) => e.kind === 'builder' && e.name === name);
      const cards = comps('CouliCard');
      const titles = builds('title');

      // P1-shell：外壳经 CouliCard，标题在卡里。
      if (cards.length === 0) { report('P1-shell', owner, tag + '：可达界面里没有 CouliCard 外壳（书 §2.1：外壳换 CouliCard）'); }
      for (const t of titles) {
        if (t.ctx.cards.length === 0) { report('P1-shell', t.node, tag + '：标题不在 CouliCard 里（外壳没包住整卡内容）'); }
      }
      // P2-static：openable=false 时每个可达 CouliCard 只能是 STATIC。
      if (!open) {
        for (const c of cards) {
          const ks = [...c.cardKinds];
          if (!(ks.length === 1 && ks[0] === 'STATIC')) {
            report('P2-static', c.node, tag + '：CouliCard 的 kind 可能取 ' + ks.join(' / ').replace('?', '（无法静态判定）')
              + '，openable=false 时必须恰为 CouliCardKind.STATIC（否则组件内接了按压，吞掉页面外层 .onClick）');
          }
        }
      }
      if (variant !== 'LARGE') {
        // P1-tap：openable=true 时整卡可点、回调 onOpen、BOUNCE。
        if (open) {
          const taps = cards.filter((c) => c.cardKinds.size === 1 && c.cardKinds.has('TAPPABLE'));
          if (taps.length === 0) {
            report('P1-tap', cards[0] ? cards[0].node : owner, tag + '：openable=true 时没有 kind 恰为 TAPPABLE 的 CouliCard（整卡按压用 CouliCard 可点版）');
          }
          for (const c of taps) {
            const opts = c.args[0];
            const onTap = property(opts, 'onTap');
            const fn = onTap ? unwrap(onTap.initializer) : null;
            const callsOpen = fn && (ts.isArrowFunction(fn) || ts.isFunctionExpression(fn))
              && collect(fn.body, (n) => ts.isCallExpression(n) && compact(n.expression) === 'this.onOpen').length === 1
              && collect(fn.body, (n) => ts.isCallExpression(n) && compact(n.expression) === 'this.onBuy').length === 0;
            if (!callsOpen) { report('P1-tap', onTap || c.node, tag + '：可点 CouliCard 的 onTap 应恰调用一次 this.onOpen()（且不调 onBuy）'); }
            const press = property(opts, 'press');
            if (press && compact(press.initializer) !== 'PressKind.BOUNCE') {
              report('P1-tap', press, tag + '：整卡按压应为 PressKind.BOUNCE（书 §2.1），实际 ' + press.initializer.getText());
            }
            const disabled = property(opts, 'disabled');
            if (disabled && compact(disabled.initializer) !== 'false') {
              report('P1-tap', disabled, tag + '：可点卡不应传 disabled（' + disabled.initializer.getText() + '）');
            }
          }
        }
        // P1-inset：网格卡 inset 透传给 CouliCard（段卡里无底、无阴影）。
        if (variant === 'GRID') {
          for (const c of cards) {
            const inset = property(c.args[0], 'inset');
            if (!inset || !resolvesTo(inset.initializer, 'this.inset', owner, 0)) {
              report('P1-inset', inset || c.node, tag + '：网格卡的 CouliCard 应传 inset: this.inset（首页段卡里平铺，H11 / H-V08）');
            }
          }
        }
        // P3-list：列表 / AI / 网格卡不显示预估返后（DETAIL-V3 U1）。
        for (const e of comps('EstNetLine')) {
          report('P3-list', e.node, tag + '：可达界面仍有 EstNetLine（U1：列表卡、AI 卡、网格卡不显示「预估返后」）');
        }
        for (const e of events) {
          for (const a of e.args || []) {
            for (const n of collect(a, (x) => ts.isPropertyAccessExpression(x) && (compact(x) === 'this.estNet' || compact(x) === 'this.data.estNet'))) {
              report('P3-list', n, tag + '：可达界面读 ' + compact(n) + '（U1：不显示预估返后）');
            }
          }
        }
        // P4-group：卡片外壳不把内容合成一个读屏组（否则购买按钮被吞）。
        for (const c of cards) {
          const g = property(c.args[0], 'groupAccessibility');
          if (!g || unwrap(g.initializer).kind !== ts.SyntaxKind.FalseKeyword) {
            report('P4-group', g || c.node, tag + '：CouliCard 应传 groupAccessibility: false（卡里有单独可聚焦的购买按钮，F-HM-98；读屏组只放信息区）');
          }
        }
        // P4-info：信息区读屏合一项。
        const cellGroups = events.filter((e) => e.kind === 'comp' && e.attrs.some((c) => c.name === 'accessibilityGroup')
          && e.attrs.some((c) => c.name === 'accessibilityText' && c.args[0] && resolvesTo(c.args[0], CELL_LABEL, owner, 0))
          && e.attrs.some((c) => c.name === 'accessibilityGroup' && c.args[0] && unwrap(c.args[0]).kind === ts.SyntaxKind.TrueKeyword));
        if (cellGroups.length === 0) {
          report('P4-info', owner, tag + '：没有信息区读屏组（.accessibilityGroup(true) + .accessibilityText(' + CELL_LABEL + ')）');
        }
        const inCell = (e) => e.ctx.groups.some((g) => g.cell);
        const mustIn = titles.concat(comps('PriceTag'), comps('RebateTag'), builds('unavailableNote'), builds('priceBlock'));
        for (const e of mustIn) {
          if (!inCell(e)) {
            report('P4-info', e.node, tag + '：' + (e.kind === 'builder' ? 'this.' + e.name + '()' : e.name) + ' 不在信息区读屏组里（会被单独读出 / 重读；200% 时 widePrice 分支也要在组里）');
          }
        }
        // P4-buy：购买按钮单独一项，不进任何读屏组；口径 i 不进信息组。
        for (const e of comps('BuyButton').concat(builds('buyButton'))) {
          if (e.ctx.groups.length > 0) {
            report('P4-buy', e.node, tag + '：购买按钮在读屏组里（应单独一项，书 §2.3）');
          }
        }
        for (const e of comps('DisclaimerFooter').concat(builds('gridInfo'))) {
          if (inCell(e)) { report('P4-buy', e.node, tag + '：口径 i 在信息区读屏组里（i 是按钮，组会把它吞掉）'); }
        }
        for (const e of comps('GridRebateBlock')) {
          if (inCell(e)) {
            const lines = property(e.args[0], 'lines');
            if (!lines || compact(lines.initializer) !== '[]') {
              report('P4-buy', e.node, tag + '：带口径 i 的 GridRebateBlock 在信息区读屏组里（i 会被吞掉）');
            }
          } else {
            const spoken = property(e.args[0], 'spoken');
            if (!spoken || unwrap(spoken.initializer).kind !== ts.SyntaxKind.FalseKeyword) {
              report('P4-rebate', spoken || e.node, tag + '：信息组外的 GridRebateBlock 应传 spoken: false（返利已在信息区读屏名里，不重读）');
            }
          }
        }
        // P4-nobutton（HM-BATCH1-DEVFIX swap3，编排 D10-1296，#24 只加）：信息区读屏组里不得有任何按钮 / 可点组件。
        for (const e of events) {
          if (e.kind !== 'comp' || !inCell(e)) { continue; }
          const hit = buttonIn(sf, e, []);
          if (hit !== null) {
            report('P4-nobutton', e.node, tag + '：信息区读屏组里有按钮 / 可点组件 ' + hit + '（组合成一项，组内按钮读屏够不着、'
              + '设备读屏项数也看不出；按钮一律放组外，D10-1296）');
          }
        }
      } else {
        // P3-large：详情大卡保留预估返后（归 HM-FLOW-DETAIL / U2，书 §2.2）。
        if (comps('EstNetLine').length === 0) {
          report('P3-large', owner, tag + '：详情大卡不再有 EstNetLine（LARGE 的预估返后本单不动，归 HM-FLOW-DETAIL）');
        }
      }
    }
  }

  // P7-hidden：BuyButton 吃未遮罩返利与真开关；按钮只回调 onBuy。
  const buys = collect(sf, (n) => (ts.isEtsComponentExpression(n) || ts.isCallExpression(n)) && n.expression.getText() === 'BuyButton'
    && n.arguments && n.arguments.length > 0);
  if (buys.length === 0) { report('P7-hidden', owner, 'ProductCard.ets 里找不到 BuyButton('); }
  for (const b of buys) {
    let o = null;
    for (let p = b.parent; p; p = p.parent) { if (ts.isStructDeclaration(p) || ts.isClassDeclaration(p)) { o = p; break; } }
    const opts = b.arguments[0];
    if (!ts.isObjectLiteralExpression(opts)) { report('P7-hidden', b, 'BuyButton 实参不是对象字面量，无法判定'); continue; }
    const rebate = property(opts, 'rebate');
    if (!rebate || !resolvesTo(rebate.initializer, 'this.data.rebate', o, 0)) {
      const why = rebate && maskedRebate(rebate.initializer, o, 0)
        ? '（这是 CardAmountMask 遮罩后的返利，卡内 this.rebate() 就是它：BuyButtonModel 拿「****」比动词，金额隐藏回落静默失效，按钮露出「购买预估返 ¥x」；BUTTON 评审 r1 S3-1 / M5）' : '';
      report('P7-hidden', rebate || b, 'BuyButton 的 rebate 应是未遮罩的 this.data.rebate，实际 ' + (rebate ? rebate.initializer.getText() : '缺') + why);
    }
    const hidden = property(opts, 'amountHidden');
    if (!hidden || !resolvesTo(hidden.initializer, 'this.data.amountHidden', o, 0)) {
      report('P7-hidden', hidden || b, 'BuyButton 的 amountHidden 应是 this.data.amountHidden（D10-871 按 ② 读），实际 ' + (hidden ? hidden.initializer.getText() : '缺'));
    }
    const onTap = property(opts, 'onTap');
    const fn = onTap ? unwrap(onTap.initializer) : null;
    const ok = fn && (ts.isArrowFunction(fn) || ts.isFunctionExpression(fn))
      && collect(fn.body, (n) => ts.isIdentifier(n) && n.text === 'onOpen').length === 0
      && collect(fn.body, (n) => ts.isCallExpression(n) && compact(n.expression) === 'this.onBuy').length === 1;
    if (!ok) { report('P7-buy', onTap || b, 'BuyButton 的 onTap 应只回调 this.onBuy()、不碰 onOpen（点购买不得触发整卡打开）'); }
  }
}

// ---------------------------------------------------------------- P2-page 页面零改动
function checkPages() {
  for (const rel of input.scan || []) {
    const sf = parse(rel);
    if (!sf) { continue; }
    for (const c of collect(sf, (n) => (ts.isEtsComponentExpression(n) || ts.isCallExpression(n)) && n.expression.getText() === 'ProductCard'
      && n.arguments && n.arguments[0] && ts.isObjectLiteralExpression(n.arguments[0]))) {
      for (const name of ['openable', 'onOpen']) {
        const prop = property(c.arguments[0], name);
        if (prop) {
          report('P2-page', prop, '页面给 ProductCard 传了 ' + name + '（README ⑥：本单页面零改动，3 处页面外层 .onClick 照旧；切换归 FLOW-HOME / SEARCH）');
        }
      }
    }
  }
}

// ---------------------------------------------------------------- P8 目录样例
function checkCatalog() {
  const sf = parse(SAMPLES);
  if (!sf) { return; }
  const cards = collect(sf, (n) => (ts.isEtsComponentExpression(n) || ts.isCallExpression(n)) && n.expression.getText() === 'ProductCard'
    && n.arguments && n.arguments[0] && ts.isObjectLiteralExpression(n.arguments[0]));
  const openables = cards.filter((c) => property(c.arguments[0], 'openable') && property(c.arguments[0], 'onOpen'));
  if (openables.length === 0) {
    report('P8-catalog', null, '目录 ProductCard 样例没有传 openable / onOpen（目录要能看整卡按压、数 onOpen，设备 l2cell_ 用例前提）', SAMPLES);
  }
  const owners = new Set();
  for (const c of cards) {
    for (let p = c.parent; p; p = p.parent) { if (ts.isStructDeclaration(p)) { owners.add(p); break; } }
  }
  const outer = [...owners].some((o) => collect(o, (x) => ts.isCallExpression(x) && ts.isPropertyAccessExpression(x.expression)
    && x.expression.name.text === 'onClick').length > 0);
  if (!outer) {
    report('P8-catalog', null, '目录 ProductCard 样例所在 struct 没有外层 .onClick（favorite / ranking 要模拟页面外层点击，验证 openable=false 不吞）', SAMPLES);
  }
  const ids = collect(sf, (x) => isStr(x) && x.text.startsWith('catalog-events/ProductCard'));
  if (ids.length === 0) { report('P8-catalog', null, '目录缺 catalog-events/ProductCard/<变体>/<状态> 计数节点（open|buy|outer）', SAMPLES); }
}

// ---------------------------------------------------------------- P9 登记
function checkRegistration() {
  const sf = parse(DS_LIST);
  if (!sf) { return; }
  const imp = sf.statements.filter((s) => ts.isImportDeclaration(s) && isStr(s.moduleSpecifier) && s.moduleSpecifier.text === './L2ProductCell.test'
    && s.importClause && s.importClause.name && s.importClause.name.text === 'l2ProductCellTest');
  if (imp.length !== 1) { report('P9-ds-list', null, 'designsystem List.test.ets 应 import l2ProductCellTest from \'./L2ProductCell.test\' 恰好一次', DS_LIST); }
  const suite = sf.statements.find((s) => ts.isFunctionDeclaration(s) && s.body);
  const direct = suite ? suite.body.statements.filter((s) => ts.isExpressionStatement(s) && compact(s.expression) === 'l2ProductCellTest()') : [];
  const all = collect(sf, (n) => ts.isCallExpression(n) && compact(n.expression) === 'l2ProductCellTest');
  if (direct.length !== 1 || all.length !== 1) {
    report('P9-ds-list', suite, 'testsuite 里应直接调用 l2ProductCellTest(); 恰好一次（实际直接 ' + direct.length + ' / 全部 ' + all.length + '）', DS_LIST);
  }
}

function checkSuite() {
  const sf = parse(SUITE);
  if (!sf) { return; }
  const consts = collect(sf, (n) => ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === 'L2CELL_DEVICE_CASES');
  const names = [];
  if (consts.length !== 1 || !consts[0].initializer || !ts.isArrayLiteralExpression(consts[0].initializer)) {
    report('P9-suite', consts[0] || null, 'Ds02L2Ui 应恰有一处 export const L2CELL_DEVICE_CASES: string[] = [ ... ]', SUITE);
  } else {
    for (const el of consts[0].initializer.elements) {
      if (!isStr(el)) { report('P9-suite', el, 'L2CELL_DEVICE_CASES 里有非字面量元素'); continue; }
      names.push(el.text);
    }
    const stmt = consts[0].parent && consts[0].parent.parent;
    if (!stmt || !(stmt.modifiers || []).some((m) => m.kind === ts.SyntaxKind.ExportKeyword)) {
      report('P9-suite', consts[0], 'L2CELL_DEVICE_CASES 应 export（test_test_facilities / check_device_result 比对名单）');
    }
  }
  facts.suiteNames = names;
  const fns = sf.statements.filter((s) => ts.isFunctionDeclaration(s) && s.name && s.name.text === 'ds02L2UiCellCases');
  if (fns.length !== 1) { report('P9-suite', null, 'Ds02L2Ui 应恰有一个 function ds02L2UiCellCases()（本段段函数）', SUITE); }
  const fn = fns[0];
  if (fn) {
    if (collect(fn, (n) => ts.isCallExpression(n) && compact(n.expression) === 'describe').length > 0) {
      report('P9-suite', fn, 'ds02L2UiCellCases 里另起 describe（段函数只注册 it，套件仍是唯一的 Ds02L2Ui）');
    }
    const its = collect(fn, (n) => ts.isCallExpression(n) && compact(n.expression) === 'it');
    const idx = [];
    for (const call of its) {
      const a = call.arguments[0] ? unwrap(call.arguments[0]) : null;
      if (a && ts.isElementAccessExpression(a) && compact(a.expression) === 'L2CELL_DEVICE_CASES' && ts.isNumericLiteral(a.argumentExpression)) {
        idx.push(Number(a.argumentExpression.text));
      } else {
        report('P9-suite', call, 'ds02L2UiCellCases 里的 it 名应写 L2CELL_DEVICE_CASES[下标]（与 BUTTON / PRICE 段同口径，CARD C7 只认字面量名）');
      }
    }
    const sorted = idx.slice().sort((x, y) => x - y);
    const want = names.map((_n, i) => i);
    if (JSON.stringify(sorted) !== JSON.stringify(want)) {
      report('P9-suite', fn, 'ds02L2UiCellCases 注册的下标 ' + JSON.stringify(sorted) + ' 应恰为 0..' + (names.length - 1) + ' 各一次');
    }
  }
  const calls = collect(sf, (n) => ts.isCallExpression(n) && compact(n) === 'ds02L2UiCellCases()');
  const describes = collect(sf, (n) => ts.isCallExpression(n) && compact(n.expression) === 'describe' && n.arguments[0] && isStr(n.arguments[0])
    && n.arguments[0].text === 'Ds02L2Ui');
  let placed = false;
  if (describes.length === 1) {
    const cb = describes[0].arguments[1];
    if (cb && (ts.isArrowFunction(cb) || ts.isFunctionExpression(cb)) && ts.isBlock(cb.body)) {
      const stmts = cb.body.statements;
      const at = stmts.findIndex((s) => ts.isExpressionStatement(s) && compact(s.expression) === 'ds02L2UiCellCases()');
      const state = stmts.findIndex((s) => ts.isExpressionStatement(s) && compact(s.expression) === 'L2StateSegment.ds02L2UiStateCases()');
      placed = at >= 0 && state >= 0 && at > state;
    }
  }
  if (calls.length !== 1 || !placed) {
    report('P9-suite', calls[0] || null, 'ds02L2UiCellCases(); 应在 describe(\'Ds02L2Ui\') 回调里直接调用恰好一次、排在 STATE 段之后（全文件 ' + calls.length + ' 处）', SUITE);
  }
  // 段边界（integ1 / integ2 同法只加本段分支）。
  const segs = collect(sf, (n) => ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === 'L2_SEGMENTS');
  const segVals = segs.length === 1 && segs[0].initializer && ts.isArrayLiteralExpression(segs[0].initializer)
    ? segs[0].initializer.elements.filter(isStr).map((e) => e.text) : [];
  if (segVals[segVals.length - 1] !== 'cell' || segVals.indexOf('state') !== segVals.length - 2) {
    report('P9-segment', segs[0] || null, 'L2_SEGMENTS 末尾应依次是 \'state\', \'cell\'（本段排在 STATE 之后），实际 ' + JSON.stringify(segVals), SUITE);
  }
  const fnBody = (name) => {
    const f = sf.statements.find((s) => ts.isFunctionDeclaration(s) && s.name && s.name.text === name);
    return f && f.body ? f.body : null;
  };
  const segOf = fnBody('l2SegmentOf');
  if (!segOf || !collect(segOf, (n) => ts.isIfStatement(n) && compact(n.expression) === "name.startsWith('l2cell_')"
    && collect(n.thenStatement, (r) => ts.isReturnStatement(r) && r.expression && isStr(r.expression) && r.expression.text === 'cell').length === 1).length) {
    report('P9-segment', segOf, "l2SegmentOf 应把 l2cell_ 前缀归到 'cell' 段", SUITE);
  }
  for (const name of ['l2SetupSegment', 'l2LeaveSegment']) {
    const body = fnBody(name);
    if (!body || collect(body, (n) => ts.isIfStatement(n) && compact(n.expression) === "segment==='cell'").length !== 1) {
      report('P9-segment', body, name + " 应恰有一支 segment === 'cell'（本段段前准备 / 段后复位）", SUITE);
    }
  }
}

for (const rel of FILES) { parse(rel); }
for (const rel of input.scan || []) { parse(rel); }
if (incomplete.length === 0) {
  checkProductCard();
  checkPages();
  checkCatalog();
  checkRegistration();
  checkSuite();
}
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete, facts: facts }));
