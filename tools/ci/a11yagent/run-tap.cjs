#!/usr/bin/env node
// FU-HM-A11Y-AGENT-harmony #24 / D10-1339 ③（新鲜独立 Claude 补）：「点信息区进详情恰好一次，不会外壳和信息组各触发一次」的宿主执行级用例。
//   照 tools/ci/a11yagent/run-logic.cjs 的做法（SDK ohos-typescript 解析真实 .ets、执行真实方法体与处理器，替身只管 ArkUI 运行时）：
//   把真实 ProductCard.ets（ProductCard）、CouliCard.ets（CouliCard）、CouliPressable.ets（CouliPressable）的 build() / @Builder 按 if / else、
//   @Builder 调用、@BuilderParam 尾随闭包展开成组件树（只取树形与点击类属性；条件、实参、处理器都执行真实源码），再按 ArkUI 手势竞争规则
//   派发一次点击：命中链上 .onClick / .gesture(TapGesture) 是同类排他手势，子组件优先（最内层那个响应）；.parallelGesture 与之并行、各自都响应；
//   .priorityGesture 父组件优先（最外层那个响应）。读屏双击 = 对读屏焦点所在组件执行它自己的点击。onOpen / onBuy 换成计数器。
//   钉：LIST / AI / GRID × 回弹 / 减弱动态（CouliPressable 两支）× 字号 100% / 200%（价格区两种位置）：
//     ① openable=true 点信息区 → onOpen 恰 1 次、onBuy 0 次（外壳 CouliPressable 的 .onClick 不再同时触发）；
//     ② openable=true 读屏双击信息组 → onOpen 恰 1 次；
//     ③ openable=true 点信息区外的卡片空白处 → onOpen 恰 1 次（整卡按压仍由外壳承担）；
//     ④ openable=false 点信息区 → 卡内命中链上没有任何点击类手势、onOpen 0 次（不吞页面外层 .onClick，P2 原意）。
// 用法：
//   node tools/ci/a11yagent/run-tap.cjs                           真实产品（任一用例失败退出 1）
//   node tools/ci/a11yagent/run-tap.cjs --root <树>               换一棵树
//   node tools/ci/a11yagent/run-tap.cjs --swap <相对路径> <文件>   把某个源码换成 <文件>（参照件 / 变异体用，可多次）
//   node tools/ci/a11yagent/run-tap.cjs --expect-red              退出码取反（变异体必须至少一条失败）
//   node tools/ci/a11yagent/run-tap.cjs --self-test               参照件（fixtures/good 的 ProductCard.ets）全绿 + 逐个变异体被指定用例打红
// 这是 ArkUI 手势竞争的替身模型，不冒充设备：真机由 Ds02L2Ui l2cell_02（目录计数 open 恰 +1）与 HmA11yUi a11y_agent_01（返回一次回到 AI 助手）核。
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const { spawnSync } = require('child_process');
const loader = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const options = { ets: ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets,
  etsLoaderPath: loader };

const args = process.argv.slice(2);
const rootIndex = args.indexOf('--root');
const root = rootIndex >= 0 ? path.resolve(args[rootIndex + 1]) : path.resolve(__dirname, '../../..');
const swaps = new Map();
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--swap') { swaps.set(path.join(root, args[i + 1]), path.resolve(args[i + 2])); i += 2; }
}
const expectRed = args.includes('--expect-red');
const PC = 'common/designsystem/src/main/ets/components/ProductCard.ets';
const CARD = 'common/designsystem/src/main/ets/components/CouliCard.ets';
const PRESS = 'common/designsystem/src/main/ets/components/CouliPressable.ets';
const MOTION = 'common/designsystem/src/main/ets/components/CouliMotion.ets';
const GOOD = path.join(__dirname, 'fixtures', 'good');
/** 展开进组件树的 struct（名字 → 文件）；其余组件只记一个节点（含尾随闭包里的子树），不进它们的 build。 */
const REGISTRY = { ProductCard: PC, CouliCard: CARD, CouliPressable: PRESS };

// ---------------------------------------------------------------- 自测：参照件全绿、变异体逐个被指定用例打红（名字，文件，原串，新串，应红的用例名前缀）
const INFO_CLICK = "        .accessibilityRole(AccessibilityRoleType.BUTTON)\n        .onClick(() => {\n          this.onOpen();\n        })\n";
const INFO_PARALLEL = "        .accessibilityRole(AccessibilityRoleType.BUTTON)\n        .parallelGesture(TapGesture().onAction(() => {\n          this.onOpen();\n        }))\n";
const LIST_OPEN = "          this.listInfo()\n        }\n        .alignItems(HorizontalAlign.Start)\n        .width('100%')\n"
  + "        .accessibilityGroup(true)\n        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n" + INFO_CLICK;
const GRID_OPEN = LIST_OPEN.replace('this.listInfo()', 'this.gridInfoBody()');
const LIST_STATIC = "      } else {\n        Column({ space: CouliSpacing.space2 }) {\n          this.listInfo()\n        }\n"
  + "        .alignItems(HorizontalAlign.Start)\n        .width('100%')\n        .accessibilityGroup(true)\n"
  + "        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n      }\n";
const PRESS_TAP = "      .onClick((): void => {\n        if (this.disabled) {\n          return;\n        }\n        this.onTap();\n      })\n";
const PRESS_PARALLEL = "      .parallelGesture(TapGesture().onAction((): void => {\n        if (this.disabled) {\n          return;\n        }\n        this.onTap();\n      }))\n";
const BOUNCE_TAIL = "      .clickEffect({ level: ClickEffectLevel.LIGHT })\n      .enabled(!this.disabled)\n"
  + "      .accessibilityGroup(this.groupAccessibility)\n      .accessibilityText(this.a11yText)\n" + PRESS_TAP;
const HIGHLIGHT_TAIL = "        normal: { .backgroundColor(this.normalColor) }\n      })\n      .enabled(!this.disabled)\n"
  + "      .accessibilityGroup(this.groupAccessibility)\n      .accessibilityText(this.a11yText)\n" + PRESS_TAP;
const MUTANTS = [
  ['外壳（CouliPressable 回弹支）点击改并行手势：点信息区时外壳也触发 onOpen', PRESS, BOUNCE_TAIL,
    BOUNCE_TAIL.replace(PRESS_TAP, PRESS_PARALLEL), 'tap_list_bounce_font100_info_tap_open_once'],
  ['外壳（CouliPressable 减弱动态支）点击改并行手势', PRESS, HIGHLIGHT_TAIL,
    HIGHLIGHT_TAIL.replace(PRESS_TAP, PRESS_PARALLEL), 'tap_list_reduced_font100_info_tap_open_once'],
  ['列表信息组点击改并行手势：外壳与信息组各触发一次', PC, LIST_OPEN, LIST_OPEN.replace(INFO_CLICK, INFO_PARALLEL),
    'tap_list_bounce_font100_info_tap_open_once'],
  ['网格信息组点击改并行手势', PC, GRID_OPEN, GRID_OPEN.replace(INFO_CLICK, INFO_PARALLEL), 'tap_grid_bounce_font100_info_tap_open_once'],
  ['列表信息组处理器调两次 onOpen', PC, LIST_OPEN, LIST_OPEN.replace('          this.onOpen();\n', '          this.onOpen();\n          this.onOpen();\n'),
    'tap_list_bounce_font100_info_tap_open_once'],
  ['列表信息组不接点击（读屏双击到不了 onOpen）', PC, LIST_OPEN, LIST_OPEN.replace(INFO_CLICK, "        .accessibilityRole(AccessibilityRoleType.BUTTON)\n"),
    'tap_list_bounce_font100_reader_activate_info_open_once'],
  ['openable=false 的列表信息组也接点击（吞页面外层 .onClick）', PC, LIST_STATIC,
    LIST_STATIC.replace("        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n      }\n",
      "        .accessibilityText(ProductCardA11y.cellLabel(this.data))\n        .onClick(() => {\n          this.onOpen();\n        })\n      }\n"),
    'static_list_bounce_font100_info_tap_not_swallowed'],
];

function selfTest() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'a11yagent-tap-'));
  const failures = [];
  const run = (rel, file, wantRed) => {
    const argv = [__filename, '--root', root, '--swap', PC, rel === PC ? file : path.join(GOOD, PC)];
    if (rel !== null && rel !== PC) argv.push('--swap', rel, file);
    return spawnSync(process.execPath, argv.concat(wantRed ? ['--expect-red'] : []), { encoding: 'utf8' });
  };
  try {
    const good = run(null, null, false);
    if (good.status !== 0) failures.push('参照件不全绿：\n' + good.stdout.split('\n').filter(l => !l.startsWith('PASS')).join('\n'));
    else console.log('REFERENCE ' + good.stdout.trim().split('\n').pop());
    MUTANTS.forEach(([name, rel, from, to, want], i) => {
      const text = fs.readFileSync(rel === PC ? path.join(GOOD, PC) : path.join(root, rel), 'utf8');
      const count = text.split(from).length - 1;
      if (count !== 1) { failures.push('变异「' + name + '」原串出现 ' + count + ' 次（应 1 次）'); return; }
      const file = path.join(tmp, 'm' + i + '-' + path.basename(rel));
      fs.writeFileSync(file, text.replace(from, () => to));
      const r = run(rel, file, true);
      const red = r.stdout.split('\n').filter(l => l.startsWith('FAIL') || l.startsWith('LOAD_FAIL'));
      const hit = red.filter(l => l.replace(/^FAIL\[\w+\] /, '').startsWith(want));
      if (r.status !== 0 || hit.length === 0) {
        failures.push('变异「' + name + '」没被 ' + want + ' 杀（红的：' + (red.map(l => l.replace(/:.*$/, '')).join(', ') || '无') + '）');
      } else {
        console.log('KILLED ' + name + ' ← ' + hit.map(l => l.replace(/:.*$/, '')).join(', ') + '（共红 ' + red.length + ' 条）');
      }
    });
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  if (failures.length) {
    failures.forEach(f => console.log('SELFTEST FAIL: ' + f));
    console.log('A11YAGENT_TAP_SELFTEST 失败 ' + failures.length + ' / ' + (MUTANTS.length + 1));
    process.exitCode = 1;
  } else {
    console.log('A11YAGENT_TAP_SELFTEST 通过：参照件全绿 + 变异 ' + MUTANTS.length + ' 个全杀（各被指定用例打红）');
  }
}

if (args.includes('--self-test')) { selfTest(); return; }

// ---------------------------------------------------------------- 加载器（同 run-logic.cjs）
const noop = () => undefined;
for (const name of ['ObservedV2', 'Trace', 'Observed', 'Track', 'Local', 'Param', 'Once', 'Event', 'Provider', 'Consumer',
  'Monitor', 'Computed', 'Builder', 'BuilderParam', 'Component', 'ComponentV2', 'Entry', 'Concurrent', 'Sendable']) {
  if (global[name] === undefined) global[name] = noop;
}
// 与 run-logic.cjs 不同：@kit 里取不到的名字给 inert()（界面依赖在模块顶层就会取 LengthMetrics.vp 之类，本替身不看取值）。
const kitStub = new Proxy({}, { get: (_t, key) => key === '__esModule' ? false : (key === 'hilog'
  ? { warn: noop, info: noop, error: noop, debug: noop, fatal: noop, isLoggable: () => false } : inert()) });
const readSource = filename => fs.readFileSync(swaps.has(filename) ? swaps.get(filename) : filename, 'utf8');
const isStruct = s => ts.isStructDeclaration && ts.isStructDeclaration(s);
function parseEts(filename) {
  const tree = ts.createSourceFile(filename, readSource(filename), ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options);
  if (tree.parseDiagnostics.length) {
    throw new Error('PARSE_FAIL ' + path.relative(root, filename) + ': ' + ts.flattenDiagnosticMessageText(tree.parseDiagnostics[0].messageText, ' '));
  }
  return tree;
}
function transpile(source, filename) {
  return ts.transpileModule(source, { fileName: filename.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true } }).outputText;
}
const cache = new Map();
function load(filename) {
  if (cache.has(filename)) return cache.get(filename).exports;
  if (!fs.existsSync(swaps.has(filename) ? swaps.get(filename) : filename)) throw new Error('MISSING_SOURCE ' + path.relative(root, filename));
  const module = { exports: {} };
  cache.set(filename, module);
  let source = readSource(filename);
  let free = [];
  if (filename.endsWith('.ets')) {
    const tree = parseEts(filename);
    source = tree.statements.filter(s => !isStruct(s)).map(s => s.getText()).join('\n');
    free = freeNames(tree);
  }
  new vm.Script('(function(require,module,exports' + free.map(g => ',' + g).join('') + '){\n' + transpile(source, filename) + '\n})', { filename })
    .runInThisContext()(name => resolve(filename, name), module, module.exports, ...free.map(() => inert()));
  return module.exports;
}
function lazy(filename) {
  let real = null;
  const get = () => (real === null ? (real = load(filename)) : real);
  return new Proxy({}, { get: (_t, key) => (key === '__esModule' ? true : get()[key]), has: (_t, key) => key in get() });
}
function resolve(from, name) {
  if (name === 'generated') return lazy(path.join(root, 'common/generated/Index.ets'));
  if (name.startsWith('generated/')) {
    const rest = name.slice('generated/'.length) + '.ets';
    const hit = ['src/main', 'src/release'].map(d => path.join(root, 'common/generated', d, rest)).find(f => fs.existsSync(f));
    if (!hit) throw new Error('MISSING_SOURCE generated ' + name);
    return lazy(hit);
  }
  if (name.startsWith('@kit.') || name.startsWith('@ohos.') || name.startsWith('@hms.')) return kitStub;
  if (!name.startsWith('.')) throw new Error('Unsupported dependency: ' + name);
  const target = path.resolve(path.dirname(from), name);
  return lazy(target.endsWith('.ets') ? target : target + '.ets');
}
/** 文件里用到、却既非本文件声明 / import、也非 node 全局的大写或 $ 开头名字（ArkUI 全局：Color、Curve、$r、AccessibilityRoleType…）。 */
function freeNames(tree) {
  const declared = new Set();
  for (const s of tree.statements) {
    if (ts.isImportDeclaration(s) && s.importClause) {
      if (s.importClause.name) declared.add(s.importClause.name.text);
      const nb = s.importClause.namedBindings;
      if (nb && ts.isNamedImports(nb)) nb.elements.forEach(e => declared.add(e.name.text));
      if (nb && ts.isNamespaceImport(nb)) declared.add(nb.name.text);
    }
    if ((ts.isClassDeclaration(s) || ts.isEnumDeclaration(s) || ts.isFunctionDeclaration(s) || isStruct(s)) && s.name) declared.add(s.name.text);
    if (ts.isVariableStatement(s)) s.declarationList.declarations.forEach(d => ts.isIdentifier(d.name) && declared.add(d.name.text));
  }
  const free = new Set();
  const walk = (n) => {
    if (ts.isIdentifier(n) && /^[A-Z$]/.test(n.text) && !declared.has(n.text) && !(n.text in globalThis)
      && !(ts.isPropertyAccessExpression(n.parent) && n.parent.name === n)
      && !((ts.isPropertyAssignment(n.parent) || ts.isPropertyDeclaration(n.parent) || ts.isMethodDeclaration(n.parent)
        || ts.isEnumMember(n.parent) || ts.isTypeParameterDeclaration(n.parent)) && n.parent.name === n)) free.add(n.text);
    ts.forEachChild(n, walk);
  };
  walk(tree);
  return [...free];
}
/** ArkUI 全局（Color、HorizontalAlign、AccessibilityRoleType…）：本替身不看它们的取值，任意取属性 / 调用都不抛。 */
function inert() {
  const f = function () { return inert(); };
  return new Proxy(f, { get: (_t, key) => (key === '__esModule' ? false : (key === Symbol.toPrimitive ? () => '' : inert())),
    apply: () => inert(), construct: () => inert() });
}

// ---------------------------------------------------------------- 真实 struct → 可执行的方法与表达式
const TAP_ATTRS = { onClick: 'exclusive', gesture: 'exclusive', parallelGesture: 'parallel', priorityGesture: 'priority' };
const EVAL_ATTRS = ['onClick', 'accessibilityGroup', 'accessibilityText', 'enabled'];
const decoratorsOf = n => ((ts.getAllDecorators ? ts.getAllDecorators(n) : (n.decorators || [])) || []).map(d => d.expression.getText());

/** 一个 .ets 文件：非 struct 语句原文 + 每个 struct 的普通方法类 + build / @Builder 里要求值的表达式（各成一个函数，作用域里有该文件的 import）。 */
function loadUi(rel) {
  const file = path.join(root, rel);
  const tree = parseEts(file);
  const thunks = new Map();
  const parts = [];
  const structs = {};
  for (const s of tree.statements) {
    if (isStruct(s)) continue;
    if (ts.isFunctionDeclaration(s) && decoratorsOf(s).length > 0) {
      parts.push('function ' + (s.name ? s.name.text : '__builder') + '() {}');
      continue;
    }
    parts.push(s.getText());
  }
  const addThunk = (node, params) => {
    if (!thunks.has(node)) thunks.set(node, { id: thunks.size, params });
  };
  const gestureHandler = (arg) => {
    let fn = null;
    const walk = (n) => {
      if (!fn && ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === 'onAction'
        && n.arguments.length > 0) fn = n.arguments[0];
      ts.forEachChild(n, walk);
    };
    walk(arg);
    return fn;
  };
  for (const s of tree.statements.filter(isStruct)) {
    const name = s.name.text;
    const info = { decl: s, rel, file, builders: {}, builderParams: [], defaults: {}, methods: [] };
    structs[name] = info;
    for (const m of s.members) {
      const decos = decoratorsOf(m);
      if (ts.isPropertyDeclaration(m)) {
        if (decos.includes('BuilderParam')) { info.builderParams.push(m.name.getText()); continue; }
        if (m.initializer) { addThunk(m.initializer, []); info.defaults[m.name.getText()] = m.initializer; }
        continue;
      }
      if (!ts.isMethodDeclaration(m) || !m.body) continue;
      const mname = m.name.getText();
      if (mname === 'build' || decos.includes('Builder')) {
        const params = m.parameters.map(p => p.name.getText());
        info.builders[mname] = { body: m.body, params };
        const walk = (n) => {
          if (ts.isIfStatement(n)) addThunk(n.expression, params);
          if ((ts.isCallExpression(n) || (ts.isEtsComponentExpression && ts.isEtsComponentExpression(n)))) {
            const callee = n.expression;
            if (ts.isIdentifier(callee) && REGISTRY[callee.text] && n.arguments && n.arguments[0] && ts.isObjectLiteralExpression(n.arguments[0])) {
              n.arguments[0].properties.forEach(p => ts.isPropertyAssignment(p) && addThunk(p.initializer, params));
            }
            if (ts.isPropertyAccessExpression(callee) && callee.expression.kind === ts.SyntaxKind.ThisKeyword) {
              (n.arguments || []).forEach(a => addThunk(a, params));
            } else if (ts.isPropertyAccessExpression(callee) && n.arguments && n.arguments.length > 0) {
              const attr = callee.name.text;
              if (EVAL_ATTRS.includes(attr)) addThunk(n.arguments[0], params);
              else if (TAP_ATTRS[attr]) { const fn = gestureHandler(n.arguments[0]); if (fn) addThunk(fn, params); }
            }
          }
          ts.forEachChild(n, walk);
        };
        walk(m.body);
        continue;
      }
      if (decos.length === 0) info.methods.push(m.getText());
    }
  }
  const lines = [...parts, 'const __x = [];'];
  for (const [name, info] of Object.entries(structs)) {
    lines.push('exports.__S_' + name + ' = class {\n' + info.methods.join('\n') + '\n};');
  }
  for (const [node, t] of thunks) lines.push('__x[' + t.id + '] = function (' + t.params.join(', ') + ') { return (' + node.getText() + '); };');
  lines.push('exports.__x = __x;');
  const globalsList = freeNames(tree);
  const module = { exports: {} };
  new vm.Script('(function(require,module,exports' + globalsList.map(g => ',' + g).join('') + '){\n' + transpile(lines.join('\n'), file) + '\n})', { filename: file })
    .runInThisContext()(name => resolve(file, name), module, module.exports, ...globalsList.map(() => inert()));
  const thunk = (node) => {
    const t = thunks.get(node);
    if (!t) throw new Error(rel + ' 表达式没登记：' + node.getText().slice(0, 80));
    return module.exports.__x[t.id];
  };
  for (const [name, info] of Object.entries(structs)) { info.Cls = module.exports['__S_' + name]; info.thunk = thunk; }
  return structs;
}

// ---------------------------------------------------------------- 展开组件树
let UI = null;
function uiStructs() {
  if (UI) return UI;
  UI = {};
  for (const rel of new Set(Object.values(REGISTRY))) Object.assign(UI, loadUi(rel));
  for (const name of Object.keys(REGISTRY)) if (!UI[name]) throw new Error(REGISTRY[name] + ' 找不到 struct ' + name);
  return UI;
}
const call = (ctx, node) => ctx.info.thunk(node).apply(ctx.self, ctx.args);

function instantiate(name, props, content, attrs) {
  const info = uiStructs()[name];
  const self = Object.create(info.Cls.prototype);
  for (const [k, init] of Object.entries(info.defaults)) {
    if (k in props) continue;
    try { self[k] = info.thunk(init).call(self); } catch (e) { self[k] = undefined; }
  }
  Object.assign(self, props);
  self.__content = {};
  if (content && info.builderParams.length > 0) self.__content[info.builderParams[0]] = content;
  const node = { comp: name, attrs, children: [], self };
  const b = info.builders.build;
  if (!b) throw new Error(name + ' 没有 build()');
  execStatements(b.body.statements, { info, self, args: [] }, node);
  return node;
}

function execStatements(stmts, ctx, parent) {
  for (const s of stmts) {
    if (ts.isIfStatement(s)) {
      if (call(ctx, s.expression)) execStatements([s.thenStatement], ctx, parent);
      else if (s.elseStatement) execStatements([s.elseStatement], ctx, parent);
    } else if (ts.isBlock(s)) {
      execStatements(s.statements, ctx, parent);
    } else if (ts.isExpressionStatement(s)) {
      execExpr(s.expression, ctx, parent);
    }
  }
}

function execExpr(expr, ctx, parent) {
  const attrs = [];
  let e = expr;
  while (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression) && e.expression.expression.kind !== ts.SyntaxKind.ThisKeyword) {
    attrs.unshift({ name: e.expression.name.text, args: e.arguments, ctx });
    e = e.expression.expression;
  }
  const isComp = ts.isEtsComponentExpression && ts.isEtsComponentExpression(e);
  if ((isComp || ts.isCallExpression(e)) && ts.isPropertyAccessExpression(e.expression) && e.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
    const m = e.expression.name.text;
    const content = ctx.self.__content && ctx.self.__content[m];
    if (content) { execStatements(content.stmts, content.ctx, parent); return; }
    const b = ctx.info.builders[m];
    if (b) { execStatements(b.body.statements, { info: ctx.info, self: ctx.self, args: (e.arguments || []).map(a => call(ctx, a)) }, parent); }
    return;
  }
  if (!(isComp || ts.isCallExpression(e)) || !ts.isIdentifier(e.expression)) return;
  const name = e.expression.text;
  const body = isComp && e.body ? e.body : null;
  if (REGISTRY[name]) {
    const props = {};
    const obj = e.arguments && e.arguments[0];
    if (obj && ts.isObjectLiteralExpression(obj)) {
      obj.properties.forEach(p => { if (ts.isPropertyAssignment(p)) props[p.name.getText()] = call(ctx, p.initializer); });
    }
    parent.children.push(instantiate(name, props, body ? { stmts: body.statements, ctx } : null, attrs));
    return;
  }
  const node = { comp: name, attrs, children: [] };
  if (body && !['ForEach', 'LazyForEach', 'Repeat'].includes(name)) execStatements(body.statements, ctx, node);
  parent.children.push(node);
}

// ---------------------------------------------------------------- ArkUI 点击派发（替身）
function recognizers(node) {
  const out = [];
  for (const a of node.attrs) {
    const mode = TAP_ATTRS[a.name];
    if (!mode || !a.args[0]) continue;
    let fnNode = a.args[0];
    if (a.name !== 'onClick') {
      let hit = null;
      const walk = (n) => { if (!hit && ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === 'onAction') hit = n.arguments[0]; ts.forEachChild(n, walk); };
      walk(fnNode);
      const isTap = /^TapGesture\b/.test(a.args[0].getText());
      if (!hit || !isTap) continue;
      fnNode = hit;
    }
    out.push({ mode, comp: node.comp, attr: a.name, fn: call(a.ctx, fnNode) });
  }
  return out;
}
function pathTo(node, pred, trail = []) {
  const here = trail.concat([node]);
  if (pred(node)) return here;
  for (const c of node.children) { const p = pathTo(c, pred, here); if (p) return p; }
  return null;
}
function findAll(node, pred, out = []) {
  if (pred(node)) out.push(node);
  node.children.forEach(c => findAll(c, pred, out));
  return out;
}
/** 命中链（外 → 内）上的点击类手势：parallel 全响应；有 priority 时最外层那个响应，否则最内层的排他手势（onClick / gesture）响应。 */
function tap(chain) {
  const recs = chain.flatMap(recognizers);
  const fired = recs.filter(r => r.mode === 'parallel');
  const prio = recs.filter(r => r.mode === 'priority');
  const excl = recs.filter(r => r.mode === 'exclusive');
  if (prio.length > 0) fired.push(prio[0]);
  else if (excl.length > 0) fired.push(excl[excl.length - 1]);
  fired.forEach(r => r.fn({}));
  return { recs, fired };
}
/** 读屏双击：对焦点组件执行它自己的点击（不经命中链竞争）。 */
function activate(node) {
  const own = recognizers(node);
  own.forEach(r => r.fn({}));
  return own;
}

function scene(variant, openable, reduced, scale) {
  const pc = load(path.join(root, PC));
  load(path.join(root, MOTION)).CouliMotion.reduceEnabled = reduced;
  const data = new pc.ProductCardData();
  data.platformCode = 'taobao';
  data.platformLabel = '淘宝';
  data.title = '点一次测试商品';
  data.buyBase = '去购买';
  const counts = { open: 0, buy: 0 };
  const card = instantiate('ProductCard', {
    data, variant: pc.ProductCardVariant[variant], showBuy: true, openable,
    onOpen: () => { counts.open++; }, onBuy: () => { counts.buy++; },
  }, null, []);
  card.self.fontScale = { scale };
  // fontScale 在 instantiate 里已用默认值展开过一次，按本场景字号重展开
  card.children = [];
  execStatements(uiStructs().ProductCard.builders.build.body.statements, { info: uiStructs().ProductCard, self: card.self, args: [] }, card);
  const label = pc.ProductCardA11y.cellLabel(data);
  const isInfo = n => n.attrs.some(a => a.name === 'accessibilityGroup' && call(a.ctx, a.args[0]) === true)
    && n.attrs.some(a => a.name === 'accessibilityText' && call(a.ctx, a.args[0]) === label);
  const infos = findAll(card, isInfo);
  assert.strictEqual(infos.length, 1, variant + ' 应恰有一个信息组（accessibilityGroup(true) + 读屏名 = cellLabel），实际 ' + infos.length);
  return { card, counts, info: infos[0], chain: pathTo(card, n => n === infos[0]) };
}

const tests = [];
for (const variant of ['LIST', 'AI', 'GRID']) {
  for (const [reduced, rw] of [[false, 'bounce'], [true, 'reduced']]) {
    for (const [scale, fw] of [[1, 'font100'], [2, 'font200']]) {
      const tag = variant.toLowerCase() + '_' + rw + '_' + fw;
      const where = variant + (reduced ? ' 减弱动态' : ' 回弹') + ' 字号 ' + (scale * 100) + '%';
      tests.push({ name: 'tap_' + tag + '_info_tap_open_once', fn: () => {
        const s = scene(variant, true, reduced, scale);
        const r = tap(s.chain);
        assert.deepStrictEqual(s.counts, { open: 1, buy: 0 }, where + '：点信息区应 onOpen 恰 1 次、onBuy 0 次（外壳与信息组不能各触发一次）；响应的手势 '
          + JSON.stringify(r.fired.map(f => f.comp + '.' + f.attr + '/' + f.mode)) + '，实际 ' + JSON.stringify(s.counts));
        assert.ok(r.fired.length === 1 && r.fired[0].comp === 'Column' && r.fired[0].attr === 'onClick',
          where + '：响应点击的应是信息组自身的 .onClick，实际 ' + JSON.stringify(r.fired.map(f => f.comp + '.' + f.attr + '/' + f.mode)));
      } });
      tests.push({ name: 'tap_' + tag + '_reader_activate_info_open_once', fn: () => {
        const s = scene(variant, true, reduced, scale);
        activate(s.info);
        assert.deepStrictEqual(s.counts, { open: 1, buy: 0 }, where + '：读屏双击信息组应 onOpen 恰 1 次，实际 ' + JSON.stringify(s.counts));
      } });
      tests.push({ name: 'tap_' + tag + '_card_area_tap_open_once', fn: () => {
        const s = scene(variant, true, reduced, scale);
        tap(s.chain.slice(0, -1));
        assert.deepStrictEqual(s.counts, { open: 1, buy: 0 }, where + '：点信息区外的卡片空白处应由外壳 onOpen 恰 1 次，实际 ' + JSON.stringify(s.counts));
      } });
      tests.push({ name: 'static_' + tag + '_info_tap_not_swallowed', fn: () => {
        const s = scene(variant, false, reduced, scale);
        const r = tap(s.chain);
        assert.deepStrictEqual(r.recs.map(f => f.comp + '.' + f.attr), [], where + ' openable=false：信息区命中链上不得有点击类手势（会吞页面外层 .onClick）');
        assert.deepStrictEqual(s.counts, { open: 0, buy: 0 }, where + ' openable=false：点信息区不得触发 onOpen');
      } });
    }
  }
}

let failures = 0;
for (const test of tests) {
  try {
    test.fn();
    console.log('PASS ' + test.name);
  } catch (e) {
    failures++;
    const kind = e instanceof assert.AssertionError ? 'ASSERT' : 'THROW';
    const detail = e instanceof assert.AssertionError ? e.message : String(e && e.stack ? e.stack.split('\n').slice(0, 2).join(' ') : e);
    console.log('FAIL[' + kind + '] ' + test.name + ': ' + detail.split('\n')[0].slice(0, 400));
  }
}
console.log('A11YAGENT tap: ' + (tests.length - failures) + '/' + tests.length + ' passed; root=' + root + (swaps.size ? '; swaps=' + swaps.size : ''));
process.exitCode = expectRed ? (failures > 0 ? 0 : 1) : (failures > 0 ? 1 : 0);
