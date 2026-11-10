#!/usr/bin/env node
// HM-L2-CARD 宿主守卫的解析部分（测试作者 v1，新鲜独立 Claude；由 check_l2_card.py 调用，不单独跑）。
// 照 tools/ci/tabbar/tabbar_ast.cjs：用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS，判定全部走 AST（struct / 组件尾随闭包 / 装饰器 /
// 属性链 / if 分支），不用正则切块；注释与字符串里的字不算。
//   用法：node l2card_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>" | null}, "scan": ["<相对路径>", ...]}（null = 文件不存在；scan 为页面候选文件）
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."], "facts": {...}}
// 规则编号对应 NATIVE/HM-L2-BATCH1/brief-CARD.md §3（C1–C4）与 §2.2–§2.4、§4、README ⑨ ⑩（C6–C8）：
//   C1 CouliCard 结构（两种入口、TAPPABLE 经 CouliPressable、STATIC 无点击、参数默认值、Index 导出）
//   C2 卡内只用 CouliColors / CouliRadius / CouliShadow 令牌（无字面量）；白底在 STATIC 链上、TAPPABLE 不盖住按压色
//   C3 CouliPressable 的 F-HM-98（disabled → .enabled(!this.disabled)、onClick 内判禁用、accessibilityGroup / accessibilityText 两分支、normalColor）
//   C4 CouliPressable / CouliCard 无触感、不读 motion 令牌
//   C6 目录：CatalogManifest 的 CouliCard 矩阵、CatalogSampleViews 的样例分支（含 ListItemGroup CARD）
//   C7 登记：两份 List.test.ets（AST 部分）、设备用例名单一致（与 device-cases.txt 的比对在 py）
//   C8 页面不用 CouliCard（L2 期内只被组件库用；书 §2.4、§4）
// 测试 v2（评审 r1）：C3-corner / C2-tappable-corner（S2-1 回弹缩放那层带卡片圆角）；C2-elevated 极性、C2-shadow-radius、C2-padding（S3-2 三个漏网变异）；
//   C9 给后续单的接口（S3-5：STATIC 读屏参数 C9-a11y、最外层 a11yLevel C9-level、STATIC 圆角裁剪 C9-clip、平铺 inset C9-inset）。
//   属性实参按参数取值求（ev：只认 this.elevated / this.inset 的布尔式、三元与 if），求不出按违反。
'use strict';
const fs = require('fs');
const path = require('path');

const CARD = 'common/designsystem/src/main/ets/components/CouliCard.ets';
const PRESS = 'common/designsystem/src/main/ets/components/CouliPressable.ets';
const INDEX = 'common/designsystem/Index.ets';
const MANIFEST = 'entry/src/staging/ets/catalog/CatalogManifest.ets';
const SAMPLES = 'entry/src/staging/ets/catalog/CatalogSampleViews.ets';
const ENTRY_LIST = 'entry/src/ohosTest/ets/test/List.test.ets';
const DS_LIST = 'common/designsystem/src/test/List.test.ets';
const DEVICE_SUITE = 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets';

const CARD_MODULE = './src/main/ets/components/CouliCard';
const EXPECTED_CASES = [];
for (const v of ['static', 'tappable-bounce', 'tappable-highlight']) {
  for (const s of ['default', 'pressed', 'disabled']) { EXPECTED_CASES.push(v + '/' + s); }
}
EXPECTED_CASES.push('list-group/default');

const tsDir = process.argv[2];
if (!tsDir) { console.error('l2card_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('l2card_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('l2card_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
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

/** 解析；文件不存在返回 null（由各规则报违反），语法错误记 incomplete（py 按 4 退出）。 */
function parse(rel) {
  if (parsed.has(rel)) { return parsed.get(rel); }
  const text = input.files[rel];
  if (text === undefined || text === null) { parsed.set(rel, null); return null; }
  const kind = rel.endsWith('.ets') ? ts.ScriptKind.ETS : ts.ScriptKind.TS;
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true, kind, ETS_OPTIONS);
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
function exists(rel) { return input.files[rel] !== undefined && input.files[rel] !== null; }

function lineOf(node) { return node.getSourceFile().getLineAndCharacterOfPosition(node.getStart()).line + 1; }
function report(rule, file, node, msg) {
  violations.push({ rule: rule, file: file, line: node ? lineOf(node) : 0, msg: msg });
}
function walk(node, visit) { visit(node); ts.forEachChild(node, (c) => walk(c, visit)); }
function collect(node, pred) { const out = []; walk(node, (n) => { if (pred(n)) { out.push(n); } }); return out; }
function compact(node) { return node.getText().replace(/\s+/g, ''); }
function unwrap(e) {
  while (e && (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isNonNullExpression(e))) { e = e.expression; }
  return e;
}
function nameText(n) { return n && (ts.isIdentifier(n) || ts.isStringLiteral(n)) ? n.text : ''; }
function decoratorsOf(node) {
  const list = ts.getAllDecorators ? ts.getAllDecorators(node) : (node.decorators || []);
  return Array.from(list || []).map((d) => {
    const x = ts.isCallExpression(d.expression) ? d.expression.expression : d.expression;
    return x.getText();
  });
}
function hasExport(node) { return (node.modifiers || []).some((m) => m.kind === ts.SyntaxKind.ExportKeyword); }
function findStruct(sf, name) {
  let hit = null;
  ts.forEachChild(sf, (n) => { if (ts.isStructDeclaration(n) && n.name && n.name.text === name) { hit = n; } });
  return hit;
}
function methodOf(struct, name) {
  return struct.members.find((m) => ts.isMethodDeclaration(m) && nameText(m.name) === name) || null;
}
function propOf(struct, name) {
  return struct.members.find((m) => ts.isPropertyDeclaration(m) && nameText(m.name) === name) || null;
}

/** 组件调用（CouliCard({...}) / Column() / ListItem({...})）：返回被调名；EtsComponentExpression 与普通调用都认。 */
function componentName(n) {
  if (ts.isEtsComponentExpression && ts.isEtsComponentExpression(n)) { return n.expression.getText(); }
  if (ts.isCallExpression(n) && ts.isIdentifier(n.expression)) { return n.expression.text; }
  return '';
}
function componentCalls(root, name) { return collect(root, (n) => componentName(n) === name); }
function firstObjectArg(call) {
  const args = Array.from(call.arguments || []);
  return args.length > 0 && ts.isObjectLiteralExpression(unwrap(args[0])) ? unwrap(args[0]) : null;
}
function objectProps(obj) {
  const out = new Map();
  if (!obj) { return out; }
  for (const p of obj.properties) {
    if (ts.isPropertyAssignment(p)) { out.set(nameText(p.name), p.initializer); }
    else if (ts.isShorthandPropertyAssignment(p)) { out.set(p.name.text, p.name); }
  }
  return out;
}
/** 尾随闭包（组件的 body 块）。 */
function trailingBody(call) { return call.body || null; }

/** 某组件调用所在的属性链：向外爬 PropertyAccess + Call，返回 [{name, args, node}]（书写顺序）。 */
function chainAround(component) {
  let top = component;
  const calls = [];
  for (;;) {
    const access = top.parent;
    if (access && ts.isPropertyAccessExpression(access) && access.expression === top &&
        access.parent && ts.isCallExpression(access.parent) && access.parent.expression === access) {
      calls.push({ name: access.name.text, args: Array.from(access.parent.arguments), node: access.parent });
      top = access.parent;
    } else { break; }
  }
  return calls;
}
/** 链头：.onClick(...) 这类调用一路往里找到组件调用（Stack() / Column()）。 */
function chainHead(call) {
  let e = call;
  while (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression)) { e = e.expression.expression; }
  return e;
}
function attributeCalls(root, names) {
  return collect(root, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
    names.includes(n.expression.name.text) && componentName(chainHead(n)) !== '');
}
function isThisMember(node, member) {
  const e = unwrap(node);
  return e && ts.isPropertyAccessExpression(e) && e.expression.kind === ts.SyntaxKind.ThisKeyword && e.name.text === member;
}
function mentionsThis(node, member) {
  return collect(node, (n) => ts.isPropertyAccessExpression(n) && n.expression.kind === ts.SyntaxKind.ThisKeyword &&
    n.name.text === member).length > 0;
}
/** 闭包里实际调用 this.<member>()。 */
function callsThis(node, member) {
  return collect(node, (n) => ts.isCallExpression(n) && isThisMember(n.expression, member)).length > 0;
}

/** if 条件是「this.kind 与 CouliCardKind.X 的单一比较」时，返回 TAPPABLE 所在的语句块；否则 null。 */
function tappableSplit(ifs) {
  const c = unwrap(ifs.expression);
  if (!ts.isBinaryExpression(c)) { return null; }
  const op = c.operatorToken.kind;
  const eq = op === ts.SyntaxKind.EqualsEqualsEqualsToken || op === ts.SyntaxKind.EqualsEqualsToken;
  const ne = op === ts.SyntaxKind.ExclamationEqualsEqualsToken || op === ts.SyntaxKind.ExclamationEqualsToken;
  if (!eq && !ne) { return null; }
  const sides = [unwrap(c.left), unwrap(c.right)];
  const kindSide = sides.find((s) => isThisMember(s, 'kind'));
  const lit = sides.find((s) => ts.isPropertyAccessExpression(s) && s.expression.getText() === 'CouliCardKind');
  if (!kindSide || !lit || !ifs.elseStatement) { return null; }
  const member = lit.name.text;
  const thenIsTappable = (member === 'TAPPABLE') === eq;
  if (member !== 'TAPPABLE' && member !== 'STATIC') { return null; }
  return thenIsTappable ? { tappable: ifs.thenStatement, stat: ifs.elseStatement }
    : { tappable: ifs.elseStatement, stat: ifs.thenStatement };
}

function argReferences(arg) {
  // 实参里出现的标识符根（CouliColors.x → CouliColors；this.x → this）与字面量。
  const roots = new Set();
  const literals = [];
  walk(arg, (n) => {
    if (ts.isPropertyAccessExpression(n) && !ts.isPropertyAccessExpression(n.parent)) {
      let r = n;
      while (ts.isPropertyAccessExpression(r)) { r = r.expression; }
      roots.add(r.kind === ts.SyntaxKind.ThisKeyword ? 'this' : r.getText() + (r.getText() === 'Color' ? '.' + n.name.text : ''));
    } else if (ts.isIdentifier(n) && !ts.isPropertyAccessExpression(n.parent) && !(ts.isPropertyAssignment(n.parent) && n.parent.name === n)) {
      roots.add(n.text);
    }
    if (ts.isNumericLiteral(n) || ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)) { literals.push(n.getText()); }
  });
  return { roots, literals };
}

// ---------------------------------------------------------------- C1 / C2 / C4：CouliCard

// ---------------------------------------------------------------- 测试 v2：按参数取值求属性实参（评审 r1 S2-1 / S3-2 / S3-5）
// 只认 this.elevated / this.inset 的布尔式（!、&&、||、=== true/false、三元、if 条件）；其余 this.x 与令牌按原文（去空白）当叶子。
// 求不出来（条件里有方法调用、非布尔参与逻辑运算）按 UNKNOWN，各规则一律当违反（fail-closed，不当通过）。
const NORMAL = { elevated: true, inset: false };
const SHADOW_OFF = [{ elevated: false, inset: false }, { elevated: false, inset: true }];
const INSET = { elevated: true, inset: true };
const UNKNOWN = { unknown: true };
const ABSENT = { absent: true };
class Unknown extends Error {}
function ev(node, env) {
  const e = unwrap(node);
  if (!e) { throw new Unknown('空'); }
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) {
    const v = ev(e.operand, env);
    if (typeof v !== 'boolean') { throw new Unknown(e.getText()); }
    return !v;
  }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    if ([ts.SyntaxKind.AmpersandAmpersandToken, ts.SyntaxKind.BarBarToken, ts.SyntaxKind.EqualsEqualsEqualsToken,
      ts.SyntaxKind.ExclamationEqualsEqualsToken, ts.SyntaxKind.EqualsEqualsToken, ts.SyntaxKind.ExclamationEqualsToken].includes(op)) {
      const l = ev(e.left, env);
      const r = ev(e.right, env);
      if (typeof l !== 'boolean' || typeof r !== 'boolean') { throw new Unknown(e.getText()); }
      if (op === ts.SyntaxKind.AmpersandAmpersandToken) { return l && r; }
      if (op === ts.SyntaxKind.BarBarToken) { return l || r; }
      const same = l === r;
      return (op === ts.SyntaxKind.EqualsEqualsEqualsToken || op === ts.SyntaxKind.EqualsEqualsToken) ? same : !same;
    }
    throw new Unknown(e.getText());
  }
  if (ts.isConditionalExpression(e)) {
    const c = ev(e.condition, env);
    if (typeof c !== 'boolean') { throw new Unknown(e.getText()); }
    return ev(c ? e.whenTrue : e.whenFalse, env);
  }
  if (ts.isPropertyAccessExpression(e) && e.expression.kind === ts.SyntaxKind.ThisKeyword &&
      Object.prototype.hasOwnProperty.call(env, e.name.text)) {
    return env[e.name.text];
  }
  if (ts.isCallExpression(e)) { throw new Unknown(e.getText()); }
  return compact(e);
}
function evSafe(node, env) {
  try { return ev(node, env); } catch (x) { if (x instanceof Unknown) { return UNKNOWN; } throw x; }
}
/** 某节点在 env 下是否会画出来：从它往上到 stop，经过的 if / 三元条件都要求值成立。求不出抛 Unknown。 */
function active(node, env, stop) {
  for (let p = node.parent, child = node; p && p !== stop; child = p, p = p.parent) {
    if (ts.isIfStatement(p) && child !== p.expression) {
      const c = ev(p.expression, env);
      if (typeof c !== 'boolean') { throw new Unknown(p.expression.getText()); }
      if ((child === p.thenStatement && !c) || (child === p.elseStatement && c)) { return false; }
    }
    if (ts.isConditionalExpression(p) && child !== p.condition) {
      const c = ev(p.condition, env);
      if (typeof c !== 'boolean') { throw new Unknown(p.condition.getText()); }
      if ((child === p.whenTrue && !c) || (child === p.whenFalse && c)) { return false; }
    }
  }
  return true;
}
/** 链上某属性在 env 下的值：同名取最后一次（ArkUI 后写覆盖）；没有 → ABSENT；求不出 → UNKNOWN。 */
function chainVal(chain, name, env) {
  const hits = chain.filter((c) => c.name === name);
  if (!hits.length) { return ABSENT; }
  const last = hits[hits.length - 1];
  if (last.args.length !== 1) { return UNKNOWN; }
  return evSafe(last.args[0], env);
}
function isVal(v, text) { return typeof v === 'string' && v === text; }
function hasCardShadow(v) { return typeof v === 'string' && v.includes('CouliShadow.card'); }
/** 组件调用 c 的尾随闭包是否包住节点 n。 */
function encloses(c, n) { return !!(c.body && c.body.pos <= n.pos && n.end <= c.body.end); }
/** branch 内包住 n 的组件调用，由内到外。 */
function enclosingContainers(branch, n) {
  const out = collect(branch, (x) => componentName(x) !== '' && encloses(x, n));
  return out.sort((a, b) => (a.body.end - a.body.pos) - (b.body.end - b.body.pos));
}
/** branch 里 this.content() 调用。 */
function contentCalls(branch) {
  return collect(branch, (n) => ts.isCallExpression(n) && isThisMember(n.expression, 'content'));
}
/** branch 块里直接的组件语句（卡片最外层）。 */
function topComponents(branch) {
  const stmts = ts.isBlock(branch) ? Array.from(branch.statements) : [branch];
  return stmts.filter((s) => ts.isExpressionStatement(s)).map((s) => chainHead(unwrap(s.expression)))
    .filter((h) => componentName(h) !== '');
}

function checkCard() {
  if (!exists(CARD)) {
    report('C1-missing', CARD, null, 'CouliCard.ets 不存在（书 §2.2 新件）');
    return;
  }
  const sf = parse(CARD);
  if (!sf) { return; }
  // C1-enum
  let en = null;
  ts.forEachChild(sf, (n) => { if (ts.isEnumDeclaration(n) && n.name.text === 'CouliCardKind') { en = n; } });
  if (!en || !hasExport(en)) {
    report('C1-enum', CARD, en, '缺 export enum CouliCardKind');
  } else {
    const members = en.members.map((m) => nameText(m.name));
    if (members.join(',') !== 'STATIC,TAPPABLE' || en.members.some((m) => m.initializer)) {
      report('C1-enum', CARD, en, 'CouliCardKind 必须恰为 { STATIC, TAPPABLE }（无初值，STATIC 在前），实际 ' + members.join(','));
    }
  }
  const st = findStruct(sf, 'CouliCard');
  if (!st || !hasExport(st)) { report('C1-struct', CARD, st, '缺 export struct CouliCard'); return; }
  if (!decoratorsOf(st).includes('ComponentV2')) { report('C1-struct', CARD, st, 'CouliCard 应为 @ComponentV2'); }
  const want = [
    ['kind', 'Param', 'CouliCardKind', 'CouliCardKind.STATIC'],
    ['press', 'Param', 'PressKind', 'PressKind.BOUNCE'],
    ['disabled', 'Param', 'boolean', 'false'],
    ['a11yText', 'Param', 'string', "''"],
    ['groupAccessibility', 'Param', 'boolean', 'true'],
    ['elevated', 'Param', 'boolean', 'true'],
    // 测试 v2（评审 r1 S3-2 / S3-5）：内边距参数钉住；后续两单要的读屏层级、平铺模式（调用方不能在卡上接属性，SDK 1128）。
    ['cardPadding', 'Param', 'Padding | Length', 'CouliSpacing.space3'],
    ['a11yLevel', 'Param', 'string', "'auto'"],
    ['inset', 'Param', 'boolean', 'false'],
    ['onTap', 'Event', null, null],
    ['content', 'BuilderParam', null, null],
  ];
  for (const [name, deco, type, init] of want) {
    const p = propOf(st, name);
    if (!p) { report('C1-props', CARD, st, 'CouliCard 缺 @' + deco + ' ' + name); continue; }
    if (!decoratorsOf(p).includes(deco)) { report('C1-props', CARD, p, name + ' 应为 @' + deco); }
    if (type && (!p.type || p.type.getText() !== type)) { report('C1-props', CARD, p, name + ' 类型应为 ' + type); }
    if (init && (!p.initializer || compact(p.initializer) !== init.replace(/\s+/g, ''))) {
      report('C1-props', CARD, p, name + ' 默认值应为 ' + init + '（书 §2.2；默认 STATIC / 可用 / 读屏合一 / 不平铺）');
    }
  }
  // C1-click：卡内不自己接点击（点击只经 CouliPressable，见 C3）
  for (const n of collect(sf, (x) => ts.isCallExpression(x) && ts.isPropertyAccessExpression(x.expression) &&
      ['onClick', 'onTouch', 'gesture', 'priorityGesture', 'parallelGesture'].includes(x.expression.name.text))) {
    report('C1-click', CARD, n, 'CouliCard 内出现 .' + n.expression.name.text + '：点击只经 CouliPressable（STATIC 无点击；无反馈的裸点击不许）');
  }
  for (const n of collect(sf, (x) => ts.isIdentifier(x) && ['TapGesture', 'LongPressGesture'].includes(x.text))) {
    report('C1-click', CARD, n, 'CouliCard 内出现 ' + n.text);
  }
  const build = methodOf(st, 'build');
  if (!build || !build.body) { report('C1-branch', CARD, st, 'CouliCard 缺 build()'); return; }
  const splits = collect(build.body, (n) => ts.isIfStatement(n)).map(tappableSplit).filter((x) => x);
  if (splits.length !== 1) {
    report('C1-branch', CARD, build, 'build() 应恰有一个以 this.kind 与 CouliCardKind 单一比较的 if / else 分开两种入口，实际 ' + splits.length);
    report('C2-static-surface', CARD, build, '分不出 STATIC / TAPPABLE 两支，令牌白底 / 圆角 / 阴影无从核对（按违反计）');
    return;
  }
  const { tappable, stat } = splits[0];
  // STATIC 分支
  if (componentCalls(stat, 'CouliPressable').length) { report('C1-static', CARD, stat, 'STATIC 分支不应经 CouliPressable'); }
  if (!callsThis(stat, 'content')) { report('C1-content', CARD, stat, 'STATIC 分支没有调用 this.content()'); }
  // TAPPABLE 分支
  const presses = componentCalls(tappable, 'CouliPressable');
  if (presses.length !== 1) {
    report('C1-tappable', CARD, tappable, 'TAPPABLE 分支应恰经一个 CouliPressable（系统 clickEffect / stateStyles 反馈在其内），实际 ' + presses.length);
  }
  const press = presses[0] || null;
  if (press) {
    const props = objectProps(firstObjectArg(press));
    const forward = [['kind', 'press'], ['disabled', 'disabled'], ['groupAccessibility', 'groupAccessibility'], ['a11yText', 'a11yText']];
    for (const [key, member] of forward) {
      if (!props.has(key) || !isThisMember(props.get(key), member)) {
        report('C1-forward', CARD, press, 'CouliPressable 的 ' + key + ' 应直接传 this.' + member);
      }
    }
    const tap = props.get('onTap');
    const tapOk = tap && (isThisMember(tap, 'onTap') ||
      ((ts.isArrowFunction(unwrap(tap)) || ts.isFunctionExpression(unwrap(tap))) && callsThis(unwrap(tap), 'onTap')));
    if (!tapOk) { report('C1-forward', CARD, press, 'CouliPressable 的 onTap 应转发 this.onTap'); }
    const body = trailingBody(press);
    if (!body || !callsThis(body, 'content')) {
      report('C1-content', CARD, press, 'TAPPABLE：this.content() 应在 CouliPressable 的尾随闭包里（读屏合一、整卡可点）');
    }
    // C2-cover：Pressable 内容里不许再刷底色（会盖住 HIGHLIGHT 的按压色，书 §1 表、§2.2）
    if (body) {
      for (const n of attributeCalls(body, ['backgroundColor', 'background', 'linearGradient', 'backgroundImage'])) {
        report('C2-cover', CARD, n, 'CouliPressable 尾随闭包里有 .' + n.expression.name.text + '：会盖住 HIGHLIGHT 按压底色；白底交给 normalColor 或 Pressable 外层');
      }
    }
    // C2-tappable-surface：白底来自 normalColor: CouliColors.backgroundSurface 或 Pressable 外层链 backgroundColor(同令牌)
    // 自定义组件的尾随闭包后面不能再接属性（SDK 解析器报 1128，实测），所以圆角 / clip / 外层白底看包住它的容器链。
    // 测试 v2：实参按 env 求值（平铺 inset 时白底可以关，非平铺时必须是 surface）。
    const outer = [chainAround(press)];
    for (let p = press.parent; p && p !== tappable; p = p.parent) {
      if (componentName(p) !== '' && p.body && p.body.pos <= press.pos && press.end <= p.body.end) { outer.push(chainAround(p)); }
    }
    const chain = [].concat(...outer);
    const viaNormal = props.has('normalColor') && isVal(evSafe(props.get('normalColor'), NORMAL), 'CouliColors.backgroundSurface');
    const viaChain = isVal(chainVal(chain, 'backgroundColor', NORMAL), 'CouliColors.backgroundSurface');
    if (!viaNormal && !viaChain) {
      report('C2-tappable-surface', CARD, press, 'TAPPABLE 白底应为 CouliColors.backgroundSurface（经 normalColor 或 CouliPressable 外层 backgroundColor；inset=false 时求值）');
    }
    if (!outer.some((ch) => isVal(chainVal(ch, 'borderRadius', NORMAL), 'CouliRadius.card') && chainVal(ch, 'clip', NORMAL) === true)) {
      report('C2-tappable-radius', CARD, press, 'TAPPABLE：包住 CouliPressable 的容器要在同一条链上 borderRadius(CouliRadius.card) + clip(true)（按压底色与白底同圆角）');
    }
    // C2-tappable-corner（评审 r1 S2-1）：回弹缩放的是 Pressable 自己的 Stack，外面的裁剪不跟着缩；卡片圆角要交给 Pressable 的 cornerRadius。
    if (!props.has('cornerRadius') || !isVal(evSafe(props.get('cornerRadius'), NORMAL), 'CouliRadius.card')) {
      report('C2-tappable-corner', CARD, press, 'CouliPressable 应传 cornerRadius: CouliRadius.card（回弹缩放那层自带卡片圆角，按住不露直角白底，评审 r1 S2-1）');
    }
    // C9-inset：平铺时 Pressable 常态底不是白底
    if (props.has('normalColor') && evSafe(props.get('normalColor'), INSET) !== ABSENT) {
      const v = evSafe(props.get('normalColor'), INSET);
      if (v === UNKNOWN || isVal(v, 'CouliColors.backgroundSurface')) {
        report('C9-inset', CARD, press, 'inset=true 时 CouliPressable 的 normalColor 仍是白底（或求不出）：平铺不画白底（商品卡 inset）');
      }
    }
    facts.cardPassesNormalColor = viaNormal;
  }
  // 测试 v2：阴影 —— 极性（C2-elevated）、同链圆角（C2-shadow-radius）、平铺无阴影（C9-inset）、两支在常态下都有（C2-*-shadow）
  const shadows = attributeCalls(build, ['shadow']);
  const branchOf = (n) => (n.pos >= tappable.pos && n.end <= tappable.end) ? tappable : ((n.pos >= stat.pos && n.end <= stat.end) ? stat : build);
  const shadowOn = { tappable: false, stat: false };
  for (const n of shadows) {
    const stop = branchOf(n);
    const chain = chainAround(chainHead(n));
    let unknown = false;
    const valueIn = (env) => {
      try {
        if (!active(n, env, stop)) { return ABSENT; }
      } catch (x) { if (x instanceof Unknown) { unknown = true; return UNKNOWN; } throw x; }
      const v = n.arguments.length === 1 ? evSafe(n.arguments[0], env) : UNKNOWN;
      if (v === UNKNOWN) { unknown = true; }
      return v;
    };
    const normal = valueIn(NORMAL);
    if (hasCardShadow(normal)) {
      if (stop === tappable) { shadowOn.tappable = true; }
      if (stop === stat) { shadowOn.stat = true; }
      if (!isVal(chainVal(chain, 'borderRadius', NORMAL), 'CouliRadius.card')) {
        report('C2-shadow-radius', CARD, n, '带 shadow.card 的那层同一条链上没有 borderRadius(CouliRadius.card)：阴影会是直角（评审 r1 S3-2）');
      }
    }
    for (const env of SHADOW_OFF) {
      if (hasCardShadow(valueIn(env))) {
        report('C2-elevated', CARD, n, 'elevated=false（inset=' + env.inset + '）时仍画 shadow.card：开关极性写反或不受 elevated 控制（评审 r1 S3-2）');
      }
    }
    if (hasCardShadow(valueIn(INSET))) {
      report('C9-inset', CARD, n, 'inset=true 时仍画 shadow.card：平铺不画阴影（商品卡 inset，评审 r1 S3-5）');
    }
    if (unknown) {
      report('C2-elevated', CARD, n, '.shadow 的开关求不出（只认 this.elevated / this.inset 的布尔式与三元 / if）：' + n.getText().slice(0, 120));
    }
  }
  if (!shadowOn.tappable) { report('C2-tappable-shadow', CARD, tappable, 'TAPPABLE 分支在 elevated=true、inset=false 时缺 shadow(…CouliShadow.card…)'); }
  // C2-static-surface：常态（inset=false）下 STATIC 包住内容的容器 surface 白底 + 卡片圆角；带 shadow.card 的那层就是它或包住它
  const statContent = contentCalls(stat);
  const statBoxes = statContent.length ? enclosingContainers(stat, statContent[0]) : [];
  const surfaceBox = statBoxes.find((c) => {
    const ch = chainAround(c);
    return isVal(chainVal(ch, 'backgroundColor', NORMAL), 'CouliColors.backgroundSurface') && isVal(chainVal(ch, 'borderRadius', NORMAL), 'CouliRadius.card');
  });
  if (!surfaceBox) {
    report('C2-static-surface', CARD, stat, 'STATIC 包住内容的容器同一条链应有 backgroundColor(CouliColors.backgroundSurface) + borderRadius(CouliRadius.card)（inset=false 时求值）');
  } else {
    const idx = statBoxes.indexOf(surfaceBox);
    const lifted = statBoxes.slice(idx).some((c) => hasCardShadow(chainVal(chainAround(c), 'shadow', NORMAL)));
    if (!lifted || !shadowOn.stat) {
      report('C2-static-surface', CARD, stat, 'STATIC 的 shadow(…CouliShadow.card…) 应在白底那层或包住它的那层（elevated=true、inset=false 时求值）');
    }
  }
  // C2-padding（评审 r1 S3-2）：两种卡都用 cardPadding，且就在包住内容的最近一层（TAPPABLE 在 Pressable 尾随闭包里，白底盖住内边距）
  for (const [label, branch] of [['TAPPABLE', tappable], ['STATIC', stat]]) {
    const calls = contentCalls(branch);
    const nearest = calls.length ? enclosingContainers(branch, calls[0])[0] : null;
    const pad = nearest ? chainVal(chainAround(nearest), 'padding', NORMAL) : ABSENT;
    if (!isVal(pad, 'this.cardPadding') || (label === 'TAPPABLE' && nearest && componentName(nearest) === 'CouliPressable')) {
      report('C2-padding', CARD, nearest || branch, label + '：包住 this.content() 的最近一层应 .padding(this.cardPadding)（' +
        (label === 'TAPPABLE' ? '在 CouliPressable 尾随闭包里，白底与按压色盖住内边距' : '白底与圆角裁剪那层') + '），实际 ' +
        (pad === ABSENT ? '没有' : (pad === UNKNOWN ? '求不出' : pad)));
    }
  }
  // C9-a11y（评审 r1 S3-5）：STATIC 也处理读屏参数（SKELETON / 商品卡静态外壳）
  const a11yBox = statBoxes.find((c) => {
    const ch = chainAround(c);
    const g = ch.filter((x) => x.name === 'accessibilityGroup');
    const t = ch.filter((x) => x.name === 'accessibilityText');
    return g.length === 1 && g[0].args.length === 1 && isThisMember(g[0].args[0], 'groupAccessibility') &&
      t.length === 1 && t[0].args.some((a) => mentionsThis(a, 'a11yText'));
  });
  if (!a11yBox) {
    report('C9-a11y', CARD, stat, 'STATIC：包住内容的某一层应 .accessibilityGroup(this.groupAccessibility) + .accessibilityText(…this.a11yText…)（静态卡也处理读屏参数，评审 r1 S3-5）');
  }
  // C9-level：两种卡最外层都 .accessibilityLevel(this.a11yLevel)（骨架读屏跳过；调用方不能在卡后接属性）
  for (const [label, branch] of [['TAPPABLE', tappable], ['STATIC', stat]]) {
    const tops = topComponents(branch);
    const ok = tops.length > 0 && tops.every((t) => {
      const lv = chainAround(t).filter((x) => x.name === 'accessibilityLevel');
      return lv.length === 1 && lv[0].args.length === 1 && isThisMember(lv[0].args[0], 'a11yLevel');
    });
    if (!ok) {
      report('C9-level', CARD, branch, label + '：卡片最外层应 .accessibilityLevel(this.a11yLevel)（SKELETON 传 no-hide-descendants；卡后不能接属性，SDK 1128）');
    }
  }
  // C9-clip：STATIC 常态下内容按卡片圆角裁剪；平铺时不按卡片圆角裁剪（商品卡 inset 的图不被切角）
  const clipped = (env) => statBoxes.some((c) => {
    const ch = chainAround(c);
    return isVal(chainVal(ch, 'borderRadius', env), 'CouliRadius.card') && chainVal(ch, 'clip', env) === true;
  });
  const clipUnknown = statBoxes.some((c) => [NORMAL, INSET].some((env) => chainVal(chainAround(c), 'clip', env) === UNKNOWN));
  if (!clipped(NORMAL) || clipUnknown) {
    report('C9-clip', CARD, stat, 'STATIC：包住内容的某一层应 borderRadius(CouliRadius.card) + clip(true)（内容贴边时不盖住圆角，评审 r1 S3-5）');
  }
  if (clipped(INSET)) {
    report('C9-clip', CARD, stat, 'STATIC inset=true 时仍按卡片圆角裁剪内容（平铺件不画圆角，ProductCard gridCard inset 为 0 圆角）');
  }
  // C9-inset：平铺时整卡没有 surface 白底
  for (const n of attributeCalls(build, ['backgroundColor'])) {
    let v;
    try { v = active(n, INSET, branchOf(n)) ? evSafe(n.arguments[0], INSET) : ABSENT; } catch (x) { if (x instanceof Unknown) { v = UNKNOWN; } else { throw x; } }
    if (v === UNKNOWN || isVal(v, 'CouliColors.backgroundSurface')) {
      report('C9-inset', CARD, n, 'inset=true 时 .backgroundColor 仍是 surface 白底（或求不出）：平铺不画白底（商品卡 inset，评审 r1 S3-5）');
    }
  }
  // v1 C2-elevated：每处 shadow 都受 this.elevated 控制（实参里用到，或在以 this.elevated 为条件的 if 里）
  for (const n of shadows) {
    let guarded = n.arguments.some((a) => mentionsThis(a, 'elevated'));
    for (let p = n.parent; p && !guarded && p !== build; p = p.parent) {
      if (ts.isIfStatement(p) && mentionsThis(p.expression, 'elevated')) { guarded = true; }
    }
    if (!guarded) { report('C2-elevated', CARD, n, '.shadow 不受 this.elevated 控制（elevated=false 时应去阴影）'); }
  }
  if (!mentionsThis(build, 'elevated')) { report('C2-elevated', CARD, build, 'build() 没用 this.elevated（elevated=false 时去阴影）'); }
  // C2-literal：全文件无颜色字面量
  walk(sf, (n) => {
    if ((ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)) &&
        /^(#[0-9a-fA-F]{3,8}|rgba?\(.*\))$/.test(n.text)) {
      report('C2-literal', CARD, n, '颜色字面量 ' + n.getText());
    }
    if (ts.isNumericLiteral(n) && /^0x[0-9a-fA-F]{6,8}$/i.test(n.getText())) { report('C2-literal', CARD, n, '颜色字面量 ' + n.getText()); }
    if (ts.isPropertyAccessExpression(n) && n.expression.getText() === 'Color' && n.name.text !== 'Transparent') {
      report('C2-literal', CARD, n, '具名颜色 ' + n.getText() + '（颜色只来自 CouliColors）');
    }
    if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === '$r') {
      report('C2-literal', CARD, n, '卡内直接 $r 资源（颜色 / 圆角 / 阴影只经令牌类）');
    }
  });
  // C2-attr：样式属性实参只来自令牌类 / this 参数，无数字、字符串字面量
  const allowed = { backgroundColor: ['CouliColors', 'this', 'Color.Transparent'], borderColor: ['CouliColors', 'this'],
    borderRadius: ['CouliRadius', 'this'], shadow: ['CouliShadow', 'this', 'undefined'], border: ['CouliColors', 'CouliRadius', 'this'] };
  for (const n of attributeCalls(sf, Object.keys(allowed))) {
    const name = n.expression.name.text;
    for (const a of n.arguments) {
      const { roots, literals } = argReferences(a);
      const bad = [...roots].filter((r) => !allowed[name].includes(r));
      if (literals.length || bad.length) {
        report('C2-attr', CARD, n, '.' + name + '(' + a.getText() + ') 含字面量 / 非令牌来源：' + [...literals, ...bad].join(', '));
      }
    }
  }
  // C4
  for (const n of collect(sf, (x) => ts.isIdentifier(x) && ['CouliHaptics', 'vibrator', 'HapticPlan'].includes(x.text))) {
    report('C4-haptics', CARD, n, 'CouliCard 出现 ' + n.text + '（README §3.2：卡片按压不加触感）');
  }
  for (const n of collect(sf, (x) => (ts.isStringLiteral(x) || ts.isNoSubstitutionTemplateLiteral(x)) && /^(motion\.|--motion)/.test(x.text))) {
    report('C4-motion-token', CARD, n, '读了 motion 令牌 ' + n.getText() + '（D10-838）');
  }
}

function checkIndex() {
  const sf = parse(INDEX);
  if (!sf) { if (!exists(INDEX)) { incomplete.push(INDEX + '：文件不存在，无法判定'); } return; }
  const names = new Set();
  ts.forEachChild(sf, (n) => {
    if (ts.isExportDeclaration(n) && n.moduleSpecifier && ts.isStringLiteral(n.moduleSpecifier) &&
        n.moduleSpecifier.text === CARD_MODULE && n.exportClause && ts.isNamedExports(n.exportClause)) {
      for (const e of n.exportClause.elements) { names.add(e.name.text); }
    }
  });
  for (const want of ['CouliCard', 'CouliCardKind']) {
    if (!names.has(want)) { report('C1-index', INDEX, null, 'Index.ets 未从 ' + CARD_MODULE + ' 导出 ' + want); }
  }
  // PressKind 也要能从 designsystem 取到（目录样例传 press）。
  let press = false;
  ts.forEachChild(sf, (n) => {
    if (ts.isExportDeclaration(n) && n.exportClause && ts.isNamedExports(n.exportClause) &&
        n.exportClause.elements.some((e) => e.name.text === 'PressKind')) { press = true; }
  });
  if (!press) { report('C1-index', INDEX, null, 'Index.ets 未导出 PressKind'); }
}

// ---------------------------------------------------------------- C3 / C4：CouliPressable（F-HM-98）

/** 「不禁用」：!this.disabled。 */
function isNotDisabled(node) {
  const c = unwrap(node);
  return ts.isPrefixUnaryExpression(c) && c.operator === ts.SyntaxKind.ExclamationToken && isThisMember(c.operand, 'disabled');
}

/** this.onTap() 是否被禁用态守住：祖先 if (!this.disabled) 的 then；或同块前面有 if (this.disabled) return。 */
function guardedByEnabled(call, closure) {
  for (let p = call.parent, child = call; p && p !== closure.parent; child = p, p = p.parent) {
    if (ts.isIfStatement(p) && child === p.thenStatement && isNotDisabled(p.expression)) { return true; }
    if (ts.isBlock(p)) {
      const idx = p.statements.indexOf(child);
      for (let i = 0; i < idx; i++) {
        const s = p.statements[i];
        if (ts.isIfStatement(s) && !s.elseStatement && isThisMember(s.expression, 'disabled')) {
          const then = s.thenStatement;
          const returns = ts.isReturnStatement(then) || (ts.isBlock(then) && then.statements.length === 1 && ts.isReturnStatement(then.statements[0]));
          if (returns) { return true; }
        }
      }
    }
  }
  return false;
}

function checkPressable() {
  if (!exists(PRESS)) { incomplete.push(PRESS + '：文件不存在，无法判定'); return; }
  const sf = parse(PRESS);
  if (!sf) { return; }
  const st = findStruct(sf, 'CouliPressable');
  if (!st) { report('C3-struct', PRESS, null, '缺 struct CouliPressable'); return; }
  const want = [['disabled', 'boolean', 'false'], ['groupAccessibility', 'boolean', 'true'], ['a11yText', 'string', "''"],
    ['normalColor', 'ResourceColor', 'Color.Transparent'], ['cornerRadius', 'Length', '0']];
  for (const [name, type, init] of want) {
    const p = propOf(st, name);
    if (!p) { report('C3-props', PRESS, st, 'CouliPressable 缺 @Param ' + name + (name === 'cornerRadius'
      ? '（评审 r1 S2-1：按压 / 缩放那层的圆角，默认 0）' : '（F-HM-98 / 书 §2.1；enabled 与 CustomComponent.enabled 冲突，改 disabled）')); continue; }
    if (!decoratorsOf(p).includes('Param')) { report('C3-props', PRESS, p, name + ' 应为 @Param'); }
    if (!p.type || p.type.getText() !== type) { report('C3-props', PRESS, p, name + ' 类型应为 ' + type); }
    if (!p.initializer || compact(p.initializer) !== init.replace(/\s+/g, '')) { report('C3-props', PRESS, p, name + ' 默认值应为 ' + init); }
  }
  const clicks = attributeCalls(st, ['onClick']);
  facts.pressableClickChains = clicks.length;
  if (clicks.length < 2) { report('C3-branches', PRESS, st, 'CouliPressable 应在 BOUNCE / HIGHLIGHT 两个分支各有一条 .onClick 链，实际 ' + clicks.length); }
  const highlightChains = [];
  const bounceChains = [];
  for (const click of clicks) {
    const chain = chainAround(chainHead(click));
    const names = chain.map((c) => c.name);
    if (names.includes('stateStyles')) { highlightChains.push(chain); }
    if (names.includes('clickEffect')) { bounceChains.push(chain); }
    const enabled = chain.filter((c) => c.name === 'enabled');
    if (enabled.length !== 1 || enabled[0].args.length !== 1 || !isNotDisabled(enabled[0].args[0])) {
      report('C3-enabled', PRESS, click, '.onClick 同链应恰有 .enabled(!this.disabled)（禁用时系统不给按压反馈，F-HM-98 / S2-2）');
    }
    const group = chain.filter((c) => c.name === 'accessibilityGroup');
    if (group.length !== 1 || group[0].args.length < 1 || !isThisMember(group[0].args[0], 'groupAccessibility')) {
      report('C3-group', PRESS, click, '.onClick 同链应有 .accessibilityGroup(this.groupAccessibility)（读屏合一项，F-HM-98 / S2-1）');
    }
    // C3-corner（测试 v2，评审 r1 S2-1）：clickEffect 缩放的就是这条链的 Stack；圆角与裁剪必须在这一层（外层裁剪不跟着缩）。
    const radius = chain.filter((c) => c.name === 'borderRadius');
    const clip = chain.filter((c) => c.name === 'clip');
    if (radius.length !== 1 || radius[0].args.length !== 1 || !isThisMember(radius[0].args[0], 'cornerRadius') ||
        clip.length !== 1 || clip[0].args.length !== 1 || compact(clip[0].args[0]) !== 'true') {
      report('C3-corner', PRESS, click, '.onClick 同链（按压 / 缩放那层）应有 .borderRadius(this.cornerRadius) + .clip(true)（回弹缩小时不露直角底，评审 r1 S2-1）');
    }
    const text = chain.filter((c) => c.name === 'accessibilityText');
    if (text.length !== 1 || !text[0].args.some((a) => mentionsThis(a, 'a11yText'))) {
      report('C3-text', PRESS, click, '.onClick 同链应有 .accessibilityText(…this.a11yText…)（整卡读屏名）');
    }
    const handler = click.arguments[0] ? unwrap(click.arguments[0]) : null;
    const taps = handler ? collect(handler, (n) => ts.isCallExpression(n) && isThisMember(n.expression, 'onTap')) : [];
    if (!taps.length) {
      report('C3-guard', PRESS, click, '.onClick 闭包里没有调用 this.onTap()（FEEL-KIT C5 同口径，判定不能把 onTap 挪出 onClick）');
    }
    for (const t of taps) {
      if (!guardedByEnabled(t, handler)) {
        report('C3-guard', PRESS, t, 'this.onTap() 没被禁用态守住（应在 if (!this.disabled) 内，或前面 if (this.disabled) return）');
      }
    }
  }
  if (highlightChains.length !== 1) { report('C3-branches', PRESS, st, 'HIGHLIGHT（stateStyles）链应恰 1 条，实际 ' + highlightChains.length); }
  if (bounceChains.length !== 1) { report('C3-branches', PRESS, st, 'BOUNCE（clickEffect）链应恰 1 条，实际 ' + bounceChains.length); }
  for (const chain of highlightChains) {
    if (!chain.some((c) => c.args.some((a) => mentionsThis(a, 'normalColor')))) {
      report('C3-normal', PRESS, chain[0].node, 'HIGHLIGHT 链的常态底色应取 this.normalColor（书 §2.1）');
    }
  }
  facts.bounceUsesNormal = bounceChains.some((chain) => chain.some((c) => c.args.some((a) => mentionsThis(a, 'normalColor'))));
  for (const n of collect(sf, (x) => ts.isIdentifier(x) && ['CouliHaptics', 'vibrator', 'HapticPlan'].includes(x.text))) {
    report('C4-haptics', PRESS, n, 'CouliPressable 出现 ' + n.text + '（README §3.2：按压不加触感）');
  }
  for (const n of collect(sf, (x) => (ts.isStringLiteral(x) || ts.isNoSubstitutionTemplateLiteral(x)) && /^(motion\.|--motion)/.test(x.text))) {
    report('C4-motion-token', PRESS, n, '读了 motion 令牌 ' + n.getText() + '（D10-838）');
  }
}

// ---------------------------------------------------------------- C6：目录

function stringArray(node) {
  const e = unwrap(node);
  if (!e || !ts.isArrayLiteralExpression(e)) { return null; }
  const out = [];
  for (const x of e.elements) {
    if (!ts.isStringLiteral(x) && !ts.isNoSubstitutionTemplateLiteral(x)) { return null; }
    out.push(x.text);
  }
  return out;
}

function checkManifest() {
  const sf = parse(MANIFEST);
  if (!sf) { if (!exists(MANIFEST)) { incomplete.push(MANIFEST + '：文件不存在，无法判定'); } return; }
  const calls = collect(sf, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'c' &&
    n.arguments.length >= 5 && ts.isStringLiteral(n.arguments[0]) && n.arguments[0].text === 'CouliCard');
  if (calls.length !== 1) { report('C6-manifest', MANIFEST, null, "CatalogManifest 应恰有一条 c('CouliCard', …)，实际 " + calls.length); return; }
  const call = calls[0];
  if (call.arguments[1].getText() !== 'GROUP_LISTS') { report('C6-manifest', MANIFEST, call, 'CouliCard 应在 GROUP_LISTS（§3.5 列表与展示）'); }
  if (call.arguments[2].getText() !== 'KIND_L2') { report('C6-manifest', MANIFEST, call, 'CouliCard 应标 KIND_L2'); }
  const matrices = unwrap(call.arguments[4]);
  const cases = [];
  let ok = matrices && ts.isArrayLiteralExpression(matrices);
  if (ok) {
    for (const m of matrices.elements) {
      if (!ts.isCallExpression(m) || m.expression.getText() !== 'm' || m.arguments.length !== 2) { ok = false; break; }
      const vs = stringArray(m.arguments[0]);
      const ss = stringArray(m.arguments[1]);
      if (!vs || !ss) { ok = false; break; }
      for (const v of vs) { for (const s of ss) { cases.push(v + '/' + s); } }
    }
  }
  facts.manifestCases = ok ? cases : null;
  const got = ok ? [...cases].sort().join(' ') : '（矩阵不是字面量 m([...], [...])）';
  if (!ok || got !== [...EXPECTED_CASES].sort().join(' ') || new Set(cases).size !== cases.length) {
    report('C6-manifest', MANIFEST, call, 'CouliCard 矩阵应为 static / tappable-bounce / tappable-highlight × default / pressed / disabled + list-group × default（10 例），实际 ' + got);
  }
}

function checkSamples() {
  const sf = parse(SAMPLES);
  if (!sf) { if (!exists(SAMPLES)) { incomplete.push(SAMPLES + '：文件不存在，无法判定'); } return; }
  const view = findStruct(sf, 'CatalogSampleView');
  if (!view) { incomplete.push(SAMPLES + '：缺 struct CatalogSampleView'); return; }
  const build = methodOf(view, 'build');
  let branch = null;
  for (const ifs of collect(build, (n) => ts.isIfStatement(n))) {
    const c = unwrap(ifs.expression);
    if (ts.isBinaryExpression(c) && c.operatorToken.kind === ts.SyntaxKind.EqualsEqualsEqualsToken &&
        isThisMember(c.left, 'component') && ts.isStringLiteral(c.right) && c.right.text === 'CouliCard') { branch = ifs.thenStatement; }
  }
  if (!branch) { report('C6-sample-branch', SAMPLES, view, "CatalogSampleView.build 缺单独的 if (this.component === 'CouliCard') 分支（新样例分支，不改已有分支）"); return; }
  // 分支里画的：直接 CouliCard，或本文件里的一个样例 struct
  let scope = null;
  const local = collect(branch, (n) => componentName(n) !== '' && findStruct(sf, componentName(n)));
  if (local.length === 1) { scope = findStruct(sf, componentName(local[0])); }
  else if (componentCalls(branch, 'CouliCard').length) { scope = branch; }
  if (!scope) { report('C6-sample-branch', SAMPLES, branch, 'CouliCard 分支应直接画 CouliCard 或调用本文件的一个样例 struct'); return; }
  const cards = componentCalls(scope, 'CouliCard');
  if (!cards.length) { report('C6-sample-card', SAMPLES, scope, 'CouliCard 样例里没有真实 CouliCard'); }
  for (const card of cards) {
    const props = objectProps(firstObjectArg(card));
    for (const key of ['kind', 'press', 'disabled', 'onTap']) {
      if (!props.has(key)) { report('C6-sample-card', SAMPLES, card, 'CouliCard 样例没传 ' + key + '（三种变体 × 禁用 / 点击计数）'); }
    }
    if (!trailingBody(card)) { report('C6-sample-card', SAMPLES, card, 'CouliCard 样例没有内容（尾随闭包）'); }
  }
  const groups = componentCalls(scope, 'ListItemGroup').filter((g) => {
    const p = objectProps(firstObjectArg(g));
    return p.has('style') && compact(p.get('style')) === 'ListItemGroupStyle.CARD';
  });
  const items = componentCalls(scope, 'ListItem').filter((g) => {
    const p = objectProps(firstObjectArg(g));
    return p.has('style') && compact(p.get('style')) === 'ListItemStyle.CARD';
  });
  if (!groups.length || items.length < 2) {
    report('C6-sample-list', SAMPLES, scope, '系统分组列表样例应有 ListItemGroup({ style: ListItemGroupStyle.CARD }) 且其下至少 2 个 ListItem({ style: ListItemStyle.CARD })（书 §2.2）');
  }
  for (const n of attributeCalls(scope, ['backgroundColor', 'background'])) {
    report('C6-sample-nobg', SAMPLES, n, 'CouliCard 样例里有 .' + n.expression.name.text + '：白底只能来自 CouliCard 本身（设备取色才有意义）');
  }
}

// ---------------------------------------------------------------- C7：登记（AST 部分）

function checkRegistered(rel, importPath, fnRule) {
  const sf = parse(rel);
  if (!sf) { if (!exists(rel)) { incomplete.push(rel + '：文件不存在，无法判定'); } return; }
  let local = null;
  ts.forEachChild(sf, (n) => {
    if (ts.isImportDeclaration(n) && ts.isStringLiteral(n.moduleSpecifier) && n.moduleSpecifier.text === importPath &&
        n.importClause && n.importClause.name) { local = n.importClause.name.text; }
  });
  if (!local) { report(fnRule, rel, null, rel + " 没有 import … from '" + importPath + "'"); return; }
  let suite = null;
  ts.forEachChild(sf, (n) => { if (ts.isFunctionDeclaration(n) && n.name && n.name.text === 'testsuite') { suite = n; } });
  if (!suite || !suite.body) { incomplete.push(rel + '：缺 testsuite()'); return; }
  const direct = suite.body.statements.filter((s) => ts.isExpressionStatement(s) && ts.isCallExpression(s.expression) &&
    ts.isIdentifier(s.expression.expression) && s.expression.expression.text === local && s.expression.arguments.length === 0);
  const anywhere = collect(suite.body, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === local);
  if (direct.length !== 1 || anywhere.length !== 1) {
    report(fnRule, rel, suite, 'testsuite() 应在顶层恰调用一次 ' + local + '()，实际顶层 ' + direct.length + ' / 全部 ' + anywhere.length);
  }
}

function deviceSuiteFacts() {
  const sf = parse(DEVICE_SUITE);
  if (!sf) { facts.deviceConst = null; facts.deviceIts = null; return; }
  let list = null;
  walk(sf, (n) => {
    if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === 'L2CARD_DEVICE_CASES' && n.initializer) {
      list = stringArray(n.initializer);
    }
  });
  facts.deviceConst = list;
  facts.deviceIts = collect(sf, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'it' &&
    n.arguments.length >= 1 && ts.isStringLiteral(n.arguments[0])).map((n) => n.arguments[0].text);
  let describes = collect(sf, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'describe' &&
    n.arguments.length >= 1 && ts.isStringLiteral(n.arguments[0])).map((n) => n.arguments[0].text);
  facts.deviceDescribes = describes;
}

// ---------------------------------------------------------------- C8：页面不用 CouliCard

function checkPages() {
  for (const rel of input.scan || []) {
    const sf = parse(rel);
    if (!sf) { continue; }
    for (const n of collect(sf, (x) => ts.isIdentifier(x) && (x.text === 'CouliCard' || x.text === 'CouliCardKind'))) {
      report('C8-pages', rel, n, '页面 / 功能模块用了 ' + n.text + '（书 §2.4：本单不改任何页面，58 处内联卡在流程单换）');
    }
  }
}

checkCard();
checkIndex();
checkPressable();
if (facts.cardPassesNormalColor && facts.bounceUsesNormal === false) {
  report('C2-bounce-surface', PRESS, null, 'CouliCard 经 normalColor 给白底，但 CouliPressable 的 BOUNCE 链不用 this.normalColor（回弹卡会丢白底）');
}
checkManifest();
checkSamples();
checkRegistered(ENTRY_LIST, './Ds02L2Ui.test', 'C7-entry-list');
checkRegistered(DS_LIST, './L2Card.test', 'C7-ds-list');
deviceSuiteFacts();
checkPages();
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete, facts: facts }));
