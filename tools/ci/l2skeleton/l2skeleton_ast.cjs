#!/usr/bin/env node
// HM-L2-SKELETON 宿主守卫的解析部分（测试作者 v1，新鲜独立 Claude；由 check_l2_skeleton.py 调用，不单独跑）。
// 照 tools/ci/l2card/l2card_ast.cjs：用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS，判定全部走 AST（struct / 装饰器 / 属性链 / if 分支 /
// 组件尾随闭包），不用正则切块；注释与字符串里的字不算。
//   用法：node l2skeleton_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>" | null}, "scan": ["<相对路径>", ...], "baseline": {"index": {...}, "logic": {...}}}
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."], "facts": {...}}
// 规则编号（NATIVE/HM-L2-BATCH1/brief-SKELETON.md §3 S1–S6，加测试作者补的 K6–K9）：
//   K1 挪件：components/Skeleton.ets 五个 @ComponentV2 export struct；SkeletonBlock 参数不变；ProductCard.ets 无骨架残留（S1）
//   K2 Index.ets 导出名集合 = 03570b8 基线 + 4 个新名（S2）
//   K3 SkeletonGate 纯逻辑：进 Logic.ets；无 @kit / $r / 组件；300 / 300 常量且被用；时钟只经注入；类内不读减弱动态（S3、逻辑 7）
//   K4 微光：SkeletonBlock 有 linearGradient + 无限循环动画（iterations: -1，系统曲线）；减弱动态（CouliMotion.reduced() 为真）时
//      该动画不可达、未减弱时可达；aboutToDisappear 收尾；底色 background.muted；不读 motion 令牌（S4）
//   K5 读屏跳过：SkeletonBlock no-hide-descendants；三种形状卡外壳是静态 CouliCard + a11yLevel 'no-hide-descendants'；无颜色字面量（S5）
//   K6 SkeletonHost：loading / skeleton / content 参数；内部 SkeletonGate + 定时器（离开时清）；@Monitor('loading')；build 不绕过门控
//      v3（HM-BATCH1-DEVFIX，tests-harmony-v4-handback.md §3.4）：SHOWING 分支里的上屏回调（SDK common.d.ts CommonMethod 的 onAppear /
//      onAttach / onAreaChange / onVisibleAreaChange）走到 this.<门控字段>.markOnScreen()（K6-on-screen）；K3 门控类须有 markOnScreen()
//      v4（HM-BATCH1-DEVFIX 评审 Codex S2-1）：K6-on-screen / monitor / timer / tick / clear-first / gate 这些钉调用的规则只认会执行的调用
//      （liveCalls / isDeadAt，照 a11yhome_ast.cjs reachableCalls：常量为假的分支、退出语句之后、从不调用的闭包与局部函数都不算）
//   K7 目录：Skeleton 矩阵 + host × gated；样例画真实骨架件与 SkeletonHost，样例 id 约定（AST 部分；inventory 在 py）
//   K8 登记：designsystem List.test 顶层恰调用一次 skeletonGateTest；Ds02L2Ui 的 L2SKEL 段（名单比对在 py）
//   K9 页面不动：页面 / 功能模块不用新件；现有 7 处骨架调用（3 个文件）原样
'use strict';
const fs = require('fs');
const path = require('path');

const SKEL = 'common/designsystem/src/main/ets/components/Skeleton.ets';
const GATE = 'common/designsystem/src/main/ets/logic/SkeletonGate.ets';
const PRODUCT = 'common/designsystem/src/main/ets/components/ProductCard.ets';
const INDEX = 'common/designsystem/Index.ets';
const LOGIC = 'common/designsystem/Logic.ets';
const MANIFEST = 'entry/src/staging/ets/catalog/CatalogManifest.ets';
const SAMPLES = 'entry/src/staging/ets/catalog/CatalogSampleViews.ets';
const DS_LIST = 'common/designsystem/src/test/List.test.ets';
const DEVICE_SUITE = 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets';

const SKEL_MODULE = './src/main/ets/components/Skeleton';
const GATE_MODULE = './src/main/ets/logic/SkeletonGate';
const STRUCTS = ['SkeletonBlock', 'SkeletonProductCard', 'SkeletonOrderCard', 'SkeletonWalletCard', 'SkeletonHost'];
const SHAPES = ['SkeletonProductCard', 'SkeletonOrderCard', 'SkeletonWalletCard'];
const INDEX_NEW = ['SkeletonOrderCard', 'SkeletonWalletCard', 'SkeletonHost', 'SkeletonGate'];
const INDEX_OPTIONAL = ['SkeletonPhase', 'SkeletonClock', 'shimmerEnabled'];
const LOGIC_NEW = ['SkeletonGate', 'SkeletonPhase', 'SkeletonClock', 'shimmerEnabled'];
const V1 = ['Component', 'State', 'Prop', 'Link', 'Provide', 'Consume', 'ObjectLink', 'Observed', 'Watch', 'StorageLink', 'StorageProp',
  'LocalStorageLink', 'LocalStorageProp', 'Track'];
const LIFECYCLE = ['build', 'aboutToAppear', 'onDidBuild', 'aboutToReuse', 'onPageShow'];
// 书 §3 S5 / §1 表：现有页面调用 7 处 / 3 文件（3 处页面不动，流程单迁 SkeletonHost）。
const PAGE_CALLS = {
  'entry/src/main/ets/trade/AuthManagePage.ets': { SkeletonBlock: 2 },
  'features/product/src/main/ets/ProductDetailView.ets': { SkeletonBlock: 4 },
  'features/search/src/main/ets/SearchView.ets': { SkeletonProductCard: 1 },
};
const PAGE_FORBIDDEN = ['SkeletonHost', 'SkeletonGate', 'SkeletonOrderCard', 'SkeletonWalletCard', 'SkeletonPhase', 'shimmerEnabled'];
const SAMPLE_IDS = ['catalog-skeleton-host/short', 'catalog-skeleton-host/mid', 'catalog-skeleton-host/slow',
  'catalog-skeleton-host/skeleton', 'catalog-skeleton-host/content', 'catalog-events/Skeleton/host/gated'];

const tsDir = process.argv[2];
if (!tsDir) { console.error('l2skeleton_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('l2skeleton_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('l2skeleton_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
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
function need(rel) {
  const sf = parse(rel);
  if (!sf && !exists(rel)) { incomplete.push(rel + '：文件不存在，无法判定'); }
  return sf;
}

function lineOf(node) { return node.getSourceFile().getLineAndCharacterOfPosition(node.getStart()).line + 1; }
function report(rule, file, node, msg) { violations.push({ rule: rule, file: file, line: node ? lineOf(node) : 0, msg: msg }); }
function walk(node, visit) { visit(node); ts.forEachChild(node, (c) => walk(c, visit)); }
function collect(node, pred) { const out = []; walk(node, (n) => { if (pred(n)) { out.push(n); } }); return out; }
function compact(node) { return node.getText().replace(/\s+/g, ''); }
function unwrap(e) {
  while (e && (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isNonNullExpression(e))) { e = e.expression; }
  return e;
}
function nameText(n) { return n && (ts.isIdentifier(n) || ts.isStringLiteral(n)) ? n.text : ''; }
function decoratorNodes(node) {
  const list = ts.getAllDecorators ? ts.getAllDecorators(node) : (node.decorators || []);
  return Array.from(list || []);
}
function decoratorNames(node) {
  return decoratorNodes(node).map((d) => (ts.isCallExpression(d.expression) ? d.expression.expression : d.expression).getText());
}
function hasExport(node) { return (node.modifiers || []).some((m) => m.kind === ts.SyntaxKind.ExportKeyword); }
function topLevel(sf, pred) { const out = []; ts.forEachChild(sf, (n) => { if (pred(n)) { out.push(n); } }); return out; }
function findStruct(sf, name) { return topLevel(sf, (n) => ts.isStructDeclaration(n) && n.name && n.name.text === name)[0] || null; }
function methodOf(owner, name) { return owner.members.find((m) => ts.isMethodDeclaration(m) && nameText(m.name) === name) || null; }
function propOf(owner, name) { return owner.members.find((m) => ts.isPropertyDeclaration(m) && nameText(m.name) === name) || null; }
function componentName(n) {
  if (ts.isEtsComponentExpression && ts.isEtsComponentExpression(n)) { return n.expression.getText(); }
  if (ts.isCallExpression(n) && ts.isIdentifier(n.expression)) { return n.expression.text; }
  return '';
}
function componentCalls(root, name) { return collect(root, (n) => componentName(n) === name); }
function firstObjectArg(call) {
  const a = Array.from(call.arguments || []);
  return a.length > 0 && ts.isObjectLiteralExpression(unwrap(a[0])) ? unwrap(a[0]) : null;
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
function attributeCalls(root, names) {
  return collect(root, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && names.includes(n.expression.name.text));
}
function isThisMember(node, member) {
  const e = unwrap(node);
  return !!e && ts.isPropertyAccessExpression(e) && e.expression.kind === ts.SyntaxKind.ThisKeyword && (!member || e.name.text === member);
}
function methodCalls(root, name) {
  return collect(root, (n) => ts.isCallExpression(n) && ((ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === name) ||
    (ts.isIdentifier(n.expression) && n.expression.text === name)));
}
function stringValue(e) { e = unwrap(e); return e && (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) ? e.text : null; }
function isNumber(e, value) {
  e = unwrap(e);
  if (!e) { return false; }
  if (ts.isNumericLiteral(e)) { return Number(e.text) === value; }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.MinusToken && ts.isNumericLiteral(e.operand)) {
    return -Number(e.operand.text) === value;
  }
  return false;
}
function isFunctionLike(n) {
  return ts.isMethodDeclaration(n) || ts.isFunctionDeclaration(n) || ts.isConstructorDeclaration(n) || ts.isGetAccessorDeclaration(n) ||
    ts.isSetAccessorDeclaration(n);
}
function motionTokens(sf, rel) {
  for (const n of collect(sf, (x) => (ts.isStringLiteral(x) || ts.isNoSubstitutionTemplateLiteral(x)) && /^(motion\.|--motion)/.test(x.text))) {
    report('K4-motion-token', rel, n, '读了 motion 令牌 ' + n.getText() + '（D10-838：原生用系统曲线，不读 motion 令牌）');
  }
}

// ---------------------------------------------------------------- 减弱动态可达性（K4-reduced / K4-dead）
// 三值求值：true / false / null（求不出）。R = CouliMotion.reduced() 的假设值。
// 认得：CouliMotion.reduced()、shimmerEnabled(x)（= !x，书 §3 逻辑 8 的契约，函数体由 run-logic 钉）、MotionPolicy.press 之外的一概不认；
// ! / && / || / 括号 / true false / 与布尔字面量 ===、!==；局部 const；本 struct 的 this.<字段>（初值与全部 this.<字段> = … 赋值同值才算定值）。
function evalCond(e, R, owner, depth) {
  e = unwrap(e);
  if (!e || depth > 8) { return null; }
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isCallExpression(e)) {
    const callee = compact(e.expression);
    if (callee === 'CouliMotion.reduced' && e.arguments.length === 0) { return R; }
    if (callee === 'shimmerEnabled' && e.arguments.length === 1) {
      const v = evalCond(e.arguments[0], R, owner, depth + 1);
      return v === null ? null : !v;
    }
    return null;
  }
  if (ts.isPrefixUnaryExpression(e) && e.operator === ts.SyntaxKind.ExclamationToken) {
    const v = evalCond(e.operand, R, owner, depth + 1);
    return v === null ? null : !v;
  }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    if (op === ts.SyntaxKind.AmpersandAmpersandToken || op === ts.SyntaxKind.BarBarToken) {
      const a = evalCond(e.left, R, owner, depth + 1);
      const b = evalCond(e.right, R, owner, depth + 1);
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
      const lit = [e.left, e.right].map(unwrap).find((x) => x.kind === ts.SyntaxKind.TrueKeyword || x.kind === ts.SyntaxKind.FalseKeyword);
      if (!lit) { return null; }
      const other = unwrap(e.left) === lit ? e.right : e.left;
      const v = evalCond(other, R, owner, depth + 1);
      if (v === null) { return null; }
      const same = v === (lit.kind === ts.SyntaxKind.TrueKeyword);
      return eq ? same : !same;
    }
    return null;
  }
  if (ts.isIdentifier(e)) {
    const init = lookupLocal(e);
    return init ? evalCond(init, R, owner, depth + 1) : null;
  }
  if (isThisMember(e) && owner) {
    const field = unwrap(e).name.text;
    const values = [];
    const prop = propOf(owner, field);
    if (prop && prop.initializer) { values.push(prop.initializer); }
    for (const a of collect(owner, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      isThisMember(n.left, field))) { values.push(a.right); }
    if (!values.length) { return null; }
    const got = values.map((v) => evalCond(v, R, owner, depth + 1));
    if (got.every((v) => v === true)) { return true; }
    if (got.every((v) => v === false)) { return false; }
    return null;
  }
  return null;
}
function lookupLocal(id) {
  let cur = id.parent;
  while (cur && !isFunctionLike(cur) && !ts.isSourceFile(cur)) {
    if (ts.isBlock(cur)) {
      for (const st of cur.statements) {
        if (!ts.isVariableStatement(st)) { continue; }
        for (const d of st.declarationList.declarations) {
          if (ts.isIdentifier(d.name) && d.name.text === id.text && d.initializer) { return d.initializer; }
        }
      }
    }
    cur = cur.parent;
  }
  return null;
}
function exits(st) {
  if (!st) { return false; }
  if (ts.isReturnStatement(st) || ts.isThrowStatement(st)) { return true; }
  if (ts.isBlock(st)) { return st.statements.length > 0 && exits(st.statements[st.statements.length - 1]); }
  return false;
}
/** node 在 R 下是否必然不可达（向上到所在方法；方法不是生命周期 / build 时再看本 struct 里所有 this.<方法>() 调用处）。 */
function blocked(node, R, owner, depth) {
  if (depth > 4) { return false; }
  let child = node;
  let cur = node.parent;
  while (cur) {
    if (ts.isIfStatement(cur)) {
      const v = evalCond(cur.expression, R, owner, 0);
      if (child === cur.thenStatement && v === false) { return true; }
      if (child === cur.elseStatement && v === true) { return true; }
    } else if (ts.isConditionalExpression(cur)) {
      const v = evalCond(cur.condition, R, owner, 0);
      if (child === cur.whenTrue && v === false) { return true; }
      if (child === cur.whenFalse && v === true) { return true; }
    } else if (ts.isBinaryExpression(cur) && child === cur.right) {
      const op = cur.operatorToken.kind;
      const v = evalCond(cur.left, R, owner, 0);
      if (op === ts.SyntaxKind.AmpersandAmpersandToken && v === false) { return true; }
      if (op === ts.SyntaxKind.BarBarToken && v === true) { return true; }
    } else if (ts.isBlock(cur) || ts.isSourceFile(cur)) {
      for (const st of cur.statements) {
        if (st === child) { break; }
        if (ts.isIfStatement(st) && exits(st.thenStatement) && evalCond(st.expression, R, owner, 0) === true) { return true; }
        if (ts.isIfStatement(st) && st.elseStatement && exits(st.elseStatement) && evalCond(st.expression, R, owner, 0) === false) {
          return true;
        }
      }
    }
    if (isFunctionLike(cur)) {
      const name = cur.name ? nameText(cur.name) : '';
      if (!owner || !ts.isMethodDeclaration(cur) || LIFECYCLE.includes(name) || cur.parent !== owner) { return false; }
      const sites = collect(owner, (n) => ts.isCallExpression(n) && isThisMember(n.expression, name));
      if (!sites.length) { return true; }
      return sites.every((s) => blocked(s, R, owner, depth + 1));
    }
    child = cur;
    cur = cur.parent;
  }
  return false;
}

// ---------------------------------------------------------------- K1 / K4 / K5 / K6：Skeleton.ets

function checkSkeleton() {
  const sf = parse(SKEL);
  if (!sf) {
    if (!exists(SKEL)) { report('K1-missing', SKEL, null, 'components/Skeleton.ets 不存在（书 §2.1：骨架件挪出 ProductCard.ets）'); }
    return;
  }
  const structs = {};
  for (const name of STRUCTS) {
    const s = findStruct(sf, name);
    structs[name] = s;
    if (!s) { report('K1-struct', SKEL, null, 'Skeleton.ets 没有 struct ' + name + '（书 §2.1 / §2.3 / §2.4）'); continue; }
    const decos = decoratorNames(s);
    if (!hasExport(s) || !decos.includes('ComponentV2') || decos.includes('Component')) {
      report('K1-struct', SKEL, s, name + ' 应为 @ComponentV2 export struct（V2 状态管理，AGENTS §3.9）');
    }
  }
  for (const d of collect(sf, (n) => ts.isDecorator(n))) {
    const name = (ts.isCallExpression(d.expression) ? d.expression.expression : d.expression).getText();
    if (V1.includes(name)) { report('K1-v1', SKEL, d, '用了 V1 装饰器 @' + name + '（AGENTS §3.9 只用 V2）'); }
  }
  const block = structs.SkeletonBlock;
  if (block) {
    const want = { blockWidth: ["'100%'", 'Length'], blockHeight: ['16', 'Length'] };
    for (const key of Object.keys(want)) {
      const p = propOf(block, key);
      const ok = p && decoratorNames(p).includes('Param') && p.type && p.type.getText() === want[key][1] && p.initializer &&
        p.initializer.getText().replace(/"/g, "'") === want[key][0];
      if (!ok) {
        report('K1-block-props', SKEL, p || block, 'SkeletonBlock 参数应保持 @Param ' + key + ': ' + want[key][1] + ' = ' + want[key][0] +
          '（页面 7 处调用不动，书 §2.1「导出名不变」）');
      }
    }
    checkShimmer(sf, block);
  }
  for (const name of SHAPES) { if (structs[name]) { checkShell(structs[name], name); } }
  if (structs.SkeletonHost) { checkHost(structs.SkeletonHost); }
  for (const name of STRUCTS) { if (structs[name]) { checkDisappearState(structs[name], name); } }
  checkColors(sf, SKEL, 'K5-literal');
  motionTokens(sf, SKEL);
}

function checkColors(sf, rel, rule) {
  for (const n of collect(sf, (x) => ts.isStringLiteral(x) || ts.isNoSubstitutionTemplateLiteral(x))) {
    if (/^(#[0-9a-fA-F]{3,8}|rgba?\()/.test(n.text)) { report(rule, rel, n, '颜色字面量 ' + n.getText() + '（颜色只来自 CouliColors 令牌）'); }
  }
  for (const n of collect(sf, (x) => ts.isNumericLiteral(x) && /^0x[0-9a-fA-F]{6,8}$/.test(x.getText()))) {
    report(rule, rel, n, '数字颜色 ' + n.getText());
  }
  for (const n of collect(sf, (x) => ts.isPropertyAccessExpression(x) && ts.isIdentifier(x.expression) && x.expression.text === 'Color' &&
    x.name.text !== 'Transparent')) {
    report(rule, rel, n, '具名色 ' + n.getText() + '（深色模式不随主题；只用 CouliColors）');
  }
  for (const n of collect(sf, (x) => ts.isCallExpression(x) && ts.isIdentifier(x.expression) && ['$r', '$rawfile'].includes(x.expression.text))) {
    report(rule, rel, n, '直接引用资源 ' + n.expression.text + '（只经 CouliColors 等令牌类）');
  }
}

function checkShimmer(sf, block) {
  if (!attributeCalls(block, ['linearGradient']).length) {
    report('K4-gradient', SKEL, block, 'SkeletonBlock 没有 .linearGradient（书 §2.2：linearGradient 位移 + 循环）');
  }
  const muted = attributeCalls(block, ['backgroundColor']).filter((c) => c.arguments.length === 1 && compact(c.arguments[0]) === 'CouliColors.backgroundMuted');
  if (!muted.length) {
    report('K4-muted', SKEL, block, 'SkeletonBlock 底色应为 .backgroundColor(CouliColors.backgroundMuted)（减弱动态时的静态底色，设备取 background.muted）');
  }
  const loops = collect(block, (n) => ts.isObjectLiteralExpression(n) && n.properties.some((p) => ts.isPropertyAssignment(p) &&
    nameText(p.name) === 'iterations' && isNumber(p.initializer, -1)));
  facts.shimmerLoops = loops.length;
  if (!loops.length) {
    report('K4-loop', SKEL, block, 'SkeletonBlock 没有无限循环动画（{ …, iterations: -1 }，animateTo 或 .animation）（书 §2.2）');
  }
  for (const lit of loops) {
    const props = objectProps(lit);
    const curve = props.get('curve');
    const c = curve ? compact(curve) : '';
    const system = c === 'CouliMotion.curve' || /^Curve\.[A-Za-z]+$/.test(c) || /^curves\.[A-Za-z]+\(.*\)$/.test(c) ||
      c === 'CouliMotion.spring()' || c === 'CouliMotion.responsive()';
    if (!system) {
      report('K4-curve', SKEL, curve || lit, '微光动画 curve 应是系统曲线（CouliMotion.curve / Curve.* / curves.*()），实际 ' + (c || '缺省') +
        '（书 §2.2、D10-838）');
    }
    if (!blocked(lit, true, block, 0)) {
      report('K4-reduced', SKEL, lit, '减弱动态（CouliMotion.reduced() 为真）时微光循环动画仍可达：应在 shimmerEnabled(CouliMotion.reduced()) / ' +
        '!CouliMotion.reduced() 为假时 return 或不进分支（书 §2.2、D10-1163 ①）');
    }
    if (blocked(lit, false, block, 0)) {
      report('K4-dead', SKEL, lit, '未减弱时微光循环动画不可达（永远不播，或启动它的方法没人调）');
    }
  }
  checkSweep(sf, block, loops);
  checkBand(sf, block, loops);
  const stop = methodOf(block, 'aboutToDisappear');
  if (!stop || !stop.body || stop.body.statements.length === 0) {
    report('K4-stop', SKEL, stop || block, 'SkeletonBlock 应有非空 aboutToDisappear() 结束微光（书 §2.2：避免离屏空转）');
  }
  const levels = attributeCalls(block, ['accessibilityLevel']).filter((c) => c.arguments.length === 1 &&
    stringValue(c.arguments[0]) === 'no-hide-descendants');
  if (!levels.length) {
    report('K5-block-a11y', SKEL, block, "SkeletonBlock 应 .accessibilityLevel('no-hide-descendants')（书 §2.3：页面直接挂块时读屏也跳过）");
  }
}

function checkShell(struct, name) {
  const build = methodOf(struct, 'build');
  const statements = build && build.body ? build.body.statements : [];
  const root = statements.length === 1 && ts.isExpressionStatement(statements[0]) ? statements[0].expression : null;
  if (!root || componentName(root) !== 'CouliCard') {
    report('K5-shell', SKEL, build || struct, name + ' 的 build() 应只有一个根：CouliCard({ kind: CouliCardKind.STATIC, a11yLevel: ' +
      "'no-hide-descendants' }) { … }（书 §2.1 外壳用 CouliCard；README ① CARD→SKELETON）");
    return;
  }
  const props = objectProps(firstObjectArg(root));
  const kind = props.get('kind');
  if (kind && compact(kind) !== 'CouliCardKind.STATIC') { report('K5-shell', SKEL, kind, name + ' 外壳应是静态卡（kind: CouliCardKind.STATIC 或不传）'); }
  if (stringValue(props.get('a11yLevel')) !== 'no-hide-descendants') {
    report('K5-shell', SKEL, root, name + " 外壳应传 a11yLevel: 'no-hide-descendants'（读屏跳过，书 §2.3；卡后不能接属性，SDK 1128）");
  }
  for (const key of ['onTap', 'press', 'disabled', 'inset']) {
    if (props.has(key)) { report('K5-shell', SKEL, props.get(key), name + ' 外壳不应传 ' + key + '（骨架不可点、白卡）'); }
  }
  const blocks = root.body ? componentCalls(root.body, 'SkeletonBlock').length : 0;
  if (blocks < 2) { report('K5-shell', SKEL, root, name + ' 卡内应由 SkeletonBlock 拼成（至少 2 块），实际 ' + blocks); }
}

function checkHost(host) {
  const want = [['loading', 'Param', 'boolean', 'false'], ['skeleton', 'BuilderParam', null, null], ['content', 'BuilderParam', null, null]];
  for (const [key, deco, type, init] of want) {
    const p = propOf(host, key);
    const ok = p && decoratorNames(p).includes(deco) && (!type || (p.type && p.type.getText() === type)) &&
      (!init || (p.initializer && p.initializer.getText() === init));
    if (!ok) { report('K6-props', SKEL, p || host, 'SkeletonHost 应有 @' + deco + ' ' + key + (type ? ': ' + type + ' = ' + init : '') + '（书 §2.4）'); }
  }
  if (!collect(host, (n) => ts.isNewExpression(n) && compact(n.expression) === 'SkeletonGate').length) {
    report('K6-gate', SKEL, host, 'SkeletonHost 内部没有 new SkeletonGate(…)（书 §2.4：门控只在纯逻辑里，包装件不另写时序）');
  }
  for (const m of ['loadingChanged', 'tick', 'nextDueInMs']) {
    // v4（Codex S2-1）：至少一处会执行（不在常量为假的分支、return 之后、从不调用的闭包里）。
    if (!methodCalls(host, m).filter((c) => !isDeadAt(c, null, host, 0)).length) {
      report('K6-gate', SKEL, host, 'SkeletonHost 没调 SkeletonGate.' + m + '()（只认会执行的调用）');
    }
  }
  const monitors = host.members.filter((m) => ts.isMethodDeclaration(m) && decoratorNodes(m).some((d) =>
    ts.isCallExpression(d.expression) && compact(d.expression.expression) === 'Monitor' &&
    d.expression.arguments.some((a) => stringValue(a) === 'loading')));
  if (!monitors.length || !monitors.some((m) => reaches(host, m, 'loadingChanged', 0))) {
    report('K6-monitor', SKEL, monitors[0] || host, "SkeletonHost 应有 @Monitor('loading') 方法，把 loading 变化交给 gate.loadingChanged");
  }
  if (!collect(host, (n) => ts.isCallExpression(n) && compact(n.expression) === 'setTimeout').length) {
    report('K6-timer', SKEL, host, 'SkeletonHost 没有定时器（按 nextDueInMs 到点再 tick，书 §2.4）');
  }
  const leave = methodOf(host, 'aboutToDisappear');
  if (!leave || !reaches(host, leave, 'clearTimeout', 0)) {
    report('K6-timer', SKEL, leave || host, 'SkeletonHost 的 aboutToDisappear 应 clearTimeout（离开页面不留定时器）');
  }
  checkHostSchedule(host);
  const build = methodOf(host, 'build');
  if (!build) { report('K6-branches', SKEL, host, 'SkeletonHost 没有 build()'); return; }
  for (const n of collect(build, (x) => isThisMember(x, 'loading'))) {
    report('K6-bypass', SKEL, n, 'SkeletonHost.build() 直接读 this.loading（绕过门控：骨架会立刻出现 / 立刻消失）');
  }
  const sk = collect(build, (x) => ts.isCallExpression(x) && isThisMember(x.expression, 'skeleton'));
  const ct = collect(build, (x) => ts.isCallExpression(x) && isThisMember(x.expression, 'content'));
  if (!sk.length || !ct.length) {
    report('K6-branches', SKEL, build, 'SkeletonHost.build() 应调 this.skeleton() 与 this.content()');
    return;
  }
  for (const s of sk) {
    const conds = enclosingIfs(s, build).map((x) => x.cond);
    if (!conds.some((c) => collect(c, (x) => compact(x) === 'SkeletonPhase.SHOWING').length)) {
      report('K6-branches', SKEL, s, 'this.skeleton() 应只在阶段为 SkeletonPhase.SHOWING 的分支里');
    }
  }
  checkHostOnScreen(host, build, sk);
  for (const c of ct) {
    const branches = enclosingIfs(c, build).map((x) => x.branch);
    for (const s of sk) {
      const sb = enclosingIfs(s, build).map((x) => x.branch);
      if (sb.length && branches.length && sb[0] === branches[0]) {
        report('K6-branches', SKEL, c, 'this.content() 与 this.skeleton() 在同一分支（骨架与内容同时出现）');
      }
    }
  }
}
// v3（HM-BATCH1-DEVFIX，tests-harmony-v4-handback.md §3.4）：设备三轮在屏 315 / 293 / 274 ms——最短停留从门控判定 SHOWING 起算，
// 判定到骨架真正挂上屏的延迟被吃进 300ms。包装件须在骨架上屏时调 gate.markOnScreen()。「上屏回调」以 SDK common.d.ts CommonMethod 为准：
// onAppear（mounts a display）/ onAttach（mounts to view tree）/ onAreaChange（首次布局完成）/ onVisibleAreaChange（可见区域变化）。
// 判据：该属性挂在 build() 里 SkeletonPhase.SHOWING 分支之内的组件上（分支外的外层容器在宿主挂载时就触发，内容分支不是骨架上屏），
// 回调（箭头函数 / 函数表达式 / this.<方法> 引用，含其经 this.<方法>() 走到的方法）里有 this.<门控字段>.markOnScreen()；
// 门控字段 = 本 struct 里 new SkeletonGate(…) 初始化或类型标注为 SkeletonGate 的字段（另 new 一个门控来调不算）。
const ON_SCREEN = ['onAppear', 'onAttach', 'onAreaChange', 'onVisibleAreaChange'];
function checkHostOnScreen(host, build, sk) {
  const gateFields = new Set(host.members.filter((m) => ts.isPropertyDeclaration(m) &&
    ((m.initializer && ts.isNewExpression(unwrap(m.initializer)) && compact(unwrap(m.initializer).expression) === 'SkeletonGate') ||
      (m.type && m.type.getText() === 'SkeletonGate'))).map((m) => nameText(m.name)));
  const isMark = (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
    n.expression.name.text === 'markOnScreen' && isThisMember(n.expression.expression) &&
    gateFields.has(unwrap(n.expression.expression).name.text);
  const marks = (root) => collect(root, isMark).length > 0;
  const branches = [];
  for (const s of sk) {
    const hit = enclosingIfs(s, build).find((x) => collect(x.cond, (y) => compact(y) === 'SkeletonPhase.SHOWING').length);
    if (hit && !branches.includes(hit.branch)) { branches.push(hit.branch); }
  }
  let ok = false;
  for (const br of branches) {
    for (const a of attributeCalls(br, ON_SCREEN)) {
      // v4（Codex S2-1）：上屏属性本身在 build 里会执行，回调里的 markOnScreen 也须会执行（常量为假的分支、return 之后、
      // 从不调用的闭包里都不算）；与原「出现即算」取与，只收紧。
      if (isDeadAt(a, null, host, 0)) { continue; }
      for (const arg of Array.from(a.arguments || [])) {
        const e = unwrap(arg);
        if (!e || !(ts.isArrowFunction(e) || ts.isFunctionExpression(e) || isThisMember(e))) { continue; }
        if (reachableRoots(host, e).some(marks) && liveCalls(host, [e], isMark).length > 0) { ok = true; }
      }
    }
  }
  if (!ok) {
    report('K6-on-screen', SKEL, branches[0] || build, 'SkeletonHost 应在骨架上屏回调（SkeletonPhase.SHOWING 分支内组件的 onAppear / onAttach / ' +
      'onAreaChange / onVisibleAreaChange）里调 this.<门控>.markOnScreen()，最短显示从上屏起算（HM-BATCH1-DEVFIX §3.4：设备在屏 315 / 293 / 274 ms）');
  }
}
function reaches(owner, method, callee, depth) {
  if (!method || !method.body || depth > 3) { return false; }
  // v4（Codex S2-1）：只认会执行的调用（liveCalls）；原「出现即算」再与之取与，判据只收紧。
  return liveCalls(owner, [method.body], (n) => isCallTo(n, callee)).length > 0 && reachesTextually(owner, method, callee, depth);
}
function reachesTextually(owner, method, callee, depth) {
  if (!method || !method.body || depth > 3) { return false; }
  if (methodCalls(method.body, callee).length) { return true; }
  for (const c of collect(method.body, (n) => ts.isCallExpression(n) && isThisMember(n.expression))) {
    const m = methodOf(owner, unwrap(c.expression).name.text);
    if (m && m !== method && reachesTextually(owner, m, callee, depth + 1)) { return true; }
  }
  return false;
}
function isCallTo(n, name) {
  return ts.isCallExpression(n) && ((ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === name) ||
    (ts.isIdentifier(n.expression) && n.expression.text === name));
}

// ---------------------------------------------------------------- v4（HM-BATCH1-DEVFIX 评审 Codex S2-1）：钉调用的规则只认会执行的调用
// 实证漏洞：`if (false) { this.gate.markOnScreen(); }`、未调用的闭包里的调用，原 K6-on-screen 照算，宿主检查返回 [] 仍过。
// 同线先例 tools/ci/a11yhome/a11yhome_ast.cjs reachableCalls / isDead：下列位置的调用确定不会执行，不算——
//   常量为假的 if / 三元 / && 右侧、常量为真的 || 右侧、常量为假的 while / for 体；同一语句列表里一定退出的语句
//   （return / throw / break / continue，或两支都退出的 if）之后；值从不被调用的函数（裸表达式语句、void、声明后没有被调用 /
//   当实参传出 / 返回 / 存起来的局部箭头、函数表达式、局部函数声明）。常量：字面量、局部 const、模块顶层 const、本 struct 的
//   readonly 或无装饰器且全部写入同值的 this.<字段>。只在确定不可执行时排除，判不了按会执行（不误伤合法写法）。
// 用于：K6-on-screen（上屏回调 → markOnScreen）、K6-monitor（@Monitor → loadingChanged）、K6-timer（aboutToDisappear → clearTimeout）、
// K6-tick（定时器回调 → tick）、K6-clear-first（排定时器前先 clearTimeout）、K6-gate（loadingChanged / tick / nextDueInMs 至少一处会执行）。
const NO_CONST = undefined;
function constOf(e, owner, depth) {
  e = unwrap(e);
  if (!e || depth > 8) { return NO_CONST; }
  const next = (x) => constOf(x, owner, depth + 1);
  const K = ts.SyntaxKind;
  if (e.kind === K.TrueKeyword) { return true; }
  if (e.kind === K.FalseKeyword) { return false; }
  if (e.kind === K.NullKeyword) { return null; }
  if (ts.isNumericLiteral(e)) { return Number(e.text); }
  if (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) { return e.text; }
  if (ts.isIdentifier(e)) {
    if (e.text === 'undefined') { return null; }
    const init = constInit(e);
    return init ? next(init) : NO_CONST;
  }
  if (ts.isVoidExpression(e)) { return null; }
  if (ts.isPrefixUnaryExpression(e)) {
    const v = next(e.operand);
    if (v === NO_CONST) { return NO_CONST; }
    if (e.operator === K.ExclamationToken) { return !v; }
    if (e.operator === K.MinusToken && typeof v === 'number') { return -v; }
    return NO_CONST;
  }
  if (isThisMember(e) && owner) { return fieldConst(owner, unwrap(e).name.text, depth); }
  if (ts.isConditionalExpression(e)) {
    const c = next(e.condition);
    return c === NO_CONST ? NO_CONST : (c ? next(e.whenTrue) : next(e.whenFalse));
  }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    const a = next(e.left);
    if (op === K.AmpersandAmpersandToken) {
      if (a !== NO_CONST && !a) { return a; }
      const b = next(e.right);
      if (a !== NO_CONST) { return b; }
      return b !== NO_CONST && !b ? false : NO_CONST;
    }
    if (op === K.BarBarToken) {
      if (a !== NO_CONST && a) { return a; }
      const b = next(e.right);
      if (a !== NO_CONST) { return b; }
      return b !== NO_CONST && b ? true : NO_CONST;
    }
    if (op === K.QuestionQuestionToken) {
      if (a === NO_CONST) { return NO_CONST; }
      return a === null ? next(e.right) : a;
    }
    const b = next(e.right);
    if (a === NO_CONST || b === NO_CONST) { return NO_CONST; }
    switch (op) {
      case K.EqualsEqualsEqualsToken: case K.EqualsEqualsToken: return a === b;
      case K.ExclamationEqualsEqualsToken: case K.ExclamationEqualsToken: return a !== b;
      case K.GreaterThanToken: return a > b;
      case K.GreaterThanEqualsToken: return a >= b;
      case K.LessThanToken: return a < b;
      case K.LessThanEqualsToken: return a <= b;
      default: return NO_CONST;
    }
  }
  return NO_CONST;
}
/** 标识符对应的 const 初值：同名局部 const（向外逐层块），再模块顶层 const；let / var / 参数 / 被遮蔽一律不算常量。 */
function constInit(id) {
  let cur = id.parent;
  while (cur) {
    if ((ts.isArrowFunction(cur) || ts.isFunctionExpression(cur) || isFunctionLike(cur)) &&
      (cur.parameters || []).some((p) => ts.isIdentifier(p.name) && p.name.text === id.text)) { return null; }
    const list = ts.isBlock(cur) || ts.isSourceFile(cur) || ts.isCaseClause(cur) || ts.isDefaultClause(cur) ? cur.statements : null;
    if (list) {
      for (const st of list) {
        if (!ts.isVariableStatement(st)) { continue; }
        for (const d of st.declarationList.declarations) {
          if (ts.isIdentifier(d.name) && d.name.text === id.text) {
            return (st.declarationList.flags & ts.NodeFlags.Const) && d.initializer ? d.initializer : null;
          }
        }
      }
    }
    cur = cur.parent;
  }
  return null;
}
/** this.<字段> 的常量值：readonly 取初值；无装饰器（外部写不进）且初值与本 struct 内全部写入同值才算定值；否则不是常量。 */
function fieldConst(owner, field, depth) {
  const prop = propOf(owner, field);
  if (!prop || !prop.initializer || decoratorNodes(prop).length) { return NO_CONST; }
  const v = constOf(prop.initializer, owner, depth + 1);
  if (v === NO_CONST) { return NO_CONST; }
  if ((prop.modifiers || []).some((m) => m.kind === ts.SyntaxKind.ReadonlyKeyword)) { return v; }
  for (const w of thisWrites(owner)) {
    if (w.field !== field) { continue; }
    if (!w.rhs || constOf(w.rhs, owner, depth + 1) !== v) { return NO_CONST; }
  }
  return v;
}
function constTruthOf(e, owner) { const v = constOf(e, owner, 0); return v === NO_CONST ? NO_CONST : !!v; }
/** 语句是否一定退出所在语句列表（之后的兄弟语句不会执行）。 */
function alwaysExits(st, owner) {
  if (!st) { return false; }
  if (ts.isReturnStatement(st) || ts.isThrowStatement(st) || ts.isBreakStatement(st) || ts.isContinueStatement(st)) { return true; }
  if (ts.isBlock(st)) { return st.statements.some((s) => alwaysExits(s, owner)); }
  if (ts.isIfStatement(st)) {
    const c = constTruthOf(st.expression, owner);
    if (c === true) { return alwaysExits(st.thenStatement, owner); }
    if (c === false) { return !!st.elseStatement && alwaysExits(st.elseStatement, owner); }
    return !!st.elseStatement && alwaysExits(st.thenStatement, owner) && alwaysExits(st.elseStatement, owner);
  }
  return false;
}
function isFnExpr(n) { return ts.isArrowFunction(n) || ts.isFunctionExpression(n); }
/** 函数值会不会被调用：只在确定不会时返回 false（被调用 / 当实参传出 / 返回 / 存进对象或字段 → 按会调用算）。 */
function fnInvoked(fn, owner, depth) {
  if (depth > 4) { return true; }
  let cur = fn;
  let p = fn.parent;
  if (ts.isFunctionDeclaration(fn)) {
    return fn.name ? nameUsedAsCallable(fn.name.text, fn.parent, fn.name, owner, depth) : false;
  }
  while (p && (ts.isParenthesizedExpression(p) || ts.isAsExpression(p) || ts.isNonNullExpression(p))) { cur = p; p = p.parent; }
  if (!p) { return true; }
  if (ts.isExpressionStatement(p) || ts.isVoidExpression(p)) { return false; }
  if (ts.isPropertyAssignment(p) && p.initializer === cur && ts.isObjectLiteralExpression(p.parent)) {
    let q = p.parent.parent;
    while (q && ts.isParenthesizedExpression(q)) { q = q.parent; }
    return !(q && (ts.isExpressionStatement(q) || ts.isVoidExpression(q)));
  }
  if (ts.isVariableDeclaration(p) && p.initializer === cur && ts.isIdentifier(p.name)) {
    let scope = p.parent;
    while (scope && !ts.isBlock(scope) && !ts.isSourceFile(scope) && !ts.isCaseClause(scope) && !ts.isDefaultClause(scope)) { scope = scope.parent; }
    return nameUsedAsCallable(p.name.text, scope || p.getSourceFile(), p.name, owner, depth);
  }
  return true;
}
/** 名字在 scope 里有没有一处会执行的「调用 / 当实参传出 / 返回 / 赋给别处 / 放进对象或数组」引用。 */
function nameUsedAsCallable(name, scope, decl, owner, depth) {
  let used = false;
  walk(scope, (x) => {
    if (used || !ts.isIdentifier(x) || x.text !== name || x === decl) { return; }
    let cur = x;
    let p = x.parent;
    while (p && (ts.isParenthesizedExpression(p) || ts.isAsExpression(p) || ts.isNonNullExpression(p))) { cur = p; p = p.parent; }
    if (!p) { return; }
    if (ts.isPropertyAccessExpression(p) && p.name === cur) { return; }
    if (ts.isPropertyAssignment(p) && p.name === cur) { return; }
    const live = (ts.isCallExpression(p) && (p.expression === cur || Array.from(p.arguments).includes(cur))) ||
      (ts.isNewExpression(p) && Array.from(p.arguments || []).includes(cur)) ||
      ts.isReturnStatement(p) || (ts.isArrowFunction(p) && p.body === cur) ||
      (ts.isBinaryExpression(p) && p.right === cur && p.operatorToken.kind === ts.SyntaxKind.EqualsToken) ||
      (ts.isVariableDeclaration(p) && p.initializer === cur) || ts.isPropertyAssignment(p) || ts.isShorthandPropertyAssignment(p) ||
      ts.isArrayLiteralExpression(p);
    if (live && !isDeadAt(x, null, owner, depth + 1)) { used = true; }
  });
  return used;
}
/** node 是否确定不会执行（向上走到所在方法为止；root 是扫描起点，本身按会执行算）。 */
function isDeadAt(node, root, owner, depth) {
  const K = ts.SyntaxKind;
  let cur = node;
  let p = node.parent;
  while (p) {
    if (ts.isIfStatement(p)) {
      const c = constTruthOf(p.expression, owner);
      if ((cur === p.thenStatement && c === false) || (cur === p.elseStatement && c === true)) { return true; }
    } else if (ts.isConditionalExpression(p)) {
      const c = constTruthOf(p.condition, owner);
      if ((cur === p.whenTrue && c === false) || (cur === p.whenFalse && c === true)) { return true; }
    } else if (ts.isBinaryExpression(p) && cur === p.right) {
      const k = p.operatorToken.kind;
      const c = constTruthOf(p.left, owner);
      if ((k === K.AmpersandAmpersandToken && c === false) || (k === K.BarBarToken && c === true)) { return true; }
      if (k === K.QuestionQuestionToken) { const v = constOf(p.left, owner, 0); if (v !== NO_CONST && v !== null) { return true; } }
    } else if (ts.isWhileStatement(p) && cur === p.statement) {
      if (constTruthOf(p.expression, owner) === false) { return true; }
    } else if (ts.isForStatement(p) && cur === p.statement && p.condition) {
      if (constTruthOf(p.condition, owner) === false) { return true; }
    } else if (ts.isBlock(p) || ts.isCaseClause(p) || ts.isDefaultClause(p) || ts.isSourceFile(p)) {
      for (const st of p.statements) {
        if (st === cur) { break; }
        if (alwaysExits(st, owner)) { return true; }
      }
    }
    if (ts.isMethodDeclaration(p) || ts.isConstructorDeclaration(p) || ts.isGetAccessorDeclaration(p) || ts.isSetAccessorDeclaration(p)) {
      return false;
    }
    if ((isFnExpr(p) || ts.isFunctionDeclaration(p)) && p !== root && !fnInvoked(p, owner, depth)) { return true; }
    cur = p;
    p = p.parent;
  }
  return false;
}
/**
 * 从 roots 出发会执行的调用里满足 pred 的（含嵌套闭包；经 this.<方法>() 调用、或作实参传出的 this.<方法> 引用展开方法体，最多 4 层）。
 * root 本身是 this.<方法> 引用（如 .onAppear(this.onShown)）时从该方法体起。
 */
function liveCalls(owner, roots, pred) {
  const out = [];
  const seen = new Set();
  const follow = (ref, depth) => {
    const m = owner ? methodOf(owner, unwrap(ref).name.text) : null;
    if (m && m.body && !seen.has(m)) { seen.add(m); scan(m.body, depth + 1); }
  };
  function scan(node, depth) {
    walk(node, (n) => {
      if (!ts.isCallExpression(n) || isDeadAt(n, node, owner, 0)) { return; }
      if (pred(n)) { out.push(n); }
      if (depth >= 4) { return; }
      if (isThisMember(n.expression)) { follow(n.expression, depth); }
      for (const a of Array.from(n.arguments || [])) { if (isThisMember(a)) { follow(a, depth); } }
    });
  }
  for (const r of roots) {
    if (!r) { continue; }
    if (isThisMember(r)) { follow(r, -1); } else { scan(r, 0); }
  }
  return out;
}
function enclosingIfs(node, stop) {
  const out = [];
  let child = node;
  let cur = node.parent;
  while (cur && cur !== stop) {
    if (ts.isIfStatement(cur) && (child === cur.thenStatement || child === cur.elseStatement)) {
      out.push({ cond: cur.expression, branch: child });
    }
    child = cur;
    cur = cur.parent;
  }
  return out;
}

// ---------------------------------------------------------------- v2（评审 r1 S2-1、S3-6）：离开不写状态、微光真在动且看得见、Host 调度
// 常量求值：数字 / 字符串 / 布尔字面量、顶层 const、本 struct 的 this.<字段>（取给定环境）、+ - * /、比较、! && ||、三元、对象 / 数组字面量、
// 模板串；CouliColors.x / Visibility.x 这类非 this 的属性访问当符号。求不出 → UNKNOWN（对应判据按「宽」处理，见各处注释）。
const UNKNOWN = { unknown: true };
const STATE_DECOS = ['Local', 'Param', 'Once', 'Provider', 'Consumer', 'Event'].concat(V1);
const MOVERS = ['translate', 'offset', 'position', 'markAnchor'];

function isUnknown(v) {
  if (v === UNKNOWN) { return true; }
  if (Array.isArray(v)) { return v.some(isUnknown); }
  if (v && typeof v === 'object' && !('sym' in v)) { return Object.keys(v).some((k) => isUnknown(v[k])); }
  return false;
}
function topConst(sf, name) {
  for (const st of sf.statements) {
    if (!ts.isVariableStatement(st)) { continue; }
    for (const d of st.declarationList.declarations) {
      if (ts.isIdentifier(d.name) && d.name.text === name && d.initializer) { return d.initializer; }
    }
  }
  return null;
}
function evalValue(e, env, sf, depth) {
  e = unwrap(e);
  if (!e || depth > 16) { return UNKNOWN; }
  const next = (x) => evalValue(x, env, sf, depth + 1);
  if (ts.isNumericLiteral(e)) { return Number(e.text); }
  if (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) { return e.text; }
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isPrefixUnaryExpression(e)) {
    const v = next(e.operand);
    if (e.operator === ts.SyntaxKind.MinusToken) { return typeof v === 'number' ? -v : UNKNOWN; }
    if (e.operator === ts.SyntaxKind.ExclamationToken) { return typeof v === 'boolean' ? !v : UNKNOWN; }
    return UNKNOWN;
  }
  if (ts.isIdentifier(e)) {
    const init = lookupLocal(e) || topConst(sf, e.text);
    return init ? next(init) : UNKNOWN;
  }
  if (isThisMember(e)) {
    const f = e.name.text;
    return Object.prototype.hasOwnProperty.call(env, f) ? env[f] : UNKNOWN;
  }
  if (ts.isPropertyAccessExpression(e) && /^[A-Za-z_][A-Za-z0-9_.]*$/.test(compact(e))) { return { sym: compact(e) }; }
  if (ts.isConditionalExpression(e)) {
    const c = next(e.condition);
    if (typeof c !== 'boolean') { return UNKNOWN; }
    return c ? next(e.whenTrue) : next(e.whenFalse);
  }
  if (ts.isTemplateExpression(e)) {
    let out = e.head.text;
    for (const span of e.templateSpans) {
      const v = next(span.expression);
      if (typeof v !== 'number' && typeof v !== 'string') { return UNKNOWN; }
      out += String(v) + span.literal.text;
    }
    return out;
  }
  if (ts.isArrayLiteralExpression(e)) { return e.elements.map(next); }
  if (ts.isObjectLiteralExpression(e)) {
    const out = {};
    for (const p of e.properties) {
      if (!ts.isPropertyAssignment(p)) { return UNKNOWN; }
      out[nameText(p.name)] = next(p.initializer);
    }
    return out;
  }
  if (ts.isBinaryExpression(e)) {
    const op = e.operatorToken.kind;
    const a = next(e.left);
    const b = next(e.right);
    const K = ts.SyntaxKind;
    if (op === K.AmpersandAmpersandToken || op === K.BarBarToken) {
      if (op === K.AmpersandAmpersandToken && (a === false || b === false)) { return false; }
      if (op === K.BarBarToken && (a === true || b === true)) { return true; }
      return typeof a === 'boolean' && typeof b === 'boolean' ? (op === K.AmpersandAmpersandToken ? a && b : a || b) : UNKNOWN;
    }
    if (isUnknown(a) || isUnknown(b)) { return UNKNOWN; }
    if (op === K.EqualsEqualsEqualsToken || op === K.EqualsEqualsToken) { return JSON.stringify(a) === JSON.stringify(b); }
    if (op === K.ExclamationEqualsEqualsToken || op === K.ExclamationEqualsToken) { return JSON.stringify(a) !== JSON.stringify(b); }
    if (op === K.PlusToken && (typeof a === 'string' || typeof b === 'string')) {
      return ['string', 'number'].includes(typeof a) && ['string', 'number'].includes(typeof b) ? String(a) + String(b) : UNKNOWN;
    }
    if (typeof a !== 'number' || typeof b !== 'number') { return UNKNOWN; }
    switch (op) {
      case K.PlusToken: return a + b;
      case K.MinusToken: return a - b;
      case K.AsteriskToken: return a * b;
      case K.SlashToken: return b === 0 ? UNKNOWN : a / b;
      case K.GreaterThanToken: return a > b;
      case K.GreaterThanEqualsToken: return a >= b;
      case K.LessThanToken: return a < b;
      case K.LessThanEqualsToken: return a <= b;
      default: return UNKNOWN;
    }
  }
  return UNKNOWN;
}
function thisWrites(root) {
  // this.<字段> 的写：= / 复合赋值 / ++ / --（含 this['字段']）。
  const out = [];
  const field = (x) => {
    x = unwrap(x);
    if (isThisMember(x)) { return x.name.text; }
    if (x && ts.isElementAccessExpression(x) && x.expression.kind === ts.SyntaxKind.ThisKeyword) { return stringValue(x.argumentExpression); }
    return null;
  };
  walk(root, (n) => {
    if (ts.isBinaryExpression(n) && n.operatorToken.kind >= ts.SyntaxKind.FirstAssignment && n.operatorToken.kind <= ts.SyntaxKind.LastAssignment) {
      const f = field(n.left);
      if (f) { out.push({ field: f, node: n, rhs: n.operatorToken.kind === ts.SyntaxKind.EqualsToken ? n.right : null }); }
    } else if ((ts.isPrefixUnaryExpression(n) || ts.isPostfixUnaryExpression(n)) &&
      (n.operator === ts.SyntaxKind.PlusPlusToken || n.operator === ts.SyntaxKind.MinusMinusToken)) {
      const f = field(n.operand);
      if (f) { out.push({ field: f, node: n, rhs: null }); }
    }
  });
  return out;
}
/** 从 node 出发（含其中 this.<方法>() 调用与 this.<方法> 引用，跨方法最多 4 层）能走到的全部节点根。 */
function reachableRoots(owner, node) {
  const roots = [node];
  const seen = new Set();
  for (let i = 0; i < roots.length && i < 32; i++) {
    for (const r of collect(roots[i], (n) => isThisMember(n))) {
      const m = methodOf(owner, unwrap(r).name.text);
      if (m && m.body && !seen.has(m)) { seen.add(m); roots.push(m.body); }
    }
  }
  return roots;
}

/** S2-1：aboutToDisappear（及它经 this.<方法>() 走到的方法、闭包）不写 @Local / @Param 等状态变量（SDK common.d.ts:30395）。 */
function checkDisappearState(owner, name) {
  const leave = methodOf(owner, 'aboutToDisappear');
  if (!leave || !leave.body) { return; }
  const state = new Set(owner.members.filter((m) => ts.isPropertyDeclaration(m) && decoratorNames(m).some((d) => STATE_DECOS.includes(d)))
    .map((m) => nameText(m.name)));
  const rule = name === 'SkeletonHost' ? 'K6-disappear-state' : 'K4-disappear-state';
  for (const root of reachableRoots(owner, leave.body)) {
    for (const w of thisWrites(root)) {
      if (state.has(w.field)) {
        report(rule, SKEL, w.node, name + ' 的 aboutToDisappear 写了状态变量 this.' + w.field + '（SDK common.d.ts:30395「Do not change state ' +
          'variables in the aboutToDisappear function」；离开只置普通私有字段，评审 r1 S2-1）');
      }
    }
  }
}

function fieldInits(owner) {
  const env = {};
  for (const m of owner.members) {
    if (ts.isPropertyDeclaration(m) && m.initializer) { env[nameText(m.name)] = m.initializer; }
  }
  return env;
}
function evalEnv(sf, owner, overrides) {
  const env = {};
  const inits = fieldInits(owner);
  for (const f of Object.keys(inits)) { env[f] = evalValue(inits[f], {}, sf, 0); }
  for (const [f, rhs] of overrides) { env[f] = rhs ? evalValue(rhs, env, sf, 0) : UNKNOWN; }
  return env;
}
function enclosingMethod(node, owner) {
  let cur = node.parent;
  while (cur && !(ts.isMethodDeclaration(cur) && cur.parent === owner)) { cur = cur.parent; }
  return cur || null;
}
/** 循环动画「播起来」时改的字段：animateTo(lit, 闭包) 取闭包里的写；.animation(lit) 取 struct 里（除 aboutToDisappear）全部写。 */
function loopWrites(block, lit) {
  const call = lit.parent;
  if (call && ts.isCallExpression(call) && call.arguments[0] === lit && ts.isPropertyAccessExpression(call.expression) &&
    call.expression.name.text === 'animateTo' && call.arguments[1]) {
    return { writes: thisWrites(call.arguments[1]), method: enclosingMethod(call, block), closure: call.arguments[1] };
  }
  const leave = methodOf(block, 'aboutToDisappear');
  return { writes: thisWrites(block).filter((w) => !(leave && w.node.pos >= leave.pos && w.node.end <= leave.end)), method: null, closure: null };
}
function chainAttrs(comp) {
  const out = [];
  let cur = comp;
  while (cur.parent && ts.isPropertyAccessExpression(cur.parent) && cur.parent.expression === cur && cur.parent.parent &&
    ts.isCallExpression(cur.parent.parent) && cur.parent.parent.expression === cur.parent) {
    out.push(cur.parent.parent);
    cur = cur.parent.parent;
  }
  return out;
}
function chainBase(attrCall) {
  let base = attrCall;
  while (ts.isCallExpression(base) && ts.isPropertyAccessExpression(base.expression)) { base = base.expression.expression; }
  return base;
}
/** 渐变所在组件链 + 它在 build 里的祖先组件链（root 标出来）。 */
function gradientChains(build, grad) {
  const base = chainBase(grad);
  const chains = [{ comp: base, attrs: chainAttrs(base), own: true }];
  let cur = base.parent;
  while (cur && cur !== build) {
    if (ts.isEtsComponentExpression && ts.isEtsComponentExpression(cur)) { chains.push({ comp: cur, attrs: chainAttrs(cur), own: false }); }
    cur = cur.parent;
  }
  for (const c of chains) {
    const top = c.attrs.length ? c.attrs[c.attrs.length - 1] : c.comp;
    c.root = !!(top.parent && ts.isExpressionStatement(top.parent) && top.parent.parent === build.body);
  }
  return chains;
}

/** S3-6 微光：循环动画要改一个被窄带位移（或渐变本身）读到的字段，且起止两态算出来不同；窄带在播时看得见；窄带颜色不全是块底色。 */
function checkSweep(sf, block, loops) {
  const build = methodOf(block, 'build');
  if (!build || !loops.length) { return; }
  const grads = attributeCalls(build, ['linearGradient']);
  if (!grads.length) { return; }
  for (const lit of loops) {
    const { writes } = loopWrites(block, lit);
    const animated = new Set(writes.map((w) => w.field));
    if (!animated.size) {
      report('K4-sweep', SKEL, lit, '微光循环动画没改任何 this 字段（动画闭包为空：窄带不会动）');
      continue;
    }
    const start = evalEnv(sf, block, []);
    const end = evalEnv(sf, block, writes.map((w) => [w.field, w.rhs]));
    let moving = false;
    const statics = [];
    for (const grad of grads) {
      for (const ch of gradientChains(build, grad)) {
        for (const a of ch.attrs) {
          const name = a.expression.name.text;
          const ok = (MOVERS.includes(name) && (ch.own || !ch.root)) || (name === 'linearGradient' && ch.own);
          if (!ok || a.arguments.length < 1) { continue; }
          const reads = collect(a.arguments[0], (n) => isThisMember(n) && animated.has(unwrap(n).name.text)).length > 0;
          if (!reads) { continue; }
          const s = evalValue(a.arguments[0], start, sf, 0);
          const e = evalValue(a.arguments[0], end, sf, 0);
          if (isUnknown(s) || isUnknown(e) || JSON.stringify(s) !== JSON.stringify(e)) { moving = true; } else { statics.push(name + ' ' + JSON.stringify(s)); }
        }
      }
    }
    if (!moving) {
      report('K4-sweep', SKEL, lit, '微光不会动：窄带的 ' + MOVERS.join(' / ') + ' / linearGradient 没有一处读循环动画改的字段（' + [...animated].join(', ') +
        '）且起止两态不同' + (statics.length ? '；起止相同：' + statics.join('；') : '') + '（评审 r1 S3-6：位移起止不同）');
    }
  }
}
function checkBand(sf, block, loops) {
  const build = methodOf(block, 'build');
  if (!build || !loops.length) { return; }
  const baseColors = attributeCalls(block, ['backgroundColor']).filter((c) => c.arguments.length === 1).map((c) => compact(c.arguments[0]));
  const { writes, method, closure } = loopWrites(block, loops[0]);
  // 「在播」状态：字段初值，叠上启动循环的方法里（闭包外）的写，再叠上动画闭包里的写。
  const pre = method ? thisWrites(method).filter((w) => !(closure && w.node.pos >= closure.pos && w.node.end <= closure.end)) : [];
  const play = evalEnv(sf, block, pre.concat(writes).map((w) => [w.field, w.rhs]));
  for (const grad of attributeCalls(build, ['linearGradient'])) {
    const why = [];
    for (const ch of gradientChains(build, grad)) {
      for (const a of ch.attrs) {
        const name = a.expression.name.text;
        if (!['visibility', 'opacity'].includes(name) || a.arguments.length !== 1) { continue; }
        const v = evalValue(a.arguments[0], play, sf, 0);
        if (name === 'visibility' && v && typeof v === 'object' && v.sym && v.sym !== 'Visibility.Visible') { why.push('.visibility → ' + v.sym); }
        if (name === 'opacity' && typeof v === 'number' && v <= 0) { why.push('.opacity → ' + v); }
      }
    }
    let child = grad;
    let cur = grad.parent;
    while (cur && cur !== build) {
      if (ts.isIfStatement(cur) && (child === cur.thenStatement || child === cur.elseStatement)) {
        const v = evalValue(cur.expression, play, sf, 0);
        if (typeof v === 'boolean' && v !== (child === cur.thenStatement)) { why.push('if (' + cur.expression.getText() + ') 不进窄带分支'); }
      }
      child = cur;
      cur = cur.parent;
    }
    if (why.length) {
      report('K4-band-visible', SKEL, grad, '微光在播时窄带看不见：' + why.join('；') + '（评审 r1 S3-6：可见性不能是常量 / 与播放反着）');
    }
    const arg = grad.arguments[0] ? evalValue(grad.arguments[0], play, sf, 0) : UNKNOWN;
    const colors = arg && typeof arg === 'object' && Array.isArray(arg.colors) ? arg.colors.map((c) => (Array.isArray(c) ? c[0] : UNKNOWN)) : null;
    if (colors && colors.length && !colors.some(isUnknown)) {
      const names = colors.map((c) => (c && c.sym ? c.sym : JSON.stringify(c)));
      if (names.every((n) => baseColors.includes(n)) || new Set(names).size < 2) {
        report('K4-band-color', SKEL, grad, '微光窄带颜色 ' + [...new Set(names)].join(' / ') + ' 与块底色相同或只有一种色（窄带扫过看不出来；评审 r1 S3-6）');
      }
    }
  }
}

/** S3-6 Host 调度：setTimeout 延时取 nextDueInMs()，剩余 ≥ 0（含到点 0）时排、< 0 时不排；回调走到 tick；排之前先清旧定时器；句柄存在 this 字段并被 clearTimeout。 */
function evalNum(e, dueName, due, depth) {
  e = unwrap(e);
  if (!e || depth > 8) { return null; }
  const next = (x) => evalNum(x, dueName, due, depth + 1);
  if (ts.isNumericLiteral(e)) { return Number(e.text); }
  if (e.kind === ts.SyntaxKind.TrueKeyword) { return true; }
  if (e.kind === ts.SyntaxKind.FalseKeyword) { return false; }
  if (ts.isIdentifier(e) && dueName && e.text === dueName) { return due; }
  if (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression) && e.expression.name.text === 'nextDueInMs') { return due; }
  if (ts.isPrefixUnaryExpression(e)) {
    const v = next(e.operand);
    if (e.operator === ts.SyntaxKind.MinusToken) { return typeof v === 'number' ? -v : null; }
    if (e.operator === ts.SyntaxKind.ExclamationToken) { return typeof v === 'boolean' ? !v : null; }
    return null;
  }
  if (ts.isBinaryExpression(e)) {
    const K = ts.SyntaxKind;
    const op = e.operatorToken.kind;
    const a = next(e.left);
    const b = next(e.right);
    if (op === K.AmpersandAmpersandToken) { return a === false || b === false ? false : (a === true && b === true ? true : null); }
    if (op === K.BarBarToken) { return a === true || b === true ? true : (a === false && b === false ? false : null); }
    if (typeof a !== 'number' || typeof b !== 'number') { return null; }
    switch (op) {
      case K.GreaterThanToken: return a > b;
      case K.GreaterThanEqualsToken: return a >= b;
      case K.LessThanToken: return a < b;
      case K.LessThanEqualsToken: return a <= b;
      case K.EqualsEqualsEqualsToken: case K.EqualsEqualsToken: return a === b;
      case K.ExclamationEqualsEqualsToken: case K.ExclamationEqualsToken: return a !== b;
      default: return null;
    }
  }
  return null;
}
function blockedBy(node, ev, stop) {
  let child = node;
  let cur = node.parent;
  while (cur && cur !== stop) {
    if (ts.isIfStatement(cur)) {
      const v = ev(cur.expression);
      if (child === cur.thenStatement && v === false) { return true; }
      if (child === cur.elseStatement && v === true) { return true; }
    } else if (ts.isConditionalExpression(cur)) {
      const v = ev(cur.condition);
      if (child === cur.whenTrue && v === false) { return true; }
      if (child === cur.whenFalse && v === true) { return true; }
    } else if (ts.isBinaryExpression(cur) && child === cur.right) {
      const v = ev(cur.left);
      if (cur.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken && v === false) { return true; }
      if (cur.operatorToken.kind === ts.SyntaxKind.BarBarToken && v === true) { return true; }
    } else if (ts.isBlock(cur)) {
      for (const st of cur.statements) {
        if (st === child) { break; }
        if (ts.isIfStatement(st) && exits(st.thenStatement) && ev(st.expression) === true) { return true; }
        if (ts.isIfStatement(st) && st.elseStatement && exits(st.elseStatement) && ev(st.expression) === false) { return true; }
      }
    }
    if (isFunctionLike(cur) || ts.isArrowFunction(cur) || ts.isFunctionExpression(cur)) { break; }
    child = cur;
    cur = cur.parent;
  }
  return false;
}
function reachesFrom(owner, node, callee) {
  // v4（Codex S2-1）：与原「出现即算」取与，另须有一处会执行（liveCalls），只收紧。
  return reachableRoots(owner, node).some((r) => methodCalls(r, callee).length > 0) &&
    liveCalls(owner, [node], (n) => isCallTo(n, callee)).length > 0;
}
function checkHostSchedule(host) {
  const timers = collect(host, (n) => ts.isCallExpression(n) && compact(n.expression) === 'setTimeout');
  const clears = collect(host, (n) => ts.isCallExpression(n) && compact(n.expression) === 'clearTimeout').map((c) => (c.arguments[0] ? compact(c.arguments[0]) : ''));
  for (const t of timers) {
    const method = enclosingMethod(t, host);
    const delay = t.arguments[1] ? unwrap(t.arguments[1]) : null;
    let dueName = null;
    let fromGate = false;
    if (delay && ts.isCallExpression(delay) && methodCalls(delay, 'nextDueInMs').length) { fromGate = true; }
    if (delay && ts.isIdentifier(delay)) {
      const init = lookupLocal(delay);
      if (init && ts.isCallExpression(unwrap(init)) && methodCalls(unwrap(init), 'nextDueInMs').length) { fromGate = true; dueName = delay.text; }
    }
    if (!fromGate) {
      report('K6-schedule', SKEL, delay || t, 'setTimeout 延时应取 gate.nextDueInMs()（或其局部 const），实际 ' + (delay ? delay.getText() : '缺省') +
        '（门控按剩余毫秒定时，评审 r1 S3-6）');
    } else {
      const at = (d) => blockedBy(t, (c) => evalNum(c, dueName, d, 0), method);
      if (at(0) || at(1) || at(300)) {
        report('K6-schedule', SKEL, t, 'nextDueInMs() 为 0（到点还没 tick）或正数时没排定时器（应 >= 0 就排，否则卡在旧阶段；评审 r1 S3-6）');
      }
      if (!at(-1)) {
        report('K6-schedule', SKEL, t, 'nextDueInMs() < 0（没有待变阶段）时仍会排定时器（应只在 >= 0 时排，否则空转 tick）');
      }
    }
    const cb = t.arguments[0];
    if (!cb || !reachesFrom(host, cb, 'tick')) {
      report('K6-tick', SKEL, cb || t, 'setTimeout 回调走不到 gate.tick()（到点不推进阶段：骨架不出现或不撤，评审 r1 S3-6）');
    }
    let ok = false;
    if (method && method.body) {
      let top = t;
      while (top.parent && top.parent !== method.body) { top = top.parent; }
      for (const st of method.body.statements) {
        if (st === top) { break; }
        if (reachesFrom(host, st, 'clearTimeout')) { ok = true; }
      }
    }
    if (!ok) {
      report('K6-clear-first', SKEL, t, 'setTimeout 所在方法排新定时器前没先 clearTimeout 旧的（同时会有多个定时器、离开只清最后一个；评审 r1 S3-6）');
    }
    const p = t.parent;
    const handle = p && ts.isBinaryExpression(p) && p.operatorToken.kind === ts.SyntaxKind.EqualsToken && p.right === t && isThisMember(p.left)
      ? compact(p.left) : null;
    if (!handle || !clears.includes(handle)) {
      report('K6-handle', SKEL, t, 'setTimeout 的句柄应存进 this.<字段>，并由 clearTimeout(this.<字段>) 清（否则清不到；评审 r1 S3-6）');
    }
  }
}

function checkProductCard() {
  const sf = need(PRODUCT);
  if (!sf) { return; }
  for (const n of collect(sf, (x) => (ts.isStructDeclaration(x) || ts.isClassDeclaration(x) || ts.isFunctionDeclaration(x)) && x.name &&
    /^Skeleton/.test(x.name.text))) {
    report('K1-leftover', PRODUCT, n, 'ProductCard.ets 仍声明 ' + n.name.text + '（书 §2.1：骨架段整段移入 Skeleton.ets，不留两份）');
  }
  for (const n of collect(sf, (x) => ts.isIdentifier(x) && ['SkeletonBlock', 'SkeletonProductCard'].includes(x.text) &&
    !(x.parent && (ts.isStructDeclaration(x.parent) || ts.isClassDeclaration(x.parent)) && x.parent.name === x))) {
    report('K1-leftover', PRODUCT, n, 'ProductCard.ets 仍引用 ' + n.text + '（书 §2.1：删除后无残留引用）');
  }
}

// ---------------------------------------------------------------- K2 / K3：导出与纯逻辑

function exportsOf(sf) {
  const out = {};
  ts.forEachChild(sf, (n) => {
    if (ts.isExportDeclaration(n) && n.exportClause && ts.isNamedExports(n.exportClause) && n.moduleSpecifier) {
      for (const e of n.exportClause.elements) {
        (out[e.name.text] = out[e.name.text] || []).push(n.moduleSpecifier.text);
      }
    }
  });
  return out;
}

function checkIndex() {
  const sf = need(INDEX);
  if (!sf) { return; }
  const ex = exportsOf(sf);
  const base = (input.baseline && input.baseline.index) || {};
  facts.indexNames = Object.keys(ex).length;
  for (const name of Object.keys(base)) {
    if (!ex[name]) { report('K2-index', INDEX, null, 'Index.ets 少了基线导出 ' + name + '（书 §2.1 / §5：导出名不变，页面 import 不改）'); }
  }
  for (const name of INDEX_NEW) {
    if (!ex[name]) { report('K2-index', INDEX, null, 'Index.ets 没有导出新件 ' + name + '（书 §2.3 / §2.4、README ⑧）'); }
  }
  for (const name of Object.keys(ex)) {
    if (!base[name] && !INDEX_NEW.includes(name) && !INDEX_OPTIONAL.includes(name)) {
      report('K2-index', INDEX, null, 'Index.ets 多了导出 ' + name + '（书 §3 S2：导出名集合不变，新增只许 ' + INDEX_NEW.join(' / ') + '）');
    }
    if (ex[name].length > 1) { report('K2-index', INDEX, null, 'Index.ets 重复导出 ' + name + '：' + ex[name].join(' / ')); }
  }
  for (const name of STRUCTS) {
    if (ex[name] && ex[name].some((m) => m !== SKEL_MODULE)) {
      report('K2-index', INDEX, null, name + " 应从 '" + SKEL_MODULE + "' 导出，实际 " + ex[name].join(' / ') + '（书 §2.1）');
    }
  }
  for (const name of ['SkeletonGate', 'SkeletonPhase', 'SkeletonClock', 'shimmerEnabled']) {
    if (ex[name] && ex[name].some((m) => m !== GATE_MODULE)) {
      report('K2-index', INDEX, null, name + " 应从 '" + GATE_MODULE + "' 导出（同一份纯逻辑）");
    }
  }
}

function checkLogic() {
  const sf = need(LOGIC);
  if (sf) {
    const ex = exportsOf(sf);
    const base = (input.baseline && input.baseline.logic) || {};
    for (const name of Object.keys(base)) {
      if (!ex[name]) { report('K3-logic-export', LOGIC, null, 'Logic.ets 少了基线导出 ' + name); }
    }
    for (const name of LOGIC_NEW) {
      if (!ex[name] || ex[name].some((m) => m !== GATE_MODULE)) {
        report('K3-logic-export', LOGIC, null, "Logic.ets 应从 '" + GATE_MODULE + "' 导出 " + name + '（书 §2.4 / §3 S3：SkeletonGate 进 Logic.ets）');
      }
    }
    for (const n of collect(sf, (x) => ts.isImportDeclaration(x) || ts.isExportDeclaration(x))) {
      const spec = n.moduleSpecifier && ts.isStringLiteral(n.moduleSpecifier) ? n.moduleSpecifier.text : '';
      if (/^@(kit|ohos)\./.test(spec) || /\/components\/Skeleton$/.test(spec)) {
        report('K3-logic-export', LOGIC, n, 'Logic.ets 引入了 ' + spec + '（无资源纯逻辑入口不得依赖 @kit / 组件，test_host.py:45）');
      }
    }
  }
  const gate = parse(GATE);
  if (!gate) {
    if (!exists(GATE)) { report('K3-gate-missing', GATE, null, 'logic/SkeletonGate.ets 不存在（书 §2.4：纯逻辑放 logic/）'); }
    return;
  }
  for (const n of collect(gate, (x) => ts.isImportDeclaration(x) || ts.isExportDeclaration(x))) {
    const spec = n.moduleSpecifier && ts.isStringLiteral(n.moduleSpecifier) ? n.moduleSpecifier.text : '';
    if (spec && !/^\.\/[A-Za-z0-9_]+$/.test(spec)) {
      report('K3-gate-kit', GATE, n, "SkeletonGate.ets 只许引同目录纯逻辑（'./X'），实际 '" + spec + "'（无 @kit / $r / 组件，test_host.py:45）");
    }
  }
  for (const n of collect(gate, (x) => ts.isStructDeclaration(x) || ts.isDecorator(x) ||
    (ts.isCallExpression(x) && ts.isIdentifier(x.expression) && ['$r', '$rawfile'].includes(x.expression.text)))) {
    report('K3-gate-kit', GATE, n, 'SkeletonGate.ets 出现组件 / 装饰器 / 资源引用：' + n.getText().slice(0, 40));
  }
  motionTokens(gate, GATE);
  const enumDecl = topLevel(gate, (n) => ts.isEnumDeclaration(n) && n.name.text === 'SkeletonPhase')[0];
  const members = enumDecl ? enumDecl.members.map((m) => nameText(m.name)).sort().join(',') : '';
  if (!enumDecl || !hasExport(enumDecl) || members !== 'CONTENT,HIDDEN,SHOWING') {
    report('K3-gate-api', GATE, enumDecl || null, 'export enum SkeletonPhase { HIDDEN, SHOWING, CONTENT }（书 §2.4），实际 ' + (members || '缺'));
  }
  const clock = topLevel(gate, (n) => ts.isInterfaceDeclaration(n) && n.name.text === 'SkeletonClock')[0];
  if (!clock || !hasExport(clock) || !clock.members.some((m) => nameText(m.name) === 'now')) {
    report('K3-gate-api', GATE, clock || null, 'export interface SkeletonClock { now(): number; }（书 §2.4：时钟注入）');
  }
  const shimmer = topLevel(gate, (n) => ts.isFunctionDeclaration(n) && n.name && n.name.text === 'shimmerEnabled')[0];
  if (!shimmer || !hasExport(shimmer) || shimmer.parameters.length !== 1) {
    report('K3-gate-api', GATE, shimmer || null, 'export function shimmerEnabled(reduced: boolean): boolean（书 §3 逻辑 8）');
  }
  const cls = topLevel(gate, (n) => ts.isClassDeclaration(n) && n.name && n.name.text === 'SkeletonGate')[0];
  if (!cls || !hasExport(cls)) { report('K3-gate-api', GATE, cls || null, 'export class SkeletonGate（书 §2.4）'); return; }
  for (const m of ['loadingChanged', 'tick', 'nextDueInMs', 'markOnScreen']) {
    if (!methodOf(cls, m)) {
      report('K3-gate-api', GATE, cls, 'SkeletonGate 缺方法 ' + m + '()（书 §2.4' +
        (m === 'markOnScreen' ? '；HM-BATCH1-DEVFIX §3.4：最短显示从骨架上屏起算' : '') + '）');
    }
  }
  const ctor = cls.members.find((m) => ts.isConstructorDeclaration(m));
  if (!ctor || ctor.parameters.length !== 1 || !ctor.parameters[0].type || ctor.parameters[0].type.getText() !== 'SkeletonClock') {
    report('K3-gate-api', GATE, ctor || cls, 'SkeletonGate 构造参数应为 (clock: SkeletonClock)（时钟注入，方案 :93）');
  }
  for (const key of ['SHOW_DELAY_MS', 'MIN_VISIBLE_MS']) {
    const p = propOf(cls, key);
    const mods = p ? (p.modifiers || []).map((x) => x.kind) : [];
    const ok = p && mods.includes(ts.SyntaxKind.StaticKeyword) && mods.includes(ts.SyntaxKind.ReadonlyKeyword) && isNumber(p.initializer, 300);
    if (!ok) { report('K3-gate-const', GATE, p || cls, 'SkeletonGate.' + key + ' 应为 static readonly … = 300（方案 :78「约 300ms」）'); }
    const uses = collect(cls, (n) => ts.isIdentifier(n) && n.text === key && !(p && n === p.name));
    if (p && !uses.length) { report('K3-gate-const', GATE, p, 'SkeletonGate.' + key + ' 声明了但门控里没用（时序另写了字面量）'); }
  }
  for (const n of collect(cls, (x) => (ts.isPropertyAccessExpression(x) && ['Date.now', 'performance.now'].includes(compact(x))) ||
    (ts.isNewExpression(x) && compact(x.expression) === 'Date') ||
    (ts.isIdentifier(x) && ['setTimeout', 'setInterval', 'systemDateTime'].includes(x.text)))) {
    report('K3-gate-clock', GATE, n, 'SkeletonGate 类里直接取时间 / 定时：' + n.getText().slice(0, 30) + '（时钟只经注入的 SkeletonClock，可单测）');
  }
  for (const n of collect(cls, (x) => ts.isIdentifier(x) && (/reduc/i.test(x.text) || ['CouliMotion', 'MotionPolicy'].includes(x.text)))) {
    report('K3-gate-reduced', GATE, n, 'SkeletonGate 类里出现 ' + n.text + '（书 §3 逻辑 7：减弱动态不影响 300 / 300 门控，只影响微光）');
  }
}

// ---------------------------------------------------------------- K7：目录（AST 部分）

function arrayStrings(e) {
  e = unwrap(e);
  if (!e || !ts.isArrayLiteralExpression(e)) { return null; }
  const out = [];
  for (const x of e.elements) { const v = stringValue(x); if (v === null) { return null; } out.push(v); }
  return out;
}
function manifestCases(entry) {
  const mats = unwrap(entry.arguments[4]);
  if (!mats || !ts.isArrayLiteralExpression(mats)) { return null; }
  const cases = [];
  for (const m of mats.elements) {
    const call = unwrap(m);
    if (!ts.isCallExpression(call) || compact(call.expression) !== 'm' || call.arguments.length !== 2) { return null; }
    const vs = arrayStrings(call.arguments[0]);
    const ss = arrayStrings(call.arguments[1]);
    if (!vs || !ss) { return null; }
    for (const v of vs) { for (const s of ss) { cases.push(v + '/' + s); } }
  }
  return cases.sort();
}
function checkManifest() {
  const sf = need(MANIFEST);
  if (!sf) { return; }
  const entries = collect(sf, (n) => ts.isCallExpression(n) && compact(n.expression) === 'c' && n.arguments.length >= 5);
  const want = { Skeleton: ['host/gated', 'order/loading', 'product/loading', 'wallet/loading'], ProductCardSkeleton: ['list/loading'] };
  facts.manifestCases = {};
  for (const comp of Object.keys(want)) {
    const hits = entries.filter((e) => stringValue(e.arguments[0]) === comp);
    if (hits.length !== 1) { report('K7-manifest', MANIFEST, null, "CatalogManifest 应恰有一条 c('" + comp + "', …)，实际 " + hits.length); continue; }
    const e = hits[0];
    const cases = manifestCases(e);
    facts.manifestCases[comp] = cases;
    if (compact(e.arguments[1]) !== 'GROUP_FEEDBACK' || compact(e.arguments[2]) !== 'KIND_L2') {
      report('K7-manifest', MANIFEST, e, comp + ' 应在 GROUP_FEEDBACK、KIND_L2（L2 业务组件）');
    }
    if (!cases || cases.join(' ') !== want[comp].join(' ')) {
      report('K7-manifest', MANIFEST, e, comp + ' 目录矩阵应为 ' + want[comp].join(' ') + '，实际 ' + (cases ? cases.join(' ') : '求不出') +
        (comp === 'Skeleton' ? "（product / order / wallet × loading 不变，加 m(['host'], ['gated']) 供 SkeletonHost 设备用例）" : ''));
    }
  }
}
function checkSamples() {
  const sf = need(SAMPLES);
  if (!sf) { return; }
  for (const name of ['SkeletonProductCard', 'SkeletonOrderCard', 'SkeletonWalletCard', 'SkeletonHost']) {
    if (!componentCalls(sf, name).length) {
      report('K7-samples', SAMPLES, null, 'CatalogSampleViews 没有画 ' + name + '(…)（书 §2.3：order / wallet 内联样例换成新件；SkeletonHost 样例）');
    }
  }
  for (const n of componentCalls(sf, 'SkeletonBlock')) {
    report('K7-samples', SAMPLES, n, 'CatalogSampleViews 仍用 SkeletonBlock 现拼骨架（书 §2.3：样例画真实骨架件）');
  }
  const strings = new Set(collect(sf, (x) => ts.isStringLiteral(x) || ts.isNoSubstitutionTemplateLiteral(x)).map((x) => x.text));
  for (const id of SAMPLE_IDS) {
    if (!strings.has(id)) { report('K7-sample-ids', SAMPLES, null, "CatalogSampleViews 缺样例 id '" + id + "'（Ds02L2Ui L2SKEL 段契约）"); }
  }
  const hostCalls = componentCalls(sf, 'SkeletonHost');
  for (const h of hostCalls) {
    const props = objectProps(firstObjectArg(h));
    for (const key of ['loading', 'skeleton', 'content']) {
      if (!props.has(key)) { report('K7-samples', SAMPLES, h, 'SkeletonHost 样例没传 ' + key); }
    }
    let owner = h.parent;
    while (owner && !ts.isStructDeclaration(owner)) { owner = owner.parent; }
    if (owner) {
      const appear = attributeCalls(owner, ['onAppear']).length;
      const gone = attributeCalls(owner, ['onDisAppear']).length;
      if (appear < 2 || gone < 1) {
        report('K7-samples', SAMPLES, owner, 'SkeletonHost 样例应在骨架 / 内容节点上用 onAppear / onDisAppear 记时刻（≥ 2 / ≥ 1），实际 ' + appear + ' / ' + gone);
      }
    }
  }
  for (const shape of ['SkeletonOrderCard', 'SkeletonWalletCard']) {
    for (const call of componentCalls(sf, shape)) {
      let owner = call.parent;
      while (owner && !ts.isStructDeclaration(owner)) { owner = owner.parent; }
      if (!owner) { continue; }
      for (const n of attributeCalls(owner, ['backgroundColor', 'background', 'padding'])) {
        report('K7-sample-wrap', SAMPLES, n, '画 ' + shape + ' 的样例里有 .' + n.expression.name.text +
          '：catalog-control 容器应无内边距、无底色（白卡只能来自骨架件自己的 CouliCard，设备取色才有意义）');
      }
    }
  }
}

// ---------------------------------------------------------------- K8：登记（AST 部分）

function checkRegistered(rel, importPath, rule) {
  const sf = need(rel);
  if (!sf) { return; }
  let local = null;
  ts.forEachChild(sf, (n) => {
    if (ts.isImportDeclaration(n) && ts.isStringLiteral(n.moduleSpecifier) && n.moduleSpecifier.text === importPath &&
        n.importClause && n.importClause.name) { local = n.importClause.name.text; }
  });
  if (!local) { report(rule, rel, null, rel + " 没有 import … from '" + importPath + "'"); return; }
  const suite = topLevel(sf, (n) => ts.isFunctionDeclaration(n) && n.name && n.name.text === 'testsuite')[0];
  if (!suite || !suite.body) { incomplete.push(rel + '：缺 testsuite()'); return; }
  const direct = suite.body.statements.filter((s) => ts.isExpressionStatement(s) && ts.isCallExpression(s.expression) &&
    ts.isIdentifier(s.expression.expression) && s.expression.expression.text === local && s.expression.arguments.length === 0);
  const anywhere = collect(suite.body, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === local);
  if (direct.length !== 1 || anywhere.length !== 1) {
    report(rule, rel, suite, 'testsuite() 应在顶层恰调用一次 ' + local + '()，实际顶层 ' + direct.length + ' / 全部 ' + anywhere.length);
  }
}
function deviceFacts() {
  const sf = need(DEVICE_SUITE);
  if (!sf) { facts.deviceConst = null; return; }
  let list = null;
  walk(sf, (n) => {
    if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === 'L2SKEL_DEVICE_CASES' && n.initializer) {
      list = arrayStrings(n.initializer);
    }
  });
  facts.deviceConst = list;
  const its = collect(sf, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'it' &&
    n.arguments.length >= 1 && ts.isElementAccessExpression(n.arguments[0]) &&
    compact(n.arguments[0].expression) === 'L2SKEL_DEVICE_CASES');
  facts.deviceIndices = its.map((n) => {
    const a = unwrap(n.arguments[0].argumentExpression);
    return ts.isNumericLiteral(a) ? Number(a.text) : -1;
  });
  facts.deviceDescribes = collect(sf, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'describe' &&
    n.arguments.length >= 1 && ts.isStringLiteral(n.arguments[0])).map((n) => n.arguments[0].text);
  // 本段的 it 所在函数须在 describe('Ds02L2Ui', …) 的回调里恰被调用一次（同一套件、同一过滤 class=Ds02L2Ui）。
  const owners = new Set();
  for (const it of its) {
    let f = it.parent;
    while (f && !ts.isFunctionDeclaration(f) && !ts.isSourceFile(f)) { f = f.parent; }
    owners.add(f && ts.isFunctionDeclaration(f) && f.name ? f.name.text : '');
  }
  facts.deviceRegistered = false;
  if (its.length && owners.size === 1 && !owners.has('')) {
    const fn = [...owners][0];
    const describe = collect(sf, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'describe' &&
      stringValue(n.arguments[0]) === 'Ds02L2Ui')[0];
    const calls = describe ? collect(describe, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === fn) : [];
    const all = collect(sf, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === fn);
    facts.deviceRegistered = calls.length === 1 && all.length === 1;
  }
}

// ---------------------------------------------------------------- K9：页面不动

function checkPages() {
  const seen = {};
  for (const rel of input.scan || []) {
    const sf = parse(rel);
    if (!sf) { continue; }
    for (const n of collect(sf, (x) => ts.isIdentifier(x) && PAGE_FORBIDDEN.includes(x.text))) {
      report('K9-pages-new', rel, n, '页面 / 功能模块用了 ' + n.text + '（书 §2.5：本单不改页面，流程单迁 SkeletonHost）');
    }
    const counts = {};
    for (const name of ['SkeletonBlock', 'SkeletonProductCard']) {
      const k = componentCalls(sf, name).length;
      if (k) { counts[name] = k; }
    }
    if (Object.keys(counts).length) { seen[rel] = counts; }
  }
  const files = new Set([...Object.keys(seen), ...Object.keys(PAGE_CALLS)]);
  for (const rel of files) {
    const got = JSON.stringify(seen[rel] || {});
    const want = JSON.stringify(PAGE_CALLS[rel] || {});
    if (got !== want) {
      report('K9-pages-calls', rel, null, '页面骨架调用应原样 ' + want + '，实际 ' + got + '（书 §1 表 7 处 / 3 文件；3 处页面不动）');
    }
  }
}

try {
  checkSkeleton();
  checkProductCard();
  checkIndex();
  checkLogic();
  checkManifest();
  checkSamples();
  checkRegistered(DS_LIST, './SkeletonGate.test', 'K8-ds-list');
  deviceFacts();
  checkPages();
} catch (e) {
  incomplete.push('l2skeleton_ast.cjs 内部错误：' + (e && e.stack ? e.stack.split('\n').slice(0, 3).join(' | ') : String(e)));
}
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete, facts: facts }));
