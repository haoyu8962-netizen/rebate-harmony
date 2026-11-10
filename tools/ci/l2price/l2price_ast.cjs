#!/usr/bin/env node
// HM-L2-PRICE-TAG 宿主守卫的解析部分（书 §3「结构」T1–T3 + 书外 P5–P8；由 check_l2_price.py 调用，不单独跑）。用鸿蒙 SDK 的 ohos-typescript
// 解析 ArkTS，判定全部走 AST（struct / 组件调用 / 属性链 / 方法体静态求值），注释与字符串里的字不算。写法照 tools/ci/l2button/l2button_ast.cjs。
//   用法：node l2price_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>"}, "rangeScan": ["<相对路径>", ...], "numeric": "transition" | "replace"}
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."]}
'use strict';
const fs = require('fs');
const path = require('path');

const PRICE = 'common/designsystem/src/main/ets/components/Price.ets';
const MODELS = 'common/designsystem/src/main/ets/format/PriceModels.ets';
const DS_LIST = 'common/designsystem/src/test/List.test.ets';
const CATALOG = 'entry/src/staging/ets/catalog/CatalogManifest.ets';
const DETAIL = 'entry/src/staging/ets/catalog/CatalogDetail.ets';

const tsDir = process.argv[2];
if (!tsDir) { console.error('l2price_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('l2price_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('l2price_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
    process.exit(3);
  }
  return { ets: cfg.compilerOptions.ets, etsLoaderPath: path.dirname(cfgPath) };
}
const ETS_OPTIONS = etsOptions();

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const MODE = input.numeric;
if (MODE !== 'transition' && MODE !== 'replace') { console.error('l2price_ast.cjs：numeric 只能是 transition / replace'); process.exit(2); }
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
  return owner ? owner.members.find((m) => ts.isMethodDeclaration(m) && memberName(m) === name) || null : null;
}
function moduleFunction(sf, name) {
  let hit = null;
  ts.forEachChild(sf, (n) => { if (ts.isFunctionDeclaration(n) && n.name && n.name.text === name) { hit = n; } });
  return hit;
}
function isBuilder(m) { return /^@Builder\b/.test(m.getText().trimStart()); }
function isThis(e) { return e && e.kind === ts.SyntaxKind.ThisKeyword; }

// ---------------------------------------------------------------- 组件节点与属性链
/** 组件调用名：Text(...) / Span(...) / Text() { ... }；不是组件调用返回 ''。 */
function compName(n) {
  if (ts.isEtsComponentExpression(n)) { return n.expression.getText(); }
  if (ts.isCallExpression(n) && ts.isIdentifier(n.expression)) { return n.expression.text; }
  return '';
}
/** 从组件调用往外收属性链 .a(..).b(..)，按书写顺序。 */
function chainUp(node) {
  const calls = [];
  let cur = node;
  while (cur.parent && ts.isPropertyAccessExpression(cur.parent) && cur.parent.expression === cur && cur.parent.parent
    && ts.isCallExpression(cur.parent.parent) && cur.parent.parent.expression === cur.parent) {
    calls.push({ name: cur.parent.name.text, args: Array.from(cur.parent.parent.arguments), node: cur.parent.parent });
    cur = cur.parent.parent;
  }
  return calls;
}

const AMOUNT_PROPS = new Set(['mainAmount', 'amountParts', 'amountText']);
/** 表达式是否读出金额：this.content.mainAmount / amountParts / amountText（可经 rangeBreakable 等函数包一层，或经无参 this.m() 转一手）。 */
function isAmountExpr(e, owner, depth) {
  if (!e || (depth || 0) > 4) { return false; }
  let hit = false;
  walk(e, (n) => {
    if (hit) { return; }
    if (ts.isPropertyAccessExpression(n) && AMOUNT_PROPS.has(n.name.text) && /content$/.test(compact(n.expression))) { hit = true; return; }
    if (ts.isCallExpression(n) && n.arguments.length === 0 && ts.isPropertyAccessExpression(n.expression) && isThis(n.expression.expression)) {
      const m = methodOf(owner, n.expression.name.text);
      if (m && !isBuilder(m) && m.body && collect(m.body, ts.isReturnStatement).some((r) => r.expression && isAmountExpr(r.expression, owner, (depth || 0) + 1))) {
        hit = true;
      }
    }
  });
  return hit;
}
/** struct（或其某个方法）里内容是金额的 Text / Span 组件调用。 */
function amountNodes(scope, owner) {
  return collect(scope, (n) => {
    const nm = compName(n);
    return (nm === 'Text' || nm === 'Span') && n.arguments && n.arguments.length > 0 && isAmountExpr(n.arguments[0], owner, 0);
  });
}
/** build() 里金额出现的位置数：直接的金额节点 + 每次调用含金额节点的 @Builder 方法（this.x()）。 */
function amountSites(owner) {
  const build = methodOf(owner, 'build');
  if (!build || !build.body) { return 0; }
  let sites = amountNodes(build.body, owner).length;
  for (const call of collect(build.body, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && isThis(n.expression.expression))) {
    const m = methodOf(owner, call.expression.name.text);
    if (m && isBuilder(m) && m.body && amountNodes(m.body, owner).length > 0) { sites++; }
  }
  return sites;
}
function enclosingText(node) {
  let cur = node.parent;
  while (cur) {
    if (ts.isEtsComponentExpression(cur) && cur.expression.getText() === 'Text') { return cur; }
    if (ts.isStructDeclaration(cur)) { return null; }
    cur = cur.parent;
  }
  return null;
}

// ---------------------------------------------------------------- 静态求值：contentTransition 实参在「减弱 / 未减弱」下各是什么
class Unknown extends Error {}

function callTarget(call, ctx) {
  const callee = call.expression;
  if (ts.isPropertyAccessExpression(callee) && isThis(callee.expression)) { return methodOf(ctx.owner, callee.name.text); }
  if (ts.isIdentifier(callee)) { return moduleFunction(ctx.sf, callee.text); }
  return null;
}
function evalBool(e, reduced, ctx, env, depth) {
  if (depth > 16) { throw new Unknown('递归太深'); }
  e = unwrap(e);
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isIdentifier(e) && env.has(e.text)) { return evalBool(env.get(e.text), reduced, ctx, env, depth + 1); }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) { return !evalBool(e.operand, reduced, ctx, env, depth + 1); }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    const l = () => evalBool(e.left, reduced, ctx, env, depth + 1);
    const r = () => evalBool(e.right, reduced, ctx, env, depth + 1);
    if (op === ts.SyntaxKind.AmpersandAmpersandToken) { return l() && r(); }
    if (op === ts.SyntaxKind.BarBarToken) { return l() || r(); }
    if (op === ts.SyntaxKind.EqualsEqualsEqualsToken) { return l() === r(); }
    if (op === ts.SyntaxKind.ExclamationEqualsEqualsToken) { return l() !== r(); }
  }
  if (ts.isCallExpression(e)) {
    const callee = compact(e.expression);
    if (callee === 'CouliMotion.reduced' && e.arguments.length === 0) { ctx.readsReduced = true; return reduced; }
    if (callee === 'MotionPolicy.numericTransition' && e.arguments.length === 1) {
      const arg = evalBool(e.arguments[0], reduced, ctx, env, depth + 1);
      if (ctx.readsReduced) { ctx.usedPolicy = true; }
      return !arg;
    }
    const target = e.arguments.length === 0 ? callTarget(e, ctx) : null;
    if (target && target.body && !isBuilder(target)) { return execBody(target.body, 'bool', reduced, ctx, new Map(), depth + 1); }
  }
  throw new Unknown('无法判定的条件「' + e.getText().slice(0, 80) + '」');
}
function evalTransition(e, reduced, ctx, env, depth) {
  if (depth > 16) { throw new Unknown('递归太深'); }
  e = unwrap(e);
  if (e.kind === ts.SyntaxKind.NullKeyword || (ts.isIdentifier(e) && e.text === 'undefined')) { return 'NONE'; }
  if (ts.isIdentifier(e) && env.has(e.text)) { return evalTransition(env.get(e.text), reduced, ctx, env, depth + 1); }
  if (ts.isConditionalExpression(e)) {
    return evalBool(e.condition, reduced, ctx, env, depth + 1) ? evalTransition(e.whenTrue, reduced, ctx, env, depth + 1)
      : evalTransition(e.whenFalse, reduced, ctx, env, depth + 1);
  }
  if (ts.isNewExpression(e) && /NumericTextTransition$/.test(e.expression.getText())) { return 'RAW'; }
  if (ts.isCallExpression(e)) {
    if (compact(e.expression) === 'CouliMotion.numeric' && e.arguments.length === 0) { return 'NUMERIC'; }
    const target = e.arguments.length === 0 ? callTarget(e, ctx) : null;
    if (target && target.body && !isBuilder(target)) { return execBody(target.body, 'transition', reduced, ctx, new Map(), depth + 1); }
  }
  throw new Unknown('无法判定的过渡实参「' + e.getText().slice(0, 80) + '」');
}
/** 方法 / 函数体的小解释器：const 绑定、if / else、return；其余语句（日志等）跳过，循环与赋值不认。 */
function execBody(block, kind, reduced, ctx, env, depth) {
  if (depth > 16) { throw new Unknown('递归太深'); }
  const stmts = ts.isBlock(block) ? block.statements : [block];
  for (const s of stmts) {
    if (ts.isVariableStatement(s)) {
      for (const d of s.declarationList.declarations) {
        if (ts.isIdentifier(d.name) && d.initializer) { env.set(d.name.text, d.initializer); }
      }
      continue;
    }
    if (ts.isReturnStatement(s)) {
      if (!s.expression) { throw new Unknown('空 return'); }
      return kind === 'bool' ? evalBool(s.expression, reduced, ctx, env, depth + 1) : evalTransition(s.expression, reduced, ctx, env, depth + 1);
    }
    if (ts.isIfStatement(s)) {
      const branch = evalBool(s.expression, reduced, ctx, env, depth + 1) ? s.thenStatement : s.elseStatement;
      if (branch) {
        const got = execBody(branch, kind, reduced, ctx, env, depth + 1);
        if (got !== undefined) { return got; }
      }
      continue;
    }
    if (ts.isBlock(s)) {
      const got = execBody(s, kind, reduced, ctx, env, depth + 1);
      if (got !== undefined) { return got; }
      continue;
    }
    if (ts.isExpressionStatement(s) && !(ts.isBinaryExpression(s.expression) && s.expression.operatorToken.kind === ts.SyntaxKind.EqualsToken)) { continue; }
    throw new Unknown('方法体里有无法判定的语句「' + s.getText().slice(0, 60) + '」');
  }
  return undefined;
}

// ---------------------------------------------------------------- T1 / P1：金额承载节点与数字过渡（README ⑤ 两种结局）
const FIT_FORBIDDEN = ['maxLines', 'textOverflow', 'minFontSize', 'maxFontSize', 'maxFontScale', 'minFontScale', 'heightAdaptivePolicy',
  'ellipsisMode'];
function checkAmountNodes() {
  const sf = parse(PRICE);
  if (!sf) { return; }
  for (const name of ['PriceTag', 'RebateTag']) {
    const owner = findStruct(sf, name);
    if (!owner) { report('P1-sites', null, 'Price.ets 缺 struct ' + name, PRICE); continue; }
    const nodes = amountNodes(owner, owner);
    const sites = amountSites(owner);
    if (sites < 2) {
      report('P1-sites', owner, name + '.build 里金额只出现 ' + sites + ' 处（应 ≥ 2：' + (name === 'PriceTag' ? '预售标签行与普通行' : '大号 / 列表行与窄卡 BLOCK')
        + '都显示金额）');
    }
    const ctx = { sf: sf, owner: owner };
    for (const n of nodes) {
      const kind = compName(n);
      const chain = chainUp(n);
      // 不截断、不缩字号、金额本身不拆（03 §10.4；Price.ets「金额本身不拆」）。Span 的这些属性挂在外层 Text 上，一并查。
      const holder = kind === 'Span' ? enclosingText(n) : n;
      const fitChain = holder ? chainUp(holder) : [];
      for (const c of fitChain) {
        if (FIT_FORBIDDEN.includes(c.name)) { report('P1-fit', c.node, name + ' 金额节点挂了 .' + c.name + '（200% 不截断、不缩字号，03 §10.4）'); }
        if (c.name === 'wordBreak' && !(c.args.length === 1 && compact(c.args[0]) === 'WordBreak.NORMAL')) {
          report('P1-fit', c.node, name + ' 金额节点 wordBreak 应为 WordBreak.NORMAL（金额本身不拆），实际 ' + c.args.map(compact).join(','));
        }
      }
      if (MODE === 'transition') {
        if (kind === 'Span') {
          report('P1-span', n, name + ' 的金额还在 Span 里：Span 没有 contentTransition（span.d.ts），金额要拆成独立 Text（README ⑤）');
          continue;
        }
        const ct = chain.filter((c) => c.name === 'contentTransition');
        if (ct.length !== 1) {
          report('P1-transition', n, name + ' 金额 Text 应挂 .contentTransition(...) 恰好一处（实际 ' + ct.length + ' 处，README ⑤）');
          continue;
        }
        if (ct[0].args.length !== 1) { report('P1-transition', ct[0].node, name + ' contentTransition 应有一个实参'); continue; }
        try {
          const c1 = { sf: sf, owner: owner, readsReduced: false, usedPolicy: false };
          const normal = evalTransition(ct[0].args[0], false, c1, new Map(), 0);
          const c2 = { sf: sf, owner: owner, readsReduced: false, usedPolicy: false };
          const reduced = evalTransition(ct[0].args[0], true, c2, new Map(), 0);
          if (normal === 'RAW' || reduced === 'RAW') {
            report('P1-transition', ct[0].node, name + ' 数字过渡要来自 CouliMotion.numeric()，不在组件里另 new NumericTextTransition');
          } else if (normal !== 'NUMERIC') {
            report('P1-transition', ct[0].node, name + ' 未减弱动态时金额没挂 CouliMotion.numeric()（实际 ' + normal + '）');
          }
          if (reduced !== 'NONE' && reduced !== 'RAW') {
            report('P1-reduced', ct[0].node, name + ' 减弱动态时仍挂数字过渡（应 undefined，直接替换，D10-1163 ①；实际 ' + reduced + '）');
          }
          if (!(c1.readsReduced && c2.readsReduced)) {
            report('P1-reduced', ct[0].node, name + ' 过渡实参没读 CouliMotion.reduced()（同一条件包减弱动态，书 T1）');
          } else if (!(c1.usedPolicy && c2.usedPolicy)) {
            report('P1-policy', ct[0].node, name + ' 过渡条件应经 MotionPolicy.numericTransition(CouliMotion.reduced())（与 Hypium p3 钉的策略同一函数）');
          }
        } catch (e) {
          if (!(e instanceof Unknown)) { throw e; }
          report('P1-transition', ct[0].node, name + ' contentTransition 实参无法静态判定：' + e.message);
        }
      }
    }
    if (nodes.length === 0) { report('P1-sites', owner, name + ' 里找不到内容是金额（content.mainAmount / amountParts / amountText）的 Text / Span'); }
    // 不闪：金额节点不按金额值建 / 拆（if 条件不读金额），PriceTag / RebateTag 里不挂 .transition / .animation。
    for (const s of collect(owner, ts.isIfStatement)) {
      if (isAmountExpr(s.expression, owner, 0)) { report('P1-flash', s, name + ' 的 if 条件读了金额值：换值时节点会被拆掉重建（闪），金额换值应原节点替换'); }
    }
    for (const c of collect(owner, (x) => ts.isCallExpression(x) && ts.isPropertyAccessExpression(x.expression)
      && ['transition', 'animation'].includes(x.expression.name.text) && !isThis(x.expression.expression))) {
      report('P1-flash', c, name + ' 里挂了 .' + c.expression.name.text + '(...)：金额换值不另做淡入淡出 / 隐式动画（系统数字过渡或直接替换）');
    }
  }
  // 任何 Span 上挂 contentTransition 都不行（书 T4：写到 Span 上解析器应报）。
  for (const n of collect(sf, (x) => compName(x) === 'Span')) {
    if (chainUp(n).some((c) => c.name === 'contentTransition')) { report('P1-span', n, 'Span 上挂了 contentTransition（span.d.ts 没有这个属性，README ⑤）'); }
  }
  if (MODE === 'replace') {
    // README ⑤ 探针不过：直接替换。Price.ets 里不出现数字过渡。
    for (const n of collect(sf, (x) => (ts.isIdentifier(x) && (x.text === 'contentTransition' || x.text === 'NumericTextTransition'))
      || (ts.isPropertyAccessExpression(x) && compact(x) === 'CouliMotion.numeric'))) {
      report('P1-replace', n, '探针结论是直接替换（--numeric replace）：Price.ets 不得出现 ' + n.getText());
    }
  }
}

// ---------------------------------------------------------------- T2 / T3：无触感、无自写过渡、不读 motion 令牌
const ANIM_CALLS = new Set(['animateTo', 'animateToImmediately', 'keyframeAnimateTo', 'animation']);
const TIMING_KEYS = new Set(['duration', 'delay', 'curve', 'iterations', 'tempo', 'playMode']);
function checkFeel() {
  const sf = parse(PRICE);
  if (!sf) { return; }
  for (const imp of sf.statements.filter(ts.isImportDeclaration)) {
    const mod = isStr(imp.moduleSpecifier) ? imp.moduleSpecifier.text : '';
    const names = imp.importClause && imp.importClause.namedBindings && ts.isNamedImports(imp.importClause.namedBindings)
      ? imp.importClause.namedBindings.elements.map((e) => e.name.text) : [];
    if (mod === '@kit.SensorServiceKit' || mod === '@ohos.vibrator' || /CouliHaptics$/.test(mod) || names.includes('CouliHaptics')) {
      report('P2-haptics', imp, 'Price.ets 引入了触感 / 振动器 ' + mod + '（价格 / 返利标签无触感时刻，README §3.2）');
    }
    if (mod.startsWith('generated') || /Tokens/.test(mod) || names.some((n) => /token/i.test(n))) {
      report('P3-token', imp, 'Price.ets 导入令牌 ' + mod + ' {' + names.join(', ') + '}（原生不读 motion 令牌，D10-838）');
    }
  }
  walk(sf, (n) => {
    if (ts.isIdentifier(n) && (n.text === 'CouliHaptics' || n.text === 'vibrator') && !ts.isImportSpecifier(n.parent)) {
      report('P2-haptics', n, 'Price.ets 用了 ' + n.text + '（价格 / 返利标签无触感，README §3.2）');
    }
    if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)) {
      const nm = n.expression.name.text;
      if (ANIM_CALLS.has(nm)) { report('P2-anim', n, 'Price.ets 自写过渡 .' + nm + '(...)（数字过渡用系统 contentTransition，书 §2.1）'); }
      if (compact(n.expression) === 'CouliMotion.run') { report('P2-anim', n, 'Price.ets 用了 CouliMotion.run（书 §2.1：数字过渡是系统能力，不用它）'); }
    }
    if (isStr(n) && (/^(--)?motion[.-]/.test(n.text))) { report('P3-token', n, 'Price.ets 读 motion 令牌「' + n.text + '」（D10-838）'); }
    if (ts.isPropertyAssignment(n) && n.name && TIMING_KEYS.has(memberName(n))) {
      report('P3-token', n, 'Price.ets 自定动效参数 ' + memberName(n) + '（不读 motion 令牌、不自写时长曲线，D10-838）');
    }
    if (ts.isPropertyAccessExpression(n) && ts.isIdentifier(n.expression) && (n.expression.text === 'Curve' || n.expression.text === 'curves'
      || (n.expression.text === 'CouliMotion' && ['durationMicro', 'durationEnter', 'curve', 'spring', 'responsive', 'appear'].includes(n.name.text)))) {
      report('P3-token', n, 'Price.ets 自选曲线 / 时长 ' + n.getText() + '（D10-838）');
    }
  });
}

// ---------------------------------------------------------------- P5（D10-1177 ④）：不做金额隐藏变体；CardAmountMask 原样留作防御
function checkHiddenVariant() {
  const sf = parse(PRICE);
  if (sf) {
    for (const name of ['PriceTag', 'RebateTag', 'EstNetLine']) {
      const owner = findStruct(sf, name);
      if (!owner) { continue; }
      for (const m of owner.members) {
        if (ts.isPropertyDeclaration(m) && /hidden|mask|conceal|secret|privacy/i.test(memberName(m))) {
          report('P5-variant', m, name + ' 新增了隐藏类参数 ' + memberName(m) + '（D10-1177 ④：不做金额隐藏变体，BR-TEXT-10 优先）');
        }
      }
      walk(owner, (n) => {
        if (ts.isIdentifier(n) && ['CardAmountMask', 'amountMask', 'amountHiddenSpoken'].includes(n.text)) {
          report('P5-variant', n, name + ' 里自做金额隐藏（' + n.text + '）；遮罩只由调用方经 CardAmountMask 传入（D10-1177 ④）');
        }
      });
    }
  }
  const models = parse(MODELS);
  if (models) {
    const mask = findClass(models, 'CardAmountMask');
    const ok = mask && ['rebate', 'estNet'].every((n) => {
      const m = methodOf(mask, n);
      return m && (m.modifiers || []).some((x) => x.kind === ts.SyntaxKind.StaticKeyword);
    });
    if (!ok) { report('P5-keep', mask, 'CardAmountMask（static rebate / estNet）要原样留作防御（D10-1177 ④）', MODELS); }
  }
}

// ---------------------------------------------------------------- P6（D10-638）：RANGE 分支只兼容保留，不新增入口
function checkRange() {
  const models = parse(MODELS);
  if (models) {
    const cls = findClass(models, 'RebateTagModel');
    const make = cls ? methodOf(cls, 'make') : null;
    const ranges = make ? collect(make, (n) => ts.isNewExpression(n) && compact(n.expression) === 'RebateTagContent' && n.arguments
      && n.arguments[0] && compact(n.arguments[0]) === 'RebateKind.RANGE') : [];
    if (ranges.length !== 1) { report('P6-make', make, 'RebateTagModel.make 里 RANGE 分支应恰好一处（兼容保留，不删不增；实际 ' + ranges.length + '）', MODELS); }
    const refs = collect(models, (n) => ts.isPropertyAccessExpression(n) && compact(n) === 'RebateKind.RANGE');
    if (refs.length > 2) { report('P6-range', refs[2], 'PriceModels.ets 里 RebateKind.RANGE 引用 ' + refs.length + ' 处（基线 2：hasAmount 与 make），新增了区间入口（D10-638）'); }
  }
  for (const rel of input.rangeScan || []) {
    if (rel === MODELS) { continue; }
    const sf = parse(rel);
    if (!sf) { continue; }
    for (const n of collect(sf, (x) => ts.isPropertyAccessExpression(x) && compact(x) === 'RebateKind.RANGE')) {
      report('P6-range', n, rel + ' 新增了 RebateKind.RANGE 入口（D10-638：服务端只发单值，RANGE 只在 RebateTagModel 兼容保留）');
    }
  }
  const price = parse(PRICE);
  if (price) {
    // rangeBreakable 只给金额节点用（区间只在破折号折行）；调用不超过基线 2 处，且每处都是金额 Text / Span 的内容。
    const calls = collect(price, (n) => ts.isCallExpression(n) && compact(n.expression) === 'rangeBreakable');
    if (calls.length > 2) { report('P6-range', calls[2], 'Price.ets 里 rangeBreakable 调用 ' + calls.length + ' 处（基线 2），新增了区间入口（D10-638）'); }
    for (const c of calls) {
      let cur = c.parent;
      while (cur && !(compName(cur) === 'Text' || compName(cur) === 'Span') && !ts.isMethodDeclaration(cur) && !ts.isStructDeclaration(cur)) { cur = cur.parent; }
      const holder = cur && (compName(cur) === 'Text' || compName(cur) === 'Span') ? cur : null;
      const owner = holder ? (function up(n) { return !n || ts.isStructDeclaration(n) ? n : up(n.parent); })(holder) : null;
      if (!holder || !holder.arguments.length || holder.arguments[0] !== c || !isAmountExpr(c, owner, 0)) {
        report('P6-range', c, 'rangeBreakable 只用作金额节点的内容（区间兼容显示），这里是新的区间入口（D10-638）');
      }
    }
  }
}

// ---------------------------------------------------------------- P7 逻辑套件已登记；P8 目录（设备套件 Ds02L2Ui l2price_ 段的前提）
function checkRegistration() {
  const sf = parse(DS_LIST);
  if (!sf) { return; }
  const imp = sf.statements.filter((s) => ts.isImportDeclaration(s) && isStr(s.moduleSpecifier) && s.moduleSpecifier.text === './L2PriceTag.test'
    && s.importClause && s.importClause.name && s.importClause.name.text === 'l2PriceTagTest');
  if (imp.length !== 1) { report('P7-register', null, 'designsystem List.test.ets 应 import l2PriceTagTest from \'./L2PriceTag.test\' 恰好一次', DS_LIST); }
  const suite = sf.statements.find((s) => ts.isFunctionDeclaration(s) && s.body);
  const direct = suite ? suite.body.statements.filter((s) => ts.isExpressionStatement(s) && compact(s.expression) === 'l2PriceTagTest()') : [];
  const all = collect(sf, (n) => ts.isCallExpression(n) && compact(n.expression) === 'l2PriceTagTest');
  if (direct.length !== 1 || all.length !== 1) {
    report('P7-register', suite, 'testsuite 里应直接调用 l2PriceTagTest(); 恰好一次（实际直接 ' + direct.length + ' / 全部 ' + all.length + '）', DS_LIST);
  }
}
const PRICE_VARIANTS = ['coupon-list', 'coupon-ai', 'coupon-detail', 'no-coupon-list', 'no-coupon-ai', 'no-coupon-detail', 'pdd-list', 'pdd-ai',
  'pdd-detail', 'presale-list', 'presale-ai', 'presale-detail'];
const WANT_ROWS = {
  PriceTag: PRICE_VARIANTS.flatMap((v) => ['normal', 'long-price'].map((s) => v + '/' + s)),
  RebateTag: ['single', 'range', 'large', 'amount_unknown', 'login_required'].flatMap((v) => ['normal', 'amount-hidden'].map((s) => v + '/' + s))
    .concat(['range/wrap-at-dash', 'block/normal']),
  EstNetLine: ['default/normal', 'default/amount-hidden'],
};
function checkCatalog() {
  const sf = parse(CATALOG);
  if (sf) {
    for (const comp of Object.keys(WANT_ROWS)) {
      const calls = collect(sf, (n) => ts.isCallExpression(n) && compact(n.expression) === 'c' && n.arguments[0] && isStr(n.arguments[0])
        && n.arguments[0].text === comp);
      const rows = [];
      for (const call of calls) {
        for (const m of collect(call, (n) => ts.isCallExpression(n) && compact(n.expression) === 'm' && n.arguments.length === 2)) {
          const lits = (a) => ts.isArrayLiteralExpression(a) ? a.elements.filter(isStr).map((e) => e.text) : [];
          for (const v of lits(m.arguments[0])) { for (const s of lits(m.arguments[1])) { rows.push(v + '/' + s); } }
        }
      }
      const got = rows.slice().sort();
      const want = WANT_ROWS[comp].slice().sort();
      if (calls.length !== 1 || JSON.stringify(got) !== JSON.stringify(want)) {
        const missing = want.filter((r) => !got.includes(r));
        const extra = got.filter((r) => !want.includes(r));
        report('P8-catalog', calls[0] || null, '目录 ' + comp + ' 样例应为既有行' + (comp === 'RebateTag' ? ' + block × normal（窄卡两行，金额独立 Text）' : '')
          + '，range / amount-hidden 原样保留、不新增（D10-638 / D10-1177 ④ / README ⑨）；缺 ' + JSON.stringify(missing) + ' 多 ' + JSON.stringify(extra), CATALOG);
      }
    }
  }
  const detail = parse(DETAIL);
  if (detail) {
    const toggles = collect(detail, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && isThis(n.expression.expression)
      && n.expression.name.text === 'action' && n.arguments[0] && isStr(n.arguments[0]) && n.arguments[0].text === 'catalog-amount-toggle');
    let ok = toggles.length === 1;
    if (ok) {
      let cur = toggles[0].parent;
      let conds = '';
      while (cur && !ts.isMethodDeclaration(cur)) {
        if (ts.isIfStatement(cur)) { conds += collect(cur.expression, isStr).map((s) => s.text).join(','); }
        cur = cur.parent;
      }
      ok = conds.includes('PriceTag') && conds.includes('RebateTag');
    }
    if (!ok) {
      report('P8-toggle', toggles[0] || null, '目录详情要有一个「切换金额」动作 this.action(\'catalog-amount-toggle\', ...)，PriceTag 与 RebateTag 页都显示'
        + '（目录内切值看数字过渡，书 §3 设备 / §7 录屏；Ds02L2Ui l2price_03）', DETAIL);
    }
  }
}

for (const rel of [PRICE, MODELS, DS_LIST, CATALOG, DETAIL]) { parse(rel); }
for (const rel of input.rangeScan || []) { parse(rel); }
if (incomplete.length === 0) {
  checkAmountNodes();
  checkFeel();
  checkHiddenVariant();
  checkRange();
  checkRegistration();
  checkCatalog();
}
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete }));
