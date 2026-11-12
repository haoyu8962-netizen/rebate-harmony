#!/usr/bin/env node
// HM-L2-STATE-harmony 宿主守卫的解析与判定部分（任务书 brief-STATE.md §3「结构」；由 check_l2_state.py 调用，不单独跑）。
// 用鸿蒙 SDK 的 ohos-typescript 解析 ArkTS：struct / 组件尾随闭包 / 装饰器 / 属性链都走 AST，注释与字符串里的字不算。
//   用法：node l2state_ast.cjs <typescript 包目录>
//   stdin：{"files": {"<相对路径>": "<源码>"}}（缺的文件不放进来，按「无法判定」处理）
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."], "facts": {...}}
// 规则（编号对应 check_l2_state.py 文件头）：
//   SL1 淡入：EmptyState / ErrorState 根 Column 链上恰一次 .transition(CouliMotion.appear())，struct 里别处无 transition；
//       不读 CouliMotion.reduced、不用 TransitionEffect（D10-1163 ①：减弱动态只取消位移，淡入保留，由 CouliMotion.appear 负责）
//   SL2 参数与重试：既有 @Param / @Event 不改名不改默认值；ErrorState 新增 @Param retrying: boolean = false 并传给 CouliButton.loading；
//       buttonId / disabled / onTap 照旧；onAppear 焦点回位 CouliFocusReturn.to(this.getUIContext(), this.retryId)；
//       aboutToAppear 播报 CouliAnnounce.say(this.getUIContext(), CouliAnnounce.errorText(this.title, this.message))
//   SL3 颜色与触感：颜色只来自 CouliColors（无 #hex / rgb()、无 Color.*、无 $r('…color…')、无渐变），色彩角色钉住；无 CouliHaptics / vibrator
//   SL4 图标：States.ets 只经 CouliIcon 画图标（无 Path / Image / SymbolGlyph 等直接绘制）；用到的名字在 SYMBOL_ICON_NAMES 里
//   SL5 播报纯函数：CouliAnnounce 有 static errorText(title: string, message: string): string，函数体不碰 UI / @kit
//   SL6 目录：CatalogManifest 的 ErrorState 含 trace6/retrying（原有 trace6、offline × default 保留），EmptyState 含 empty/default；
//       两条说明都写 ExceptionPrompt 复核结论「保留 L2」与「文案来自调用方」；目录 ErrorState 样例传 retrying 与 onRetry
//   SL7 登记：designsystem List.test 注册 l2StateTest()；entry ohosTest List.test 注册 Ds02L2Ui 默认导出且恰一次；
//       Ds02L2Ui.test.ets 里有 describe('Ds02L2UiState')（facts.deviceCases 交给 py 对 device-cases.txt）
//       HM-L2 批 1 集成 2（只换定位，integ2-harmony.md「§l2state 换定位」）：共用套件只剩一个 describe('Ds02L2Ui')（CARD / SKELETON 守卫
//       「恰一个」），STATE 的 it 在段函数 ds02L2UiStateCases 里，该函数在这个 describe 回调里恰调用一次（同 K8）；名单 / 下标照旧核对。
//   SL8 焦点接线（HM-BATCH1-DEVFIX swap2，编排 D10-1286 ①，#24 只加）：设备 l2state 31 不再硬判 isFocused（页面级 requestFocus 的结果
//       UiTest 读不到），改在宿主钉住「进入错误态时对 couli-error-retry 请求焦点」这次调用——
//       控件 id：ErrorState.retryId 默认 'couli-error-retry'、【重试】buttonId = this.retryId、设备套件 DEFAULT_RETRY_ID 同值；
//       触发时机：【重试】CouliButton 链上恰一个 .onAppear，回调是无参箭头函数、函数体恰一句（不包 setTimeout / if / 其它语句）
//         CouliFocusReturn.to(this.getUIContext(), this.retryId)；ErrorState 里别处不再移焦点（无第二个 CouliFocusReturn / requestFocus / focusControl）；
//       CouliFocusReturn 从 ./Overlays 导入；Overlays.ets 的 static to(ui, id) 里恰一处 ui.getFocusController().requestFocus(id)，同步执行
//         （不在嵌套函数里、只在 try 块里、不在任何 if 里），之前只许 if (id.length === 0) { return; } 一个提前返回；
//         HM-BATCH1-FREEZE 集成 3（#24 只换值，FU-HM-FOCUS-RETURN-STALE：to 改返回可作废票据 number）：上句的提前返回换成
//         if (id.length === 0) { return 0; }；另外 to 函数体最后一句必须恰是 return ticket;（不是提前返回，不能跳过任何语句），
//         其余位置不得有 return（插在键盘焦点之后、读屏焦点排队之前的 return 照样红）。
//         to 里恰一处 CouliFocusReturn.accessibilityFocus(ui, id)，accessibilityFocus 发 requestFocusForAccessibility 且 customId = id（读屏焦点）。
//       焦点真的落到【重试】由真机读屏核对一次、记进验收记录（不在本检查里）。
'use strict';
const fs = require('fs');
const path = require('path');

const STATES = 'common/designsystem/src/main/ets/components/States.ets';
const NAMES = 'common/designsystem/src/main/ets/logic/CouliIconNames.ets';
const MANIFEST = 'entry/src/staging/ets/catalog/CatalogManifest.ets';
const SAMPLES = 'entry/src/staging/ets/catalog/CatalogSampleViews.ets';
const DS_LIST = 'common/designsystem/src/test/List.test.ets';
const UI_LIST = 'entry/src/ohosTest/ets/test/List.test.ets';
const UI_SUITE = 'entry/src/ohosTest/ets/test/Ds02L2Ui.test.ets';
const LOGIC_SUITE = 'common/designsystem/src/test/L2State.test.ets';
// HM-BATCH1-DEVFIX swap2（D10-1286 ①，只加）：SL8 焦点接线要看 CouliFocusReturn 的实现。
const OVERLAYS = 'common/designsystem/src/main/ets/components/Overlays.ets';
const RETRY_DEFAULT_ID = 'couli-error-retry';
const FOCUS_CALL = 'CouliFocusReturn.to(this.getUIContext(),this.retryId)';
// 集成 2 换值：子集过滤 class=Ds02L2UiState 随单一 describe 不复存在，套件 describe 名统一为 Ds02L2Ui；STATE 段 = 段函数 UI_SEGMENT。
const UI_DESCRIBE = 'Ds02L2Ui';
const UI_SEGMENT = 'ds02L2UiStateCases';

const tsDir = process.argv[2];
if (!tsDir) { console.error('l2state_ast.cjs：缺少 typescript 包目录参数'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') {
  console.error('l2state_ast.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
function etsOptions() {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) {
    console.error('l2state_ast.cjs：读不到 ets 编译选项 ' + cfgPath);
    process.exit(3);
  }
  // 不传 etsLoaderPath：传了解析器会把 @kit.* 改写成 @ohos.*，这里要看源码原本写的模块名。
  return { ets: cfg.compilerOptions.ets };
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
  if (text === undefined) {
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
/** 组件调用（Column(){…}、Text(x)、CouliButton({…})）的名字；不是组件调用返回 ''。 */
function componentName(e) {
  if (!e) { return ''; }
  if (ts.isEtsComponentExpression(e) && ts.isIdentifier(e.expression)) { return e.expression.text; }
  if (ts.isCallExpression(e) && ts.isIdentifier(e.expression)) { return e.expression.text; }
  return '';
}
function argsOf(e) {
  return Array.from(e.arguments || []);
}
function decoratorsOf(node) {
  const list = ts.getAllDecorators ? ts.getAllDecorators(node) : (node.decorators || []);
  return Array.from(list || []).map((d) => {
    const x = ts.isCallExpression(d.expression) ? d.expression.expression : d.expression;
    return x.getText();
  });
}
function memberName(m) {
  return m.name && (ts.isIdentifier(m.name) || ts.isStringLiteral(m.name)) ? m.name.text : '';
}
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
function propName(p) {
  return p.name && (ts.isIdentifier(p.name) || ts.isStringLiteral(p.name)) ? p.name.text : '';
}
function objProp(obj, name) {
  for (const p of obj.properties) {
    if (propName(p) !== name) { continue; }
    if (ts.isPropertyAssignment(p)) { return p.initializer; }
    if (ts.isShorthandPropertyAssignment(p)) { return p.name; }
  }
  return undefined;
}
function objPropCount(obj, name) {
  return obj.properties.filter((p) => propName(p) === name).length;
}
/** 字符串字面量或其 + 拼接；求不出值返回 null。 */
function stringValue(e) {
  e = unwrap(e);
  if (!e) { return null; }
  if (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) { return e.text; }
  if (ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.PlusToken) {
    const a = stringValue(e.left);
    const b = stringValue(e.right);
    return a === null || b === null ? null : a + b;
  }
  return null;
}
function stringArray(e) {
  e = unwrap(e);
  if (!e || !ts.isArrayLiteralExpression(e)) { return null; }
  const out = [];
  for (const x of e.elements) {
    const v = stringValue(x);
    if (v === null) { return null; }
    out.push(v);
  }
  return out;
}
/** struct 的成员属性：{ name: { decorators, type, init, node } }。 */
function propsOf(struct) {
  const out = {};
  for (const m of struct.members) {
    if (!ts.isPropertyDeclaration(m)) { continue; }
    out[memberName(m)] = { decorators: decoratorsOf(m), type: m.type ? compact(m.type) : '', init: m.initializer ? compact(m.initializer) : null, node: m };
  }
  return out;
}
/** build() 里所有组件调用（含尾随闭包里的、if 分支里的）：[{ name, node, chain }]。 */
function componentsIn(method) {
  const out = [];
  walk(method, (n) => {
    const name = componentName(n);
    if (name === '' || !/^[A-Z]/.test(name)) { return; }
    // 只收每条链的根：父节点若是「.attr」访问则从链顶收
    let top = n;
    while (top.parent && ts.isPropertyAccessExpression(top.parent) && top.parent.expression === top &&
      top.parent.parent && ts.isCallExpression(top.parent.parent) && top.parent.parent.expression === top.parent) {
      top = top.parent.parent;
    }
    out.push({ name: name, node: n, chain: chainOf(top), top: top });
  });
  return out;
}
function isCouliColor(e) {
  e = unwrap(e);
  return !!e && ts.isPropertyAccessExpression(e) && ts.isIdentifier(e.expression) && e.expression.text === 'CouliColors';
}

// ---------------------------------------------------------------- States.ets

const STATE_STRUCTS = ['EmptyState', 'ErrorState'];
const PARAMS = {
  EmptyState: [['icon', 'string', "'search'"], ['title', 'string', "''"], ['message', 'string', "''"], ['actionText', 'string', "''"]],
  ErrorState: [['title', 'string', "''"], ['message', 'string', "''"], ['retryText', 'string', "''"],
    ['retryId', 'string', "'couli-error-retry'"], ['retryDisabled', 'boolean', 'false'], ['retrying', 'boolean', 'false']]
};
const EVENTS = { EmptyState: 'onAction', ErrorState: 'onRetry' };
// 色彩角色（brief §1 现状、§3 设备「深浅：底色 / 图标色令牌角色」）：块底色、图标色、标题 / 正文字色。
const ROLES = {
  EmptyState: { block: 'CouliColors.backgroundMuted', icon: 'CouliColors.textSecondary', text: ['CouliColors.textPrimary', 'CouliColors.textSecondary'] },
  ErrorState: { block: 'CouliColors.statusErrorBackground', icon: 'CouliColors.statusErrorText', text: ['CouliColors.textPrimary', 'CouliColors.textSecondary'] }
};
const COLOR_ATTRS = new Set(['backgroundColor', 'fontColor', 'borderColor', 'foregroundColor', 'selectedColor', 'color']);
const COLOR_KEYS = new Set(['color', 'fontColor', 'backgroundColor', 'borderColor', 'selectedColor']);
const FORBIDDEN_PAINT = new Set(['linearGradient', 'radialGradient', 'sweepGradient', 'colorBlend', 'foregroundBlurStyle']);
const DIRECT_DRAW = new Set(['Path', 'Image', 'SymbolGlyph', 'Shape', 'Circle', 'Rect', 'Ellipse', 'Polygon', 'Polyline', 'Canvas', 'ImageSpan']);
const HAPTIC_IDS = new Set(['CouliHaptics', 'vibrator', 'HapticMoment', 'HapticPlan', 'HAPTIC_EFFECT']);

function symbolNames() {
  const sf = parse(NAMES);
  if (sf === null) { return null; }
  let names = null;
  walk(sf, (n) => {
    if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === 'SYMBOL_ICON_NAMES' && n.initializer) {
      names = stringArray(n.initializer);
    }
  });
  if (names === null) { incomplete.push(NAMES + '：读不出 SYMBOL_ICON_NAMES 数组字面量'); }
  return names;
}

function checkStateStruct(sf, name, symbols) {
  const struct = findStruct(sf, name);
  if (struct === null) { report('SL2-locate', null, 'States.ets 里没有 struct ' + name, STATES); return; }
  const props = propsOf(struct);
  // SL2-params：既有参数名、类型、默认值不变；retrying 新增
  for (const [p, type, init] of PARAMS[name]) {
    const got = props[p];
    if (!got || got.decorators.indexOf('Param') < 0) {
      report('SL2-params', struct, name + ' 缺 @Param ' + p + (p === 'retrying' ? '（书 §2.1 重试加载态）' : '（既有参数不改名）'));
      continue;
    }
    if (got.type !== type || got.init !== init) {
      report('SL2-params', got.node, name + '.' + p + ' 应为 ' + type + ' = ' + init + '，实际 ' + got.type + ' = ' + got.init);
    }
    if (got.decorators.indexOf('Once') >= 0 || got.decorators.indexOf('Require') >= 0) {
      report('SL2-params', got.node, name + '.' + p + ' 不得加 @Once / @Require（调用方不传时行为不变）');
    }
  }
  const ev = props[EVENTS[name]];
  if (!ev || ev.decorators.indexOf('Event') < 0) {
    report('SL2-params', struct, name + ' 缺 @Event ' + EVENTS[name]);
  }
  const build = methodOf(struct, 'build');
  if (build === null || !build.body) { report('SL1-root', struct, name + ' 没有 build()'); return; }

  // SL1：根 Column 链上恰一次 .transition(CouliMotion.appear())
  const stmts = build.body.statements;
  const root = stmts.length === 1 && ts.isExpressionStatement(stmts[0]) ? chainOf(stmts[0].expression) : null;
  if (root === null || componentName(root.root) !== 'Column') {
    report('SL1-root', build, name + ' 的 build() 应只有一个根 Column（淡入挂在根上）');
  } else {
    const tr = root.calls.filter((c) => c.name === 'transition');
    if (tr.length !== 1) {
      report('SL1-transition', root.root, name + ' 根 Column 上 .transition 应恰 1 次，实际 ' + tr.length + ' 次（书 §2.1 出现 / 消失淡入）');
    } else if (tr[0].args.length !== 1 || compact(tr[0].args[0]) !== 'CouliMotion.appear()') {
      report('SL1-transition', tr[0].node, name + ' 根 Column 的 transition 实参必须是 CouliMotion.appear()（减弱动态分支在 CouliMotion 内，D10-1163 ①），实际 ' +
        tr[0].args.map(compact).join(','));
    }
  }
  const allTransitions = collect(struct, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
    n.expression.name.text === 'transition');
  if (root !== null && allTransitions.some((n) => !root.calls.some((c) => c.node === n))) {
    report('SL1-transition', struct, name + ' 根以外的节点不得再挂 .transition（避免子节点重复淡入 / 用别的转场）');
  }

  const comps = componentsIn(build);
  // SL4：图标只经 CouliIcon
  for (const c of comps) {
    if (DIRECT_DRAW.has(c.name)) { report('SL4-draw', c.node, name + ' 里直接画 ' + c.name + '（图标一律经 CouliIcon，ICON-SYMBOL 已走系统符号）'); }
  }
  const icons = comps.filter((c) => c.name === 'CouliIcon');
  if (icons.length !== 1) {
    report('SL4-icon', build, name + ' 应恰有一个 CouliIcon，实际 ' + icons.length);
  }
  for (const ic of icons) {
    const obj = argsOf(ic.node).length === 1 ? unwrap(argsOf(ic.node)[0]) : null;
    if (!obj || !ts.isObjectLiteralExpression(obj)) { report('SL4-icon', ic.node, 'CouliIcon 实参应是对象字面量'); continue; }
    const nameArg = objProp(obj, 'name');
    if (name === 'ErrorState') {
      const v = nameArg ? stringValue(nameArg) : null;
      if (v !== 'alert') { report('SL4-icon', ic.node, 'ErrorState 的图标应为 CouliIcon 现行名 \'alert\'（状态不只靠颜色），实际 ' + (nameArg ? compact(nameArg) : '缺')); }
    } else if (!nameArg || compact(nameArg) !== 'this.icon') {
      report('SL4-icon', ic.node, 'EmptyState 的图标名应取 this.icon（调用方传），实际 ' + (nameArg ? compact(nameArg) : '缺'));
    }
    const color = objProp(obj, 'color');
    if (!color || compact(color) !== ROLES[name].icon) {
      report('SL3-role', ic.node, name + ' 图标色应为 ' + ROLES[name].icon + '，实际 ' + (color ? compact(color) : '缺'));
    }
  }
  if (symbols !== null) {
    const used = name === 'ErrorState' ? ['alert'] : [];
    if (name === 'EmptyState' && props.icon && props.icon.init) {
      used.push(props.icon.init.replace(/^'|'$/g, ''));
    }
    for (const u of used) {
      if (symbols.indexOf(u) < 0) { report('SL4-symbol', struct, name + ' 用到的图标名 ' + u + ' 不在 SYMBOL_ICON_NAMES（应走系统符号）'); }
    }
  }
  // SL3-role：块底色、字色
  const bgCalls = [];
  for (const c of comps) {
    for (const call of c.chain.calls) { if (call.name === 'backgroundColor') { bgCalls.push(call); } }
  }
  const bgs = bgCalls.map((c) => c.args.length === 1 ? compact(c.args[0]) : '?');
  if (bgs.length !== 1 || bgs[0] !== ROLES[name].block) {
    report('SL3-role', build, name + ' 的图标块底色应恰为 ' + ROLES[name].block + '（只此一处 backgroundColor），实际 [' + bgs.join(', ') + ']');
  }
  const mods = collect(build, (n) => ts.isNewExpression(n) && n.expression.getText() === 'CouliTextModifier');
  const textColors = mods.map((n) => (n.arguments && n.arguments.length > 1) ? compact(n.arguments[1]) : '?');
  if (textColors.join('|') !== ROLES[name].text.join('|')) {
    report('SL3-role', build, name + ' 标题 / 正文字色应依次为 ' + ROLES[name].text.join(' / ') + '，实际 ' + textColors.join(' / '));
  }

  if (name === 'ErrorState') { checkRetry(struct, comps); }
}

function checkRetry(struct, comps) {
  const buttons = comps.filter((c) => c.name === 'CouliButton');
  if (buttons.length !== 1) { report('SL2-retry', struct, 'ErrorState 应恰有一个 CouliButton（【重试】），实际 ' + buttons.length); return; }
  const b = buttons[0];
  const obj = argsOf(b.node).length === 1 ? unwrap(argsOf(b.node)[0]) : null;
  if (!obj || !ts.isObjectLiteralExpression(obj)) { report('SL2-retry', b.node, '【重试】CouliButton 实参应是对象字面量'); return; }
  const want = { text: 'this.retryText', buttonId: 'this.retryId', disabled: 'this.retryDisabled', loading: 'this.retrying' };
  for (const key of Object.keys(want)) {
    const v = objProp(obj, key);
    if (objPropCount(obj, key) !== 1 || !v || compact(v) !== want[key]) {
      report(key === 'loading' ? 'SL2-loading' : 'SL2-retry', obj, '【重试】CouliButton 的 ' + key + ' 应为 ' + want[key] +
        (key === 'loading' ? '（书 §2.1：retrying 透传加载态，加载时按钮 inactive 防连点）' : '') + '，实际 ' + (v ? compact(v) : '缺'));
    }
  }
  const variant = objProp(obj, 'variant');
  if (variant && compact(variant) !== 'CouliButtonVariant.PRIMARY') {
    report('SL2-retry', obj, '【重试】是主按钮（GUIDE §3），variant 不应改成 ' + compact(variant));
  }
  const tap = objProp(obj, 'onTap');
  const tapCalls = tap ? collect(tap, (n) => ts.isCallExpression(n)).map((n) => compact(n.expression)) : [];
  if (tapCalls.filter((t) => t === 'this.onRetry').length !== 1) {
    report('SL2-retry', obj, '【重试】onTap 里应恰调用一次 this.onRetry()');
  }
  const appear = b.chain.calls.filter((c) => c.name === 'onAppear');
  const focusOk = appear.length === 1 && appear[0].args.length === 1 &&
    collect(appear[0].args[0], (n) => ts.isCallExpression(n)).some((n) => compact(n) === 'CouliFocusReturn.to(this.getUIContext(),this.retryId)');
  if (!focusOk) {
    report('SL2-focus', b.node, '【重试】链上应恰一个 .onAppear，内调 CouliFocusReturn.to(this.getUIContext(), this.retryId)（焦点回位，adaptation-a11y-spec §10）');
  }
  const about = methodOf(struct, 'aboutToAppear');
  const sayOk = about !== null && collect(about, (n) => ts.isCallExpression(n))
    .some((n) => compact(n) === 'CouliAnnounce.say(this.getUIContext(),CouliAnnounce.errorText(this.title,this.message))');
  if (!sayOk) {
    report('SL2-announce', about || struct, 'ErrorState.aboutToAppear 应调 CouliAnnounce.say(this.getUIContext(), CouliAnnounce.errorText(this.title, this.message))（播报串走纯函数，L2State 单测钉住）');
  }
}

function checkStatesFile(symbols) {
  const sf = parse(STATES);
  if (sf === null) { return; }
  // 导入：CouliMotion 来自 ./CouliMotion；不导入触感
  const imports = sf.statements.filter((s) => ts.isImportDeclaration(s));
  const importedFrom = {};
  for (const imp of imports) {
    const mod = imp.moduleSpecifier.text;
    const named = imp.importClause && imp.importClause.namedBindings && ts.isNamedImports(imp.importClause.namedBindings)
      ? imp.importClause.namedBindings.elements.map((e) => e.name.text) : [];
    for (const n of named) { importedFrom[n] = mod; }
    if (mod === '@kit.SensorServiceKit' || mod === '@ohos.vibrator' || /CouliHaptics$|HapticMoments$/.test(mod)) {
      report('SL3-haptics', imp, 'States.ets 不得导入触感（' + mod + '）：失败触感由调用方给（README §3.2）');
    }
  }
  if (importedFrom.CouliMotion !== './CouliMotion') {
    report('SL1-import', sf, 'States.ets 应从 ./CouliMotion 导入 CouliMotion', STATES);
  }
  walk(sf, (n) => {
    if (ts.isIdentifier(n) && HAPTIC_IDS.has(n.text)) {
      report('SL3-haptics', n, 'States.ets 出现触感标识 ' + n.text + '（本单无触感时刻，README §3.2）');
    }
    if (ts.isPropertyAccessExpression(n) && ts.isIdentifier(n.expression)) {
      if (n.expression.text === 'CouliMotion' && n.name.text !== 'appear') {
        report('SL1-reduced', n, 'States.ets 只用 CouliMotion.appear()，不自己读 ' + compact(n) + '（减弱动态由 CouliMotion 处理，淡入保留）');
      }
      if (n.expression.text === 'TransitionEffect') {
        report('SL1-reduced', n, 'States.ets 不直接用 TransitionEffect（' + compact(n) + '），统一走 CouliMotion.appear()');
      }
      if (n.expression.text === 'Color') {
        report('SL3-color', n, '颜色只来自 CouliColors，不用 ' + compact(n));
      }
    }
    if ((ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)) && /^\s*(#[0-9a-fA-F]{3,8}|rgba?\(|hsla?\()/.test(n.text)) {
      report('SL3-color', n, '颜色只来自 CouliColors，不写死 ' + n.text);
    }
    if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && (n.expression.text === '$r' || n.expression.text === '$rawfile')) {
      const v = n.arguments.length > 0 ? stringValue(n.arguments[0]) : null;
      if (v === null || /color/.test(v)) { report('SL3-color', n, '颜色只来自 CouliColors，不直接取资源 ' + compact(n)); }
    }
    if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)) {
      const attr = n.expression.name.text;
      if (FORBIDDEN_PAINT.has(attr)) { report('SL3-color', n, '不得用 .' + attr + '（颜色只来自 CouliColors）'); }
      if (COLOR_ATTRS.has(attr) && n.arguments.length > 0 && !isCouliColor(n.arguments[0])) {
        // 数组形式（fontColor([..])）逐个看
        const a = unwrap(n.arguments[0]);
        const items = ts.isArrayLiteralExpression(a) ? Array.from(a.elements) : [a];
        if (!items.every(isCouliColor)) { report('SL3-color', n, '.' + attr + ' 的颜色必须是 CouliColors.*，实际 ' + compact(n.arguments[0])); }
      }
    }
    if (ts.isPropertyAssignment(n) && COLOR_KEYS.has(propName(n)) && n.parent && ts.isObjectLiteralExpression(n.parent)) {
      const v = unwrap(n.initializer);
      const items = ts.isArrayLiteralExpression(v) ? Array.from(v.elements) : [v];
      if (!items.every(isCouliColor)) { report('SL3-color', n, propName(n) + ': 的颜色必须是 CouliColors.*，实际 ' + compact(n.initializer)); }
    }
    if (ts.isNewExpression(n) && n.expression.getText() === 'CouliTextModifier') {
      const a = n.arguments && n.arguments.length > 1 ? n.arguments[1] : null;
      if (!a || !isCouliColor(a)) { report('SL3-color', n, 'CouliTextModifier 的字色必须是 CouliColors.*，实际 ' + (a ? compact(a) : '缺')); }
    }
  });
  for (const name of STATE_STRUCTS) { checkStateStruct(sf, name, symbols); }
  checkAnnounce(sf);
}

// SL5：CouliAnnounce.errorText 纯函数（行为由 L2State.test 判；这里只判形状与「不碰 UI」）
function checkAnnounce(sf) {
  const cls = findClass(sf, 'CouliAnnounce');
  if (cls === null) { report('SL5-shape', null, 'States.ets 里没有 class CouliAnnounce', STATES); return; }
  if (!(cls.modifiers || []).some((m) => m.kind === ts.SyntaxKind.ExportKeyword)) {
    report('SL5-shape', cls, 'CouliAnnounce 应保持 export（Index.ets 导出它）');
  }
  const say = methodOf(cls, 'say');
  if (say === null) { report('SL5-shape', cls, 'CouliAnnounce.say 不得删（既有播报入口）'); }
  const m = methodOf(cls, 'errorText');
  if (m === null) { report('SL5-shape', cls, 'CouliAnnounce 缺 static errorText(title: string, message: string): string（播报串纯函数）'); return; }
  const isStatic = (m.modifiers || []).some((x) => x.kind === ts.SyntaxKind.StaticKeyword);
  const sig = m.parameters.map((p) => (p.type ? compact(p.type) : '?')).join(',');
  if (!isStatic || m.parameters.length !== 2 || sig !== 'string,string' || !m.type || compact(m.type) !== 'string') {
    report('SL5-shape', m, 'errorText 应为 static errorText(title: string, message: string): string，实际 ' + (isStatic ? 'static ' : '') + '(' + sig + ')' + (m.type ? ':' + compact(m.type) : ''));
  }
  if (m.body) {
    walk(m.body, (n) => {
      if (n.kind === ts.SyntaxKind.ThisKeyword) { report('SL5-pure', n, 'errorText 不得用 this（纯函数）'); }
      if (ts.isIdentifier(n) && ['accessibility', 'UIContext', 'setTimeout', 'Date', 'Math'].indexOf(n.text) >= 0 &&
        !(n.parent && ts.isPropertyAccessExpression(n.parent) && n.parent.name === n)) {
        report('SL5-pure', n, 'errorText 不得碰 ' + n.text + '（纯函数，只拼串）');
      }
    });
  }
}

// ---------------------------------------------------------------- 目录（staging）

function catalogEntries(sf) {
  const out = {};
  walk(sf, (n) => {
    if (!ts.isCallExpression(n) || !ts.isIdentifier(n.expression) || n.expression.text !== 'c' || n.arguments.length < 5) { return; }
    const name = stringValue(n.arguments[0]);
    if (name === null) { return; }
    const note = stringValue(n.arguments[3]);
    const cases = [];
    let readable = true;
    const mats = unwrap(n.arguments[4]);
    if (!ts.isArrayLiteralExpression(mats)) { readable = false; } else {
      for (const mm of mats.elements) {
        const call = unwrap(mm);
        if (!ts.isCallExpression(call) || !ts.isIdentifier(call.expression) || call.expression.text !== 'm' || call.arguments.length !== 2) { readable = false; continue; }
        const vs = stringArray(call.arguments[0]);
        const ss = stringArray(call.arguments[1]);
        if (vs === null || ss === null) { readable = false; continue; }
        for (const v of vs) { for (const s of ss) { cases.push(v + '/' + s); } }
      }
    }
    out[name] = { node: n, kind: n.arguments[2].getText(), note: note, cases: cases, readable: readable };
  });
  return out;
}

function checkCatalog() {
  const sf = parse(MANIFEST);
  if (sf !== null) {
    const entries = catalogEntries(sf);
    facts.catalog = {};
    const need = { EmptyState: ['empty/default'], ErrorState: ['trace6/default', 'offline/default', 'trace6/retrying'] };
    for (const name of Object.keys(need)) {
      const e = entries[name];
      if (!e) { report('SL6-manifest', null, 'CatalogManifest 缺 ' + name, MANIFEST); continue; }
      facts.catalog[name] = e.cases;
      if (!e.readable) { report('SL6-manifest', e.node, name + ' 的矩阵须是 [m([...], [...])] 字面量（读不出状态）'); }
      if (e.kind !== 'KIND_L2') { report('SL6-manifest', e.node, name + ' 应保持 KIND_L2，实际 ' + e.kind); }
      for (const k of need[name]) {
        if (e.cases.indexOf(k) < 0) {
          report('SL6-manifest', e.node, name + ' 缺目录状态 ' + k + (k === 'trace6/retrying' ? '（书 §2.2 补 retrying 态）' : '（既有状态不删）'));
        }
      }
      const note = e.note;
      if (note === null) { report('SL6-note', e.node, name + ' 的说明须是字符串字面量'); continue; }
      for (const must of ['ExceptionPrompt', '保留 L2', '调用方']) {
        if (note.indexOf(must) < 0) {
          report('SL6-note', e.node, name + ' 的目录说明应含「' + must + '」（方案 §1.1 ExceptionPrompt 复核：整页空态 / 错误态保留 L2；书 §2.3 文案来自调用方），实际：' + note);
        }
      }
      if (note.indexOf('外观不符') >= 0) { report('SL6-note', e.node, name + ' 的说明不应再写「外观不符」（复核结论是功能不等价）'); }
    }
    if (entries.EmptyState && entries.EmptyState.note !== null && entries.EmptyState.note.indexOf('页顶提示条') < 0) {
      report('SL6-note', entries.EmptyState.node, 'EmptyState 说明须保留「页顶提示条」（FEEL-KIT C7 同口径）');
    }
  }
  const sv = parse(SAMPLES);
  if (sv !== null) {
    const calls = collect(sv, (n) => componentName(n) === 'ErrorState');
    if (calls.length === 0) { report('SL6-sample', null, 'CatalogSampleViews 没有 ErrorState 样例', SAMPLES); }
    for (const call of calls) {
      const obj = argsOf(call).length === 1 ? unwrap(argsOf(call)[0]) : null;
      if (!obj || !ts.isObjectLiteralExpression(obj)) { report('SL6-sample', call, '目录 ErrorState 样例实参应是对象字面量'); continue; }
      if (objProp(obj, 'retrying') === undefined) { report('SL6-sample', obj, '目录 ErrorState 样例要传 retrying（retrying 态转圈、防连点）'); }
      if (objProp(obj, 'onRetry') === undefined) { report('SL6-sample', obj, '目录 ErrorState 样例要接 onRetry（点按计数 catalog-events/ErrorState，设备用例据此判防连点）'); }
    }
  }
}

// ---------------------------------------------------------------- 登记（SL7）与设备用例名单

/** testsuite() 函数体顶层直接调用 name() 的次数（if / 注释里不算）。 */
function topLevelCalls(sf, fnName, callee) {
  let fn = null;
  ts.forEachChild(sf, (n) => {
    if (ts.isFunctionDeclaration(n) && n.name && n.name.text === fnName) { fn = n; }
    if (ts.isFunctionDeclaration(n) && !n.name && (n.modifiers || []).some((x) => x.kind === ts.SyntaxKind.DefaultKeyword)) { fn = n; }
  });
  if (fn === null || !fn.body) { return -1; }
  return fn.body.statements.filter((s) => ts.isExpressionStatement(s) && ts.isCallExpression(s.expression) &&
    ts.isIdentifier(s.expression.expression) && s.expression.expression.text === callee && s.expression.arguments.length === 0).length;
}
function defaultImportFrom(sf, mod) {
  let name = null;
  for (const s of sf.statements) {
    if (ts.isImportDeclaration(s) && s.moduleSpecifier.text === mod && s.importClause && s.importClause.name) { name = s.importClause.name.text; }
  }
  return name;
}

function checkRegistration() {
  const ds = parse(DS_LIST);
  if (ds !== null) {
    const local = defaultImportFrom(ds, './L2State.test');
    if (local === null) { report('SL7-register', null, 'designsystem List.test.ets 没有 import <默认> from \'./L2State.test\'', DS_LIST); }
    else if (topLevelCalls(ds, 'testsuite', local) !== 1) { report('SL7-register', null, 'designsystem List.test.ets 的 testsuite 应在顶层直接调用 ' + local + '() 恰一次', DS_LIST); }
  }
  const ui = parse(UI_LIST);
  if (ui !== null) {
    const local = defaultImportFrom(ui, './Ds02L2Ui.test');
    if (local === null) { report('SL7-register', null, 'entry ohosTest List.test.ets 没有 import <默认> from \'./Ds02L2Ui.test\'（README ⑩ 共用套件）', UI_LIST); }
    else if (topLevelCalls(ui, 'testsuite', local) !== 1) { report('SL7-register', null, 'entry ohosTest List.test.ets 的 testsuite 应在顶层直接调用 ' + local + '() 恰一次', UI_LIST); }
  }
  const suite = parse(UI_SUITE);
  if (suite !== null) {
    const describes = collect(suite, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'describe' &&
      n.arguments.length >= 2 && stringValue(n.arguments[0]) === UI_DESCRIBE);
    // 集成 2 换定位：STATE 的 it 所在的「段」由 describe 节点换成段函数 UI_SEGMENT（模块顶层或 namespace 里恰一个同名函数声明），
    // 段函数须在 describe(UI_DESCRIBE) 回调里恰调用一次、全文件也只调这一次，段函数里不得另起 describe（否则用例不在该 describe 下）。
    const segments = collect(suite, (n) => ts.isFunctionDeclaration(n) && !!n.name && n.name.text === UI_SEGMENT && !!n.body);
    const segmentCall = (n) => ts.isCallExpression(n) && n.arguments.length === 0 &&
      ((ts.isIdentifier(n.expression) && n.expression.text === UI_SEGMENT) ||
       (ts.isPropertyAccessExpression(n.expression) && n.expression.name.text === UI_SEGMENT));
    if (describes.length !== 1) { report('SL7-suite', null, 'Ds02L2Ui.test.ets 应恰有一个 describe(\'' + UI_DESCRIBE + '\')', UI_SUITE); }
    else if (segments.length !== 1) { report('SL7-suite', describes[0], 'Ds02L2Ui.test.ets 应恰有一个 STATE 段函数 ' + UI_SEGMENT + '，实际 ' + segments.length + ' 个'); }
    else {
      const callsIn = collect(describes[0], segmentCall).length;
      const callsAll = collect(suite, segmentCall).length;
      if (callsIn !== 1 || callsAll !== 1) {
        report('SL7-suite', describes[0], UI_SEGMENT + '() 应在 describe(\'' + UI_DESCRIBE + '\') 回调里恰调用一次，实际 describe 内 ' + callsIn + ' / 全文件 ' + callsAll);
      }
      if (collect(segments[0].body, (n) => ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'describe').length > 0) {
        report('SL7-suite', segments[0], UI_SEGMENT + ' 里不得另起 describe（STATE 用例须直接注册在 describe(\'' + UI_DESCRIBE + '\') 下）');
      }
      // it 名字：字面量，或 L2STATE_DEVICE_CASES[<数字>]（同文件顶层数组字面量）
      let table = null;
      walk(suite, (n) => {
        if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === 'L2STATE_DEVICE_CASES' && n.initializer) { table = stringArray(n.initializer); }
      });
      const names = [];
      let unreadable = 0;
      walk(segments[0].body, (n) => {
        if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'it' && n.arguments.length >= 3) {
          const a = unwrap(n.arguments[0]);
          let v = stringValue(a);
          if (v === null && table !== null && ts.isElementAccessExpression(a) && ts.isIdentifier(a.expression) &&
            a.expression.text === 'L2STATE_DEVICE_CASES' && ts.isNumericLiteral(a.argumentExpression)) {
            const i = Number(a.argumentExpression.text);
            v = i < table.length ? table[i] : null;
          }
          if (v === null) { unreadable++; } else { names.push(v); }
        }
      });
      if (table !== null && table.length !== names.length) {
        report('SL7-suite', segments[0], 'L2STATE_DEVICE_CASES 有 ' + table.length + ' 个名字，' + UI_SEGMENT + ' 里实际注册 ' + names.length + ' 条');
      }
      if (unreadable > 0) { report('SL7-suite', segments[0], UI_SEGMENT + ' 里有 ' + unreadable + ' 条 it 名字不是字面量（名单无法核对）'); }
      facts.deviceCases = names;
    }
  }
  const logic = parse(LOGIC_SUITE);
  if (logic !== null) {
    const names = [];
    walk(logic, (n) => {
      if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === 'it' && n.arguments.length >= 3) {
        const v = stringValue(n.arguments[0]);
        if (v !== null) { names.push(v); }
      }
    });
    facts.logicCases = names;
  }
}

// ---------------------------------------------------------------- SL8 焦点接线（D10-1286 ①）

/** n 往上最近的函数类节点（方法 / 箭头函数 / 函数表达式）；到 stop 为止没有返回 null。 */
function enclosingFunction(n, stop) {
  for (let p = n.parent; p && p !== stop; p = p.parent) {
    if (ts.isFunctionLike(p)) { return p; }
  }
  return null;
}
/** 是不是移焦点的调用：CouliFocusReturn.<任意>、<任意>.requestFocus / requestFocusForAccessibility、focusControl.<任意>。 */
function isFocusMove(n) {
  if (!ts.isCallExpression(n) || !ts.isPropertyAccessExpression(n.expression)) { return false; }
  const owner = n.expression.expression.getText();
  const name = n.expression.name.text;
  return owner === 'CouliFocusReturn' || owner === 'focusControl' || name === 'requestFocus' || name === 'requestFocusForAccessibility';
}

function checkFocusWiring() {
  const sf = parse(STATES);
  if (sf !== null) {
    const imp = sf.statements.filter((s) => ts.isImportDeclaration(s)).find((s) => s.importClause && s.importClause.namedBindings &&
      ts.isNamedImports(s.importClause.namedBindings) && s.importClause.namedBindings.elements.some((e) => e.name.text === 'CouliFocusReturn'));
    if (!imp || imp.moduleSpecifier.text !== './Overlays') {
      report('SL8-import', imp || sf, 'States.ets 应从 ./Overlays 导入 CouliFocusReturn（焦点请求走 DS 的 FocusController 实现），实际 ' +
        (imp ? imp.moduleSpecifier.text : '没导入'), STATES);
    }
    const struct = findStruct(sf, 'ErrorState');
    const build = struct !== null ? methodOf(struct, 'build') : null;
    if (struct !== null && build !== null) {
      const retryId = propsOf(struct).retryId;
      if (!retryId || retryId.init !== "'" + RETRY_DEFAULT_ID + "'") {
        report('SL8-id', struct, 'ErrorState.retryId 默认值应为 \'' + RETRY_DEFAULT_ID + '\'（错误态出现时焦点目标），实际 ' + (retryId ? retryId.init : '缺'));
      }
      const buttons = componentsIn(build).filter((c) => c.name === 'CouliButton');
      if (buttons.length !== 1) {
        report('SL8-timing', struct, 'ErrorState 应恰有一个【重试】CouliButton（焦点在它出现时请求），实际 ' + buttons.length);
      } else {
        const b = buttons[0];
        const obj = argsOf(b.node).length === 1 ? unwrap(argsOf(b.node)[0]) : null;
        const bid = obj && ts.isObjectLiteralExpression(obj) ? objProp(obj, 'buttonId') : undefined;
        if (!bid || compact(bid) !== 'this.retryId') {
          report('SL8-id', b.node, '【重试】buttonId 应为 this.retryId（焦点请求的 id 就是按钮自身 id），实际 ' + (bid ? compact(bid) : '缺'));
        }
        const appear = b.chain.calls.filter((c) => c.name === 'onAppear');
        const fn = appear.length === 1 && appear[0].args.length === 1 ? unwrap(appear[0].args[0]) : null;
        let body = null;
        if (fn && (ts.isArrowFunction(fn) || ts.isFunctionExpression(fn)) && fn.parameters.length === 0) {
          if (ts.isBlock(fn.body)) {
            const st = fn.body.statements;
            body = st.length === 1 && ts.isExpressionStatement(st[0]) ? st[0].expression : null;
          } else {
            body = fn.body;
          }
        }
        if (body === null || compact(unwrap(body)) !== FOCUS_CALL) {
          report('SL8-timing', appear.length > 0 ? appear[0].node : b.node, '【重试】链上应恰一个 .onAppear，回调是无参函数、函数体恰一句 ' +
            'CouliFocusReturn.to(this.getUIContext(), this.retryId)（出现时同步、无条件请求焦点；不包 setTimeout / if，不加别的语句）');
        }
      }
      const moves = collect(struct, isFocusMove);
      const others = moves.filter((n) => compact(n) !== FOCUS_CALL);
      if (moves.length - others.length !== 1 || others.length > 0) {
        report('SL8-only', struct, 'ErrorState 里应只有【重试】onAppear 那一处移焦点，实际 ' + moves.map(compact).join(' ; '));
      }
    }
  }
  const ov = parse(OVERLAYS);
  if (ov !== null) {
    const cls = findClass(ov, 'CouliFocusReturn');
    const to = cls !== null ? methodOf(cls, 'to') : null;
    const isStatic = (m) => !!(m && m.modifiers && m.modifiers.some((x) => x.kind === ts.SyntaxKind.StaticKeyword));
    if (to === null || !to.body || !isStatic(to) || to.parameters.map((x) => x.name.getText()).join(',') !== 'ui,id') {
      report('SL8-request', to || cls || ov, 'Overlays.ets 应有 CouliFocusReturn.static to(ui, id)', OVERLAYS);
    } else {
      const reqs = collect(to.body, (n) => ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
        n.expression.name.text === 'requestFocus');
      let ok = reqs.length === 1 && compact(reqs[0]) === 'ui.getFocusController().requestFocus(id)' && enclosingFunction(reqs[0], to) === null;
      if (ok) {
        // 从调用往上到 to 的函数体：只许 ExpressionStatement / Block / TryStatement（且在 try 块里，不在 catch / finally 里）。
        let prev = reqs[0];
        for (let p = reqs[0].parent; p && p !== to.body; prev = p, p = p.parent) {
          if (ts.isTryStatement(p)) { if (p.tryBlock !== prev) { ok = false; } continue; }
          if (!ts.isExpressionStatement(p) && !ts.isBlock(p)) { ok = false; }
        }
        // 函数体顶层：这句之前只许 if (id.length === 0) { return; }；别处不得有提前返回。
        // HM-BATCH1-FREEZE 集成 3（#24 只换值）：to 返回票据后，提前返回换成 { return 0; }；末句恰为 return ticket;（见文件头 SL8）。
        const top = to.body.statements;
        const last = top.length > 0 ? top[top.length - 1] : null;
        const tail = last !== null && ts.isReturnStatement(last) && compact(last) === 'returnticket;' ? last : null;
        if (tail === null) { ok = false; }
        const at = top.findIndex((s) => s.pos <= reqs[0].pos && reqs[0].end <= s.end);
        for (let i = 0; i < at; i++) {
          const s = top[i];
          const guard = ts.isIfStatement(s) && !s.elseStatement && compact(s.expression) === 'id.length===0' &&
            compact(s.thenStatement) === '{return0;}';
          if (!guard) { ok = false; }
        }
        const returns = collect(to.body, (n) => ts.isReturnStatement(n) && enclosingFunction(n, to) === null);
        if (returns.some((r) => r !== tail && !(at > 0 && top.slice(0, at).some((s) => s.pos <= r.pos && r.end <= s.end)))) { ok = false; }
      }
      if (!ok) {
        report('SL8-request', reqs[0] || to, 'CouliFocusReturn.to 里应恰一处 ui.getFocusController().requestFocus(id)，同步执行（不在嵌套函数 / if / catch 里），' +
          '之前只许 if (id.length === 0) { return 0; }、末句恰为 return ticket;、别处无 return（集成 3 换值）；实际 ' + reqs.map(compact).join(' ; '), OVERLAYS);
      }
      const a11y = collect(to.body, (n) => ts.isCallExpression(n) && compact(n.expression) === 'CouliFocusReturn.accessibilityFocus');
      if (a11y.length !== 1 || compact(a11y[0]) !== 'CouliFocusReturn.accessibilityFocus(ui,id)') {
        report('SL8-a11y', a11y[0] || to, 'CouliFocusReturn.to 里应恰一处 CouliFocusReturn.accessibilityFocus(ui, id)（读屏焦点同一 id），实际 ' +
          a11y.map(compact).join(' ; '), OVERLAYS);
      }
    }
    const af = cls !== null ? methodOf(cls, 'accessibilityFocus') : null;
    const sets = af ? collect(af, (n) => ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      compact(n.left) === 'event.customId') : [];
    const evs = af ? collect(af, (n) => ts.isNewExpression(n) && compact(n.expression) === 'accessibility.EventInfo') : [];
    if (sets.length !== 1 || compact(sets[0].right) !== 'id' || evs.length !== 1 || !evs[0].arguments ||
      stringValue(evs[0].arguments[0]) !== 'requestFocusForAccessibility') {
      report('SL8-a11y', af || cls || ov, 'CouliFocusReturn.accessibilityFocus 应发 requestFocusForAccessibility 事件且 event.customId = id', OVERLAYS);
    }
  }
  const suite = parse(UI_SUITE);
  if (suite !== null) {
    const decls = collect(suite, (n) => ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.name.text === 'DEFAULT_RETRY_ID');
    if (decls.length !== 1 || !decls[0].initializer || stringValue(decls[0].initializer) !== RETRY_DEFAULT_ID) {
      report('SL8-suite', decls[0] || null, 'Ds02L2Ui.test.ets 的 STATE 段 DEFAULT_RETRY_ID 应恰一处、值 \'' + RETRY_DEFAULT_ID +
        '\'（设备用例找的重试控件就是焦点目标）', UI_SUITE);
    }
  }
}

const symbols = symbolNames();
checkStatesFile(symbols);
checkCatalog();
checkRegistration();
checkFocusWiring();
process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete, facts: facts }));
