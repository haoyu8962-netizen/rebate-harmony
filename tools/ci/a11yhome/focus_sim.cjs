#!/usr/bin/env node
// FU-HM-A11Y-HOME-SEARCH-harmony 测试作者 v2（Codex r1 S2-1）：延时读屏移焦的执行级用例（可控定时器），由 check_a11y_home_search.py 调用（AH5）。
// 不看写法、看执行结果：用 SDK ohos-typescript 把真实源码转成可执行 JS——
//   · 页面：SearchView / HomePopupView 的 struct 转成类（字段初值、普通方法、生命周期原样；build / @Builder 不执行，只把其中组件的
//     onAppear / onDisAppear 等回调、bindSheet 选项回调、【价格】筛选片的 onTap 抽出来，按框架的时序调用）；
//   · 移焦：页面 import 的 CouliFocusReturn 按 designsystem Index.ets 的导出找到真实源文件执行（实现改在哪层都照跑）；
//   · 系统：@kit.AccessibilityKit 换成记录器（requestFocusForAccessibility 事件 = 一次读屏移焦），setTimeout / setInterval / 帧回调换成
//     可控时钟；UIContext、配置、未知全局名一律换成「什么都接受」的桩。
// 然后在可控时钟下走场景（打开 / 关闭 / 快速关 / 关后重开 / 离页 / 被盖住 / 弹窗关闭 / 弹窗跳转），判：作废事件之后不得再发旧目标的读屏移焦，
// 正常路径的读屏移焦仍要发出。合格写法两种都认：调用方执行时复核（页面仍在、弹层轮次、没被盖住），或底层可作废（票据 / 轮次 / 取消句柄）。
//   用法：node focus_sim.cjs <typescript 包目录> <树根>
//   stdout：{"violations": [{"rule", "file", "line", "msg"}], "incomplete": ["..."], "log": ["..."]}
// v3（Codex r2 S2，主会话口径「被详情盖住算离页，旧 / 新回焦请求都不得发出」）：补「开着被盖住 → 收起」「盖住后解除 → 正常开关」
// 「迟到的标题出现回调（被盖住 / 离页之后）」三类场景（AH5-sheet-cover-open / -uncover / -uncover-open / -late-appear-cover /
// -late-appear-leave）；打开拆成「点【价格】」与「半屏出现回调」两步，解除覆盖 = config.onCovered(false)。
// 不冒充设备：读屏焦点在模拟器读不到（D10-1231），真机走查见 A11yHomeSearchSeg.ets 文件头。
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SEARCH = 'features/search/src/main/ets/SearchView.ets';
const HOME = 'features/home/src/main/ets/HomeCards.ets';
const DS_INDEX = 'common/designsystem/Index.ets';
const ID_FILTER_PRICE = 'search_filter_price';
const ID_PRICE_TITLE = 'search_price_title';
const ID_PRICE_MIN = 'search_price_min';
const ID_PRICE_CONFIRM = 'search_price_confirm';
const ID_POPUP_CLOSE = 'home_popup_close';
/** 作废事件与前一步的间隔（ms）：远小于任何合理的读屏移焦延时（现 120 ms），保证旧请求此刻仍在排队。 */
const GAP = 10;
/** 每一步之后让时钟走多久（ms），把所有排队的回调跑完。 */
const SETTLE = 3000;

const tsDir = process.argv[2];
const ROOT = process.argv[3];
if (!tsDir || !ROOT) { console.error('focus_sim.cjs：用法 node focus_sim.cjs <typescript 包目录> <树根>'); process.exit(2); }
const ts = require(path.resolve(tsDir));
if (ts.ScriptKind.ETS === undefined || typeof ts.isStructDeclaration !== 'function') {
  console.error('focus_sim.cjs：' + tsDir + ' 不是能解析 ArkTS 的 ohos-typescript');
  process.exit(3);
}
const ETS_OPTIONS = (() => {
  const cfgPath = path.join(path.resolve(tsDir), '..', '..', 'tsconfig.json');
  const cfg = ts.readConfigFile(cfgPath, ts.sys.readFile).config;
  if (!cfg || !cfg.compilerOptions || !cfg.compilerOptions.ets) { console.error('focus_sim.cjs：读不到 ets 编译选项 ' + cfgPath); process.exit(3); }
  return { ets: cfg.compilerOptions.ets, etsLoaderPath: path.dirname(cfgPath) };
})();

const violations = [];
const incomplete = [];
const log = [];
class Incomplete extends Error {}

// ---------------------------------------------------------------- 解析工具
const parsed = new Map();
function parseFile(abs) {
  if (parsed.has(abs)) { return parsed.get(abs); }
  if (!fs.existsSync(abs)) { throw new Incomplete(path.relative(ROOT, abs) + '：文件不存在，无法判定'); }
  const text = fs.readFileSync(abs, 'utf8');
  const sf = ts.createSourceFile(abs, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, ETS_OPTIONS);
  if (sf.parseDiagnostics.length > 0) {
    const d = sf.parseDiagnostics[0];
    throw new Incomplete(path.relative(ROOT, abs) + ':' + (sf.getLineAndCharacterOfPosition(d.start).line + 1) + ' 语法错误：' +
      ts.flattenDiagnosticMessageText(d.messageText, ' '));
  }
  parsed.set(abs, sf);
  return sf;
}
function walk(node, visit) { visit(node); ts.forEachChild(node, (c) => walk(c, visit)); }
function unwrap(e) {
  while (e && (ts.isParenthesizedExpression(e) || ts.isAsExpression(e) || ts.isNonNullExpression(e))) { e = e.expression; }
  return e;
}
function isStr(n) { return n && (ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)); }
function memberName(m) { return m.name && (ts.isIdentifier(m.name) || ts.isStringLiteral(m.name)) ? m.name.text : ''; }
function lineOf(node) { return node.getSourceFile().getLineAndCharacterOfPosition(node.getStart()).line + 1; }
function decoratorsOf(node) {
  const out = [];
  for (const m of (node.modifiers || [])) { if (m.kind === ts.SyntaxKind.Decorator) { out.push(m); } }
  for (const m of (node.decorators || [])) { if (out.indexOf(m) < 0) { out.push(m); } }
  return out;
}
function decoratorName(d) {
  const e = d.expression;
  if (ts.isIdentifier(e)) { return e.text; }
  if (ts.isCallExpression(e) && ts.isIdentifier(e.expression)) { return e.expression.text; }
  return '';
}
/** 去掉装饰器后的源码文本。 */
function textWithoutDecorators(node) {
  const decs = decoratorsOf(node);
  const sf = node.getSourceFile();
  let start = node.getStart();
  if (decs.length) {
    start = Math.max(...decs.map((d) => d.end));
    while (/\s/.test(sf.text[start])) { start++; }
  }
  return sf.text.slice(start, node.end);
}
function chainOf(expr) {
  const calls = [];
  let e = unwrap(expr);
  while (ts.isCallExpression(e) && ts.isPropertyAccessExpression(e.expression)) {
    calls.unshift({ name: e.expression.name.text, args: Array.from(e.arguments), node: e });
    e = unwrap(e.expression.expression);
  }
  return { root: e, calls: calls };
}
function property(obj, name) {
  if (!obj || !ts.isObjectLiteralExpression(obj)) { return null; }
  const p = obj.properties.find((x) => x.name && (ts.isIdentifier(x.name) || ts.isStringLiteral(x.name)) && x.name.text === name);
  if (!p) { return null; }
  if (ts.isPropertyAssignment(p)) { return p.initializer; }
  if (ts.isMethodDeclaration(p)) { return p; }
  return null;
}
/** 模块 const 字面量与类 static readonly 字符串（键「类.成员」）。 */
function moduleConsts(sf) {
  const out = new Map();
  ts.forEachChild(sf, (n) => {
    if (ts.isVariableStatement(n) && (n.declarationList.flags & ts.NodeFlags.Const)) {
      for (const d of n.declarationList.declarations) {
        if (ts.isIdentifier(d.name) && d.initializer && isStr(unwrap(d.initializer))) { out.set(d.name.text, unwrap(d.initializer).text); }
      }
    }
    if (ts.isClassDeclaration(n) && n.name) {
      for (const m of n.members) {
        if (ts.isPropertyDeclaration(m) && m.initializer && isStr(unwrap(m.initializer)) &&
          (ts.getCombinedModifierFlags(m) & ts.ModifierFlags.Static)) { out.set(n.name.text + '.' + memberName(m), unwrap(m.initializer).text); }
      }
    }
  });
  return out;
}
function strValue(e, consts) {
  e = unwrap(e);
  if (!e) { return null; }
  if (isStr(e)) { return e.text; }
  if (ts.isIdentifier(e) && consts.has(e.text)) { return consts.get(e.text); }
  if (ts.isPropertyAccessExpression(e) && ts.isIdentifier(e.expression) && consts.has(e.expression.text + '.' + e.name.text)) {
    return consts.get(e.expression.text + '.' + e.name.text);
  }
  return null;
}
function findStruct(sf, name) {
  let hit = null;
  ts.forEachChild(sf, (n) => { if (ts.isStructDeclaration(n) && n.name && n.name.text === name) { hit = n; } });
  if (!hit) { throw new Incomplete(path.relative(ROOT, sf.fileName) + '：找不到 struct ' + name); }
  return hit;
}
const BUILDER_DECORATORS = new Set(['Builder', 'LocalBuilder', 'Styles', 'Extend', 'AnimatableExtend']);
function isBuilderMember(m) {
  return memberName(m) === 'build' || decoratorsOf(m).some((d) => BUILDER_DECORATORS.has(decoratorName(d)));
}
function enclosingMember(node, struct) {
  let n = node;
  while (n && n.parent !== struct) { n = n.parent; }
  return n || null;
}
/** 组件链：{ stmt, root, calls, member }（只收 struct 里的组件语句）。 */
function components(struct) {
  const out = [];
  walk(struct, (n) => {
    if (!ts.isExpressionStatement(n)) { return; }
    const ch = chainOf(n.expression);
    if (ch.root && (ts.isEtsComponentExpression(ch.root) ||
      (ts.isCallExpression(ch.root) && ts.isIdentifier(ch.root.expression) && /^[A-Z]/.test(ch.root.expression.text)))) {
      out.push({ stmt: n, root: ch.root, calls: ch.calls, member: enclosingMember(n, struct) });
    }
  });
  return out;
}
/** 从 builder（含 build）出发经 this.<builder>() 调用能到的成员名。 */
function builderTree(struct, start) {
  const members = new Map();
  for (const m of struct.members) { if (ts.isMethodDeclaration(m)) { members.set(memberName(m), m); } }
  const seen = new Set();
  const stack = [start];
  while (stack.length) {
    const name = stack.pop();
    if (seen.has(name) || !members.has(name)) { continue; }
    seen.add(name);
    walk(members.get(name), (n) => {
      if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.expression.kind === ts.SyntaxKind.ThisKeyword &&
        members.has(n.expression.name.text) && isBuilderMember(members.get(n.expression.name.text))) { stack.push(n.expression.name.text); }
    });
  }
  return seen;
}
function idOf(comp, consts) {
  const a = comp.root.arguments && comp.root.arguments[0];
  for (const k of ['buttonId', 'chipId']) {
    const v = a ? property(unwrap(a), k) : null;
    if (v) { return strValue(v, consts); }
  }
  const c = comp.calls.filter((x) => x.name === 'id');
  return c.length ? strValue(c[c.length - 1].args[0], consts) : null;
}

// ---------------------------------------------------------------- 编译：struct → 类，抽出回调
/**
 * 把 struct 合成一个类：字段初值放进 __init（逐个 try，判不了的给桩）、普通方法 / 存取器原样（去装饰器），每个要调的回调合成方法
 * __cb_N(<所在 builder 的形参>) { return (<回调表达式>); }——箭头函数的 this 因此就是页面实例。
 */
function synthClass(struct, callbacks) {
  const name = '__Sim_' + struct.name.text;
  const parts = ['class ' + name + ' {'];
  const init = [];
  const monitors = [];
  for (const m of struct.members) {
    if (ts.isPropertyDeclaration(m)) {
      const n = memberName(m);
      if (!n) { continue; }
      if (m.initializer) {
        init.push('    if (!__skip.has(' + JSON.stringify(n) + ')) { try { this[' + JSON.stringify(n) + '] = (' + m.initializer.getText() +
          '); } catch (e) { this[' + JSON.stringify(n) + '] = __stub(' + JSON.stringify(struct.name.text + '.' + n) + '); } }');
      }
    } else if ((ts.isMethodDeclaration(m) && !isBuilderMember(m)) || ts.isGetAccessorDeclaration(m) || ts.isSetAccessorDeclaration(m)) {
      for (const d of decoratorsOf(m)) {
        if (decoratorName(d) === 'Monitor' && ts.isCallExpression(d.expression)) {
          monitors.push({ method: memberName(m), paths: d.expression.arguments.filter(isStr).map((a) => a.text) });
        }
      }
      parts.push('  ' + textWithoutDecorators(m));
    }
  }
  parts.push('  __init(__skip) {\n' + init.join('\n') + '\n  }');
  callbacks.forEach((cb, i) => {
    const owner = cb.member && ts.isMethodDeclaration(cb.member) ? cb.member : null;
    const params = owner ? owner.parameters.map((p) => p.getText()).join(', ') : '';
    parts.push('  __cb_' + i + '(' + params + ') {\n    return (' + cb.expr.getText() + ');\n  }');
    cb.method = '__cb_' + i;
    cb.params = owner ? owner.parameters.map((p) => (p.type ? p.type.getText() : '')) : [];
  });
  parts.push('}');
  return { name: name, text: parts.join('\n'), monitors: monitors };
}

/** 模块源码：顶层语句去掉 struct 与 @Builder / @Styles / @Extend 函数（ArkUI 语法，不执行），再接上合成的类。 */
function moduleSource(sf, extra) {
  const keep = [];
  for (const s of sf.statements) {
    if (ts.isStructDeclaration(s)) { continue; }
    if (ts.isFunctionDeclaration(s) && decoratorsOf(s).some((d) => BUILDER_DECORATORS.has(decoratorName(d)))) { continue; }
    if (/^@(Builder|Styles|Extend|AnimatableExtend|LocalBuilder)\b/.test(s.getText())) { continue; }
    keep.push(s.getText());
  }
  return keep.join('\n') + (extra ? '\n' + extra : '');
}
const compiled = new Map();
function transpile(key, source) {
  if (compiled.has(key)) { return compiled.get(key); }
  const out = ts.transpileModule(source, { fileName: key.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true } }).outputText
    .replace(/^"use strict";\s*/, '');
  // 本模块自己声明的名字（with 作用域不得遮住它们）。
  const declared = new Set(['require', 'module', 'exports', '__scope', 'arguments']);
  const jsf = ts.createSourceFile('x.js', out, ts.ScriptTarget.ES2020, true, ts.ScriptKind.JS);
  walk(jsf, (n) => {
    if ((ts.isVariableDeclaration(n) || ts.isFunctionDeclaration(n) || ts.isClassDeclaration(n) || ts.isParameter(n) ||
      ts.isBindingElement(n) || ts.isFunctionExpression(n) || ts.isClassExpression(n)) && n.name && ts.isIdentifier(n.name)) { declared.add(n.name.text); }
  });
  const r = { js: out, declared: declared };
  compiled.set(key, r);
  return r;
}

// ---------------------------------------------------------------- 世界：可控时钟、记录器、桩
const DECORATORS = ['ObservedV2', 'Trace', 'Observed', 'Track', 'Local', 'Param', 'Once', 'Event', 'Provider', 'Consumer', 'Computed',
  'Builder', 'BuilderParam', 'LocalBuilder', 'Component', 'ComponentV2', 'Entry', 'Concurrent', 'Sendable', 'Require', 'State', 'Prop',
  'Link', 'Provide', 'Consume', 'Watch', 'StorageLink', 'StorageProp', 'LocalStorageLink', 'LocalStorageProp', 'ObjectLink', 'Styles',
  'Extend', 'AnimatableExtend', 'Reusable', 'ReusableV2', 'CustomDialog', 'Preview', 'Env', 'Type', 'Monitor', 'Track'];

function makeWorld() {
  const w = { now: 0, timerSeq: 0, timers: new Map(), a11y: [], kbd: [], errors: [], step: 0, present: new Set(), stubs: 0 };
  // 什么都接受的桩：取任何属性 / 调用 / new 都得到桩；转原始值为空串；不是 thenable。
  function stub(label) {
    w.stubs++;
    const target = function () {};
    return new Proxy(target, {
      get: (_t, k) => {
        if (k === Symbol.toPrimitive) { return () => ''; }
        if (k === 'then' || k === Symbol.iterator || k === Symbol.asyncIterator) { return undefined; }
        if (k === 'toString' || k === 'valueOf') { return () => ''; }
        if (k === 'length') { return 0; }
        if (k === '__isSimStub') { return true; }
        if (typeof k === 'symbol') { return undefined; }
        return stub(label + '.' + String(k));
      },
      set: () => true,
      apply: () => stub(label + '()'),
      construct: () => stub('new ' + label),
      has: () => true,
    });
  }
  w.stub = stub;
  function addTimer(fn, ms, args, every) {
    const id = ++w.timerSeq;
    const d = Math.max(0, Number(ms) || 0);
    w.timers.set(id, { id: id, at: w.now + d, fn: fn, args: args || [], every: every ? Math.max(1, d) : 0 });
    return id;
  }
  w.setTimeout = (fn, ms, ...args) => (typeof fn === 'function' ? addTimer(fn, ms, args, false) : 0);
  w.setInterval = (fn, ms, ...args) => (typeof fn === 'function' ? addTimer(fn, ms, args, true) : 0);
  w.clearTimeout = (id) => { w.timers.delete(id); };
  w.clearInterval = w.clearTimeout;
  w.requestAnimationFrame = (fn) => addTimer(() => fn(w.now), 16, [], false);
  w.cancelAnimationFrame = w.clearTimeout;
  w.guard = (what, fn) => {
    try { return fn(); } catch (e) { w.errors.push(what + ' 抛异常：' + (e && e.stack ? String(e.stack).split('\n').slice(0, 3).join(' | ') : e)); return undefined; }
  };
  w.flush = async () => { for (let i = 0; i < 4; i++) { await new Promise((r) => setImmediate(r)); } };
  /** 时钟走到 t，按到期先后执行排队的回调（同时到期按排队先后）。 */
  w.runTo = async (t) => {
    let guardN = 0;
    for (;;) {
      let next = null;
      for (const x of w.timers.values()) { if (x.at <= t && (next === null || x.at < next.at || (x.at === next.at && x.id < next.id))) { next = x; } }
      if (next === null || ++guardN > 5000) { break; }
      w.now = next.at;
      if (next.every) { next.at += next.every; } else { w.timers.delete(next.id); }
      w.guard('定时回调', () => next.fn(...next.args));
      await w.flush();
    }
    w.now = Math.max(w.now, t);
    await w.flush();
  };
  // @kit.AccessibilityKit 记录器：requestFocusForAccessibility 事件 = 一次读屏移焦（customId = 目标组件 id）。
  class EventInfo {
    constructor(a, b, c) {
      if (a && typeof a === 'object') { Object.assign(this, a); } else { this.type = a; this.bundleName = b; this.triggerAction = c; }
    }
  }
  const send = (ev, cb) => {
    if (ev && ev.type === 'requestFocusForAccessibility') {
      w.a11y.push({ t: w.now, step: w.step, id: String(ev.customId), present: w.present.has(String(ev.customId)) });
    }
    if (typeof cb === 'function') { cb(undefined); return undefined; }
    return Promise.resolve();
  };
  const accessibility = { EventInfo: EventInfo, sendAccessibilityEvent: send, sendAccessibilityEventSync: send,
    isOpenAccessibilitySync: () => true, isOpenAccessibility: () => Promise.resolve(true), isScreenReaderOpenSync: () => true,
    isOpenTouchGuideSync: () => true, on: () => undefined, off: () => undefined };
  w.kits = { '@kit.AccessibilityKit': withStub({ accessibility: withStub(accessibility, 'accessibility') }, '@kit.AccessibilityKit'),
    '@ohos.accessibility': withStub(Object.assign({ default: withStub(accessibility, 'accessibility') }, accessibility), '@ohos.accessibility') };
  function withStub(obj, label) {
    return new Proxy(obj, { get: (t, k) => (k in t ? t[k] : (typeof k === 'symbol' || k === 'then' ? undefined : stub(label + '.' + String(k)))) });
  }
  w.withStub = withStub;
  const frameNode = (id) => (w.present.has(id) ? stub('FrameNode#' + id) : null);
  const focusController = withStub({
    requestFocus: (id) => { w.kbd.push({ t: w.now, step: w.step, id: String(id) }); if (!w.present.has(String(id))) { throw new Error('150001 not found ' + id); } },
    clearFocus: () => undefined, activate: () => undefined, setAutoFocusTransfer: () => undefined,
  }, 'FocusController');
  w.ui = withStub({
    getFocusController: () => focusController,
    getHostContext: () => ({ applicationInfo: { name: 'com.couli.sim' } }),
    getFrameNodeById: frameNode, getAttachedFrameNodeById: frameNode,
    postFrameCallback: (cb) => { addTimer(() => { if (cb && typeof cb.onFrame === 'function') { cb.onFrame(w.now * 1e6); } }, 16, [], false); },
    postDelayedFrameCallback: (cb, ms) => { addTimer(() => { if (cb && typeof cb.onFrame === 'function') { cb.onFrame(w.now * 1e6); } }, 16 + (Number(ms) || 0), [], false); },
    runScopedTask: (fn) => fn(),
    px2vp: (x) => x, vp2px: (x) => x,
  }, 'UIContext');
  w.getInspectorByKey = (id) => (w.present.has(String(id)) ? '{"$type":"Sim"}' : '');
  return w;
}

// ---------------------------------------------------------------- 模块加载（每个场景一个新世界、新的 vm 上下文，模块实例不共享）
function makeLoader(w) {
  const sandbox = { console: console, setTimeout: w.setTimeout, clearTimeout: w.clearTimeout, setInterval: w.setInterval,
    clearInterval: w.clearInterval, requestAnimationFrame: w.requestAnimationFrame, cancelAnimationFrame: w.cancelAnimationFrame,
    getInspectorByKey: w.getInspectorByKey, __stub: w.stub };
  for (const d of DECORATORS) { sandbox[d] = () => undefined; }
  const context = vm.createContext(sandbox);
  const builtins = new Set(vm.runInContext('Object.getOwnPropertyNames(globalThis)', context));
  const cache = new Map();
  /** 未声明的名字（ArkUI 全局：Color、Alignment、$r、AppStorage、animateTo…）一律给桩。 */
  function scopeFor(declared) {
    const store = new Map();
    return new Proxy({}, {
      has: (_t, k) => typeof k === 'string' && !declared.has(k) && !builtins.has(k) && !(k in sandbox),
      get: (_t, k) => {
        if (k === Symbol.unscopables || typeof k === 'symbol') { return undefined; }
        if (!store.has(k)) { store.set(k, w.stub(String(k))); }
        return store.get(k);
      },
      set: (_t, k, v) => { store.set(k, v); return true; },
    });
  }
  function run(key, source, requireFn, module) {
    const c = transpile(key, source);
    const fn = vm.runInContext('(function (require, module, exports, __scope) { with (__scope) {\n' + c.js + '\n} })', context, { filename: key });
    fn(requireFn, module, module.exports, scopeFor(c.declared));
    return module.exports;
  }
  /** 真实加载一个 .ets 文件（struct / @Builder 去掉）；失败抛出。 */
  function loadFile(abs, extra) {
    const k = abs + (extra ? '#sim' : '');
    if (cache.has(k)) { return cache.get(k).exports; }
    const sf = parseFile(abs);
    const module = { exports: {} };
    cache.set(k, module);
    try {
      run(k, moduleSource(sf, extra ? extra.text : ''), (name) => resolve(abs, name), module);
    } catch (e) {
      cache.delete(k);
      throw e;
    }
    return module.exports;
  }
  /** 相对 import：首次取属性时才加载；加载失败（不是本场景要的文件）退成桩。 */
  function lazyFile(abs) {
    let real;
    let failed = false;
    const get = () => {
      if (real === undefined && !failed) {
        try { real = loadFile(abs); } catch (e) { failed = true; }
      }
      return failed ? null : real;
    };
    return new Proxy({}, {
      get: (_t, k) => {
        if (k === '__esModule') { return true; }
        const m = get();
        if (m && k in m) { return m[k]; }
        return typeof k === 'symbol' ? undefined : w.stub(path.basename(abs) + '.' + String(k));
      },
    });
  }
  /** designsystem 包：按 Index.ets 的 export { … } from '…' 找到每个名字的源文件。 */
  let dsMap = null;
  function designsystem() {
    if (dsMap === null) {
      dsMap = new Map();
      const abs = path.join(ROOT, DS_INDEX);
      const sf = parseFile(abs);
      for (const s of sf.statements) {
        if (ts.isExportDeclaration(s) && s.moduleSpecifier && isStr(s.moduleSpecifier) && s.exportClause && ts.isNamedExports(s.exportClause)) {
          const target = path.resolve(path.dirname(abs), s.moduleSpecifier.text);
          for (const el of s.exportClause.elements) {
            dsMap.set(el.name.text, { file: target.endsWith('.ets') ? target : target + '.ets', name: (el.propertyName || el.name).text });
          }
        }
      }
    }
    return new Proxy({}, {
      get: (_t, k) => {
        if (k === '__esModule') { return true; }
        if (typeof k === 'symbol') { return undefined; }
        const hit = dsMap.get(k);
        if (hit && k === 'CouliFocusReturn') {
          // 移焦本体必须真实加载：加载失败 = 判不了。
          const m = loadFile(hit.file);
          if (!m[hit.name]) { throw new Incomplete(path.relative(ROOT, hit.file) + ' 没有导出 ' + hit.name); }
          return m[hit.name];
        }
        if (hit) {
          try { const m = loadFile(hit.file); if (m[hit.name] !== undefined) { return m[hit.name]; } } catch (e) { /* 退成桩 */ }
        }
        return w.stub('designsystem.' + String(k));
      },
    });
  }
  function resolve(from, name) {
    if (w.kits[name]) { return w.kits[name]; }
    if (name === 'designsystem') { return designsystem(); }
    if (name.startsWith('.')) {
      const target = path.resolve(path.dirname(from), name);
      return lazyFile(target.endsWith('.ets') ? target : target + '.ets');
    }
    // core、@kit.* 其余、别的包：桩（本模拟只关心移焦本体）。
    return w.withStub({ __esModule: true }, name);
  }
  return { loadFile: loadFile, designsystem: designsystem, context: context };
}

// ---------------------------------------------------------------- 页面实例
const APPEAR = ['onAttach', 'onAppear'];
const DISAPPEAR = ['onDisAppear', 'onDisappear', 'onDetach'];

function instantiate(w, loader, file, spec, params) {
  const mod = loader.loadFile(path.join(ROOT, file), spec);
  const Cls = mod.__simClasses && mod.__simClasses[spec.structName];
  if (!Cls) { throw new Incomplete(file + '：合成 ' + spec.structName + ' 失败'); }
  const raw = new Cls();
  raw.getUIContext = () => w.ui;
  for (const k of Object.keys(params)) { raw[k] = params[k]; }
  const self = new Proxy(raw, {
    get: (t, k) => {
      if (k in t) { return t[k]; }
      if (typeof k === 'symbol' || k === 'then') { return undefined; }
      return w.stub(spec.structName + '.' + String(k));
    },
  });
  w.guard(spec.structName + ' 字段初值', () => raw.__init.call(self, new Set(Object.keys(params))));
  const inst = { self: self, raw: raw, spec: spec, monitorValues: new Map() };
  for (const m of spec.monitors) {
    for (const p of m.paths) { inst.monitorValues.set(m.method + '|' + p, readPath(self, p)); }
  }
  return inst;
}
function readPath(self, p) {
  let v = self;
  for (const k of p.split('.')) { if (v === null || v === undefined) { return v; } v = v[k]; }
  return v;
}
/** @Monitor：监视的路径值变了就调方法（每一步之后查一次）。 */
function settleMonitors(w, inst) {
  for (let round = 0; round < 5; round++) {
    let fired = false;
    for (const m of inst.spec.monitors) {
      for (const p of m.paths) {
        const key = m.method + '|' + p;
        const v = readPath(inst.self, p);
        if (v !== inst.monitorValues.get(key)) {
          inst.monitorValues.set(key, v);
          fired = true;
          w.guard('@Monitor ' + m.method, () => inst.self[m.method](w.stub('IMonitor')));
        }
      }
    }
    if (!fired) { return; }
  }
}
function callbackFn(w, inst, cb, args) {
  const fn = w.guard('取回调 ' + cb.label, () => inst.self[cb.method](...args));
  return typeof fn === 'function' ? fn : null;
}
function fire(w, inst, cbs, names, argsFor, extraArgs) {
  for (const cb of cbs) {
    if (names.indexOf(cb.event) < 0) { continue; }
    const fn = callbackFn(w, inst, cb, argsFor(cb));
    if (fn) { w.guard(cb.label, () => fn(...(extraArgs || []))); }
  }
}

// ---------------------------------------------------------------- 搜索页价格半屏
function searchSpec() {
  const abs = path.join(ROOT, SEARCH);
  const sf = parseFile(abs);
  const consts = moduleConsts(sf);
  const struct = findStruct(sf, 'SearchView');
  const comps = components(struct);
  const callbacks = [];
  // 价格半屏：bindSheet 的内容 builder 树里有 search_price_confirm / search_price_min
  let sheet = null;
  for (const c of comps) {
    for (const call of c.calls.filter((x) => x.name === 'bindSheet')) {
      const b = call.args[1] ? unwrap(call.args[1]) : null;
      if (!b || !ts.isCallExpression(b) || !ts.isPropertyAccessExpression(b.expression)) { continue; }
      const tree = builderTree(struct, b.expression.name.text);
      const inTree = comps.filter((x) => x.member && tree.has(memberName(x.member)));
      const ids = new Set(inTree.map((x) => idOf(x, consts)).filter((x) => x));
      // priceInput 的 id 是形参：按调用点实参补上
      walk(struct, (n) => {
        if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && n.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
          const m = enclosingMember(n, struct);
          if (m && tree.has(memberName(m))) { for (const a of n.arguments) { const v = strValue(a, consts); if (v) { ids.add(v); } } }
        }
      });
      if (ids.has(ID_PRICE_CONFIRM) || ids.has(ID_PRICE_MIN)) { sheet = { comp: c, call: call, tree: tree, inTree: inTree, ids: ids }; }
    }
  }
  if (!sheet) { throw new Incomplete(SEARCH + '：找不到价格半屏（bindSheet 内容里没有 search_price_confirm / search_price_min）'); }
  const opts = sheet.call.args[2] ? unwrap(sheet.call.args[2]) : null;
  if (!opts || !ts.isObjectLiteralExpression(opts)) { throw new Incomplete(SEARCH + '：价格半屏 bindSheet 选项不是对象字面量，模拟不了'); }
  for (const ev of ['onWillAppear', 'onAppear', 'onWillDisappear', 'onDisappear', 'onWillDismiss', 'shouldDismiss']) {
    const v = property(opts, ev);
    if (v) {
      if (ts.isMethodDeclaration(v)) { throw new Incomplete(SEARCH + '：bindSheet 选项 ' + ev + ' 写成方法简写，模拟不了（请写成箭头函数）'); }
      callbacks.push({ kind: 'sheetOpt', event: ev, expr: v, member: sheet.comp.member, label: 'bindSheet.' + ev + '@' + lineOf(v) });
    }
  }
  for (const c of sheet.inTree) {
    for (const call of c.calls) {
      if ((APPEAR.indexOf(call.name) >= 0 || DISAPPEAR.indexOf(call.name) >= 0) && call.args[0]) {
        callbacks.push({ kind: 'sheetComp', event: call.name, expr: call.args[0], member: c.member, label: '半屏组件.' + call.name + '@' + lineOf(call.node) });
      }
    }
  }
  // 【价格】筛选片：组件实参对象里 chipId / buttonId 为 search_filter_price 的 onTap / onClick，或 .id(search_filter_price) 的 .onClick
  let chip = null;
  for (const c of comps) {
    if (idOf(c, consts) !== ID_FILTER_PRICE) { continue; }
    const a = c.root.arguments && c.root.arguments[0] ? unwrap(c.root.arguments[0]) : null;
    const v = a ? (property(a, 'onTap') || property(a, 'onClick')) : null;
    const click = c.calls.filter((x) => x.name === 'onClick');
    const expr = v && !ts.isMethodDeclaration(v) ? v : (click.length ? click[click.length - 1].args[0] : null);
    if (expr) { chip = { kind: 'chip', event: 'tap', expr: expr, member: c.member, label: '【价格】onTap@' + lineOf(expr) }; }
  }
  if (!chip) { throw new Incomplete(SEARCH + '：找不到【价格】筛选片（search_filter_price）的点击回调'); }
  callbacks.push(chip);
  const cls = synthClass(struct, callbacks);
  return { structName: 'SearchView', file: SEARCH, text: cls.text + '\nexports.__simClasses = { SearchView: ' + cls.name + ' };',
    monitors: cls.monitors, callbacks: callbacks, sheetIds: sheet.ids, bindLine: lineOf(sheet.call.node.expression.name) };
}

/** 页面出栈的同步出口（同 core SearchPageLife）。 */
function fakeLife(w) {
  const life = { live: true, exits: [] };
  const api = {
    get alive() { return life.live; },
    onExit: (a) => { if (!life.live) { a(); return; } life.exits.push(a); },
    exit: () => { if (!life.live) { return; } life.live = false; const xs = life.exits; life.exits = []; for (const a of xs) { w.guard('life.onExit 动作', () => a()); } },
  };
  return w.withStub(api, 'SearchPageLife');
}
function fakeConfig(w) {
  const base = {
    life: fakeLife(w), restored: null, initialQuery: null, initialPlatform: null, history: [],
    texts: w.withStub({ text: (k) => String(k), format: (k) => String(k) }, 'texts'),
    controller: w.stub('SearchController'),
    onPersist: () => undefined, onPersistNow: () => undefined,
  };
  return new Proxy(base, {
    get: (t, k) => (k in t ? t[k] : (typeof k === 'symbol' || k === 'then' ? undefined : w.stub('config.' + String(k)))),
    set: (t, k, v) => { t[k] = v; return true; },
  });
}

class SearchWorld {
  constructor(spec) {
    this.w = makeWorld();
    this.loader = makeLoader(this.w);
    this.spec = spec;
    this.config = fakeConfig(this.w);
    this.page = instantiate(this.w, this.loader, SEARCH, spec, { config: this.config });
    this.sheetShown = false;
    this.alive = true;
    for (const id of [ID_FILTER_PRICE, 'search_input', 'search_filter_coupon']) { this.w.present.add(id); }
    const s = this.page.self;
    if (typeof s.aboutToAppear === 'function') { this.w.guard('SearchView.aboutToAppear', () => s.aboutToAppear()); }
    settleMonitors(this.w, this.page);
  }
  cbs(kind) { return this.spec.callbacks.filter((c) => c.kind === kind); }
  args(cb) { return cb.params.map((t) => this.w.stub('arg:' + t)); }
  setSheet(on) { for (const id of this.spec.sheetIds) { if (on) { this.w.present.add(id); } else { this.w.present.delete(id); } } }
  open() {
    this.tap();
    this.appear();
  }
  /** 点【价格】：只执行筛选片的点击（model.sheetOpen 变 true），半屏的出现回调另由 appear() 发（v3：可模拟迟到的出现回调）。 */
  tap() {
    const chip = this.cbs('chip')[0];
    const fn = callbackFn(this.w, this.page, chip, this.args(chip));
    if (fn) { this.w.guard(chip.label, () => fn()); }
    settleMonitors(this.w, this.page);
    const m = this.page.self.model;
    if (!m || m.sheetOpen !== true) { throw new Incomplete(SEARCH + '：模拟点【价格】后 model.sheetOpen 没变成 true，打不开价格半屏'); }
  }
  /** 半屏出现：选项 onWillAppear → 内容组件 onAppear / onAttach → 选项 onAppear。 */
  appear() {
    this.sheetShown = true;
    fire(this.w, this.page, this.cbs('sheetOpt'), ['onWillAppear'], (cb) => this.args(cb));
    this.setSheet(true);
    fire(this.w, this.page, this.cbs('sheetComp'), APPEAR, (cb) => this.args(cb));
    fire(this.w, this.page, this.cbs('sheetOpt'), ['onAppear'], (cb) => this.args(cb));
    settleMonitors(this.w, this.page);
  }
  /** 用户收起（下滑 / 返回）：onWillDismiss / shouldDismiss 放行后依次 onWillDisappear、内容 onDisAppear、onDisappear。 */
  close(byUser) {
    if (!this.sheetShown) { throw new Incomplete('模拟顺序错：半屏没开就关'); }
    if (byUser) {
      for (const ev of ['onWillDismiss', 'shouldDismiss']) {
        const cb = this.cbs('sheetOpt').find((c) => c.event === ev);
        if (!cb) { continue; }
        let ok = false;
        const fn = callbackFn(this.w, this.page, cb, this.args(cb));
        if (fn) { this.w.guard(cb.label, () => fn({ dismiss: () => { ok = true; }, reason: 1 })); }
        if (!ok) { throw new Incomplete(SEARCH + '：' + ev + ' 没放行用户收起，模拟不了关闭'); }
      }
    }
    this.sheetShown = false;
    fire(this.w, this.page, this.cbs('sheetOpt'), ['onWillDisappear'], (cb) => this.args(cb));
    this.setSheet(false);
    fire(this.w, this.page, this.cbs('sheetComp'), DISAPPEAR, (cb) => this.args(cb));
    fire(this.w, this.page, this.cbs('sheetOpt'), ['onDisappear'], (cb) => this.args(cb));
    settleMonitors(this.w, this.page);
  }
  /** 出栈：entry onWillDisappear → life.exit()；半屏还开着则随页面收起；再 aboutToDisappear。页面上的 id 全部不在了。 */
  leave() {
    this.config.life.exit();
    settleMonitors(this.w, this.page);
    if (this.sheetShown) { this.close(false); }
    const s = this.page.self;
    this.alive = false;
    this.w.present.clear();
    if (typeof s.aboutToDisappear === 'function') { this.w.guard('SearchView.aboutToDisappear', () => s.aboutToDisappear()); }
    settleMonitors(this.w, this.page);
  }
  /** 被详情盖住（entry 调 config.onCovered(true)）。 */
  cover(on) {
    const covered = on !== false;
    const f = this.config.onCovered;
    if (typeof f !== 'function' || f.__isSimStub) { throw new Incomplete(SEARCH + '：aboutToAppear 没注册 config.onCovered，模拟不了被盖住'); }
    this.w.guard('config.onCovered(' + covered + ')', () => f(covered));
    settleMonitors(this.w, this.page);
  }
  /** 从详情返回、页面重新露出（entry 调 config.onCovered(false)）。 */
  uncover() { this.cover(false); }
}

// ---------------------------------------------------------------- 首页弹窗
function popupSpec() {
  const abs = path.join(ROOT, HOME);
  const sf = parseFile(abs);
  const consts = moduleConsts(sf);
  const struct = findStruct(sf, 'HomePopupView');
  const tree = builderTree(struct, 'build');
  const comps = components(struct).filter((c) => c.member && tree.has(memberName(c.member)));
  const callbacks = [];
  const ids = new Set();
  for (const c of comps) {
    const id = idOf(c, consts);
    if (id) { ids.add(id); }
    for (const call of c.calls) {
      if ((APPEAR.indexOf(call.name) >= 0 || DISAPPEAR.indexOf(call.name) >= 0) && call.args[0]) {
        callbacks.push({ kind: 'popupComp', event: call.name, expr: call.args[0], member: c.member, label: '弹窗组件.' + call.name + '@' + lineOf(call.node) });
      }
    }
  }
  if (!ids.has(ID_POPUP_CLOSE)) { throw new Incomplete(HOME + '：HomePopupView 里找不到 home_popup_close'); }
  const cls = synthClass(struct, callbacks);
  return { structName: 'HomePopupView', file: HOME, text: cls.text + '\nexports.__simClasses = { HomePopupView: ' + cls.name + ' };',
    monitors: cls.monitors, callbacks: callbacks, ids: ids, returnId: consts.get('HomePopupFocus.RETURN_ID') || 'home_search_entry',
    line: lineOf(struct.name) };
}

class PopupWorld {
  constructor(spec) {
    this.w = makeWorld();
    this.loader = makeLoader(this.w);
    this.spec = spec;
    this.ticket = this.w.withStub({ key: 'sim-popup-1', image: 'sim://popup.png', adLabel: null, tap: null }, 'HomePopupTicket');
    this.w.present.add(spec.returnId);
    this.view = instantiate(this.w, this.loader, HOME, spec, { ticket: this.ticket, port: this.w.stub('HomeScreenPort') });
  }
  args(cb) { return cb.params.map((t) => (/HomePopupTicket/.test(t) ? this.ticket : this.w.stub('arg:' + t))); }
  show() {
    const s = this.view.self;
    if (typeof s.aboutToAppear === 'function') { this.w.guard('HomePopupView.aboutToAppear', () => s.aboutToAppear()); }
    for (const id of this.spec.ids) { this.w.present.add(id); }
    fire(this.w, this.view, this.spec.callbacks, APPEAR, (cb) => this.args(cb));
    settleMonitors(this.w, this.view);
  }
  /** 对话框收起（关闭键 / 返回 / 点遮罩 / 点图片跳转都一样：内容组件 onDisAppear、HomePopupView aboutToDisappear）；不是跳转时 HomeTabRoot 120 ms 后回焦首页搜索入口。 */
  dismiss(navigated) {
    for (const id of this.spec.ids) { this.w.present.delete(id); }
    fire(this.w, this.view, this.spec.callbacks, DISAPPEAR, (cb) => this.args(cb));
    const s = this.view.self;
    if (typeof s.aboutToDisappear === 'function') { this.w.guard('HomePopupView.aboutToDisappear', () => s.aboutToDisappear()); }
    settleMonitors(this.w, this.view);
    if (!navigated) {
      const CFR = this.loader.designsystem().CouliFocusReturn;
      const ui = this.w.ui;
      const id = this.spec.returnId;
      this.w.setTimeout(() => CFR.to(ui, id), 120);
    }
    if (navigated) { this.w.present.clear(); }
  }
}

// ---------------------------------------------------------------- 场景与判定
/**
 * 每个场景：一串 [时刻, 动作, 这一步之后允许的读屏移焦目标]。判定：
 *   stale     每次读屏移焦归到发出时最近的一步（含该步动作执行中），目标不在该步允许的集合里 → 过期请求（上一步排队的旧请求没作废）；
 *   expect    场景末尾要求至少一次读屏移焦到某目标，且发生在指定动作之后（正常路径仍要移焦，防「全删掉」也算过）。
 */
async function runScenario(sc, makeWorldFn) {
  let world;
  try { world = makeWorldFn(); } catch (e) { if (e instanceof Incomplete) { throw e; } throw new Incomplete(sc.name + ' 建模失败：' + e.message); }
  const w = world.w;
  const marks = [];
  for (const s of sc.steps) {
    await w.runTo(s.at);
    w.step = marks.length + 1;
    marks.push({ at: s.at, label: s.label, allowed: s.allowed, step: w.step });
    s.act(world);
  }
  await w.runTo(w.now + SETTLE);
  if (w.errors.length) { throw new Incomplete(sc.name + '：模拟执行出错（' + w.errors.slice(0, 3).join('；') + '）'); }
  const problems = [];
  for (const m of marks) {
    // 每次读屏移焦归到它发出时最近的那一步：那一步之后（到下一步之前）只允许这一步的目标。
    const late = w.a11y.filter((e) => e.step === m.step && m.allowed.indexOf(e.id) < 0);
    if (late.length) {
      problems.push('「' + m.label + '」之后仍发出读屏移焦 ' + late.map((e) => e.id + '@' + e.t + 'ms').join(', ') +
        (m.allowed.length ? '（只允许 ' + m.allowed.join(' / ') + '）' : '（应全部作废）'));
    }
  }
  for (const [id, after] of (sc.expect || [])) {
    const step = marks[after].step;
    if (!w.a11y.some((e) => e.id === id && e.step >= step)) {
      problems.push('「' + marks[after].label + '」之后没有读屏移焦到 ' + id + '（正常路径的移焦不能一起丢掉）');
    }
  }
  const trace = w.a11y.map((e) => e.id + '@' + e.t).join(' ');
  log.push(sc.rule + ' ' + (problems.length ? '红' : '绿') + '：' + sc.name + '；读屏移焦序列 [' + trace + ']');
  return problems;
}

async function main() {
  const scenarios = [];
  let sspec = null;
  let pspec = null;
  try { sspec = searchSpec(); } catch (e) { if (e instanceof Incomplete) { incomplete.push(e.message); } else { throw e; } }
  try { pspec = popupSpec(); } catch (e) { if (e instanceof Incomplete) { incomplete.push(e.message); } else { throw e; } }
  const OPEN = (x) => x.open();
  const CLOSE = (x) => x.close(true);
  /** 半屏随页面被盖住由系统收起（不是用户下滑，不经 onWillDismiss / shouldDismiss）。 */
  const CLOSE_SYS = (x) => x.close(false);
  const COVER = (x) => x.cover();
  const UNCOVER = (x) => x.uncover();
  const TAP = (x) => x.tap();
  const APPEAR = (x) => x.appear();
  const T = ID_PRICE_TITLE;
  const P = ID_FILTER_PRICE;
  if (sspec) {
    const mk = () => new SearchWorld(sspec);
    const def = (rule, name, steps, labels, expect) => scenarios.push({ rule: rule, name: name, file: SEARCH, line: sspec.bindLine, make: mk,
      steps: steps.map((s, i) => ({ at: s[0], act: s[1], allowed: s[2], label: labels[i] })), expect: expect });
    def('AH5-sheet-open', '打开价格半屏：读屏焦点进标题', [[0, OPEN, [T]]], ['打开'], [[T, 0]]);
    def('AH5-sheet-close', '打开 1 s 后关闭：读屏焦点回【价格】、不再进标题', [[0, OPEN, [T]], [1000, CLOSE, [P]]], ['打开', '关闭'], [[P, 1]]);
    def('AH5-sheet-fastclose', '打开后 ' + GAP + ' ms 就关闭：标题的旧请求作废，【价格】仍收到', [[0, OPEN, [T]], [GAP, CLOSE, [P]]],
      ['打开', '快速关闭'], [[P, 1]]);
    def('AH5-sheet-reopen', '关闭后 ' + GAP + ' ms 重开：回【价格】的旧请求作废，标题收到', [[0, OPEN, [T]], [1000, CLOSE, [P]], [1000 + GAP, OPEN, [T]]],
      ['打开', '关闭', '快速重开'], [[T, 2]]);
    def('AH5-sheet-flurry', '快速连开连关（间隔 ' + GAP + ' ms）：最后一次关闭后只回【价格】', [[0, OPEN, [T]], [GAP, CLOSE, [P]], [2 * GAP, OPEN, [T]],
      [3 * GAP, CLOSE, [P]]], ['打开', '关闭', '重开', '再关闭'], [[P, 3]]);
    def('AH5-sheet-leave', '关闭后 ' + GAP + ' ms 离页（出栈）：离页后不再有读屏移焦', [[0, OPEN, [T]], [1000, CLOSE, [P]], [1000 + GAP, (x) => x.leave(), []]],
      ['打开', '关闭', '离页'], []);
    def('AH5-sheet-leave-open', '打开后 ' + GAP + ' ms 离页（半屏随页面收起）：离页后不再有读屏移焦', [[0, OPEN, [T]], [GAP, (x) => x.leave(), []]],
      ['打开', '离页'], []);
    def('AH5-sheet-cover', '关闭后 ' + GAP + ' ms 被详情盖住：盖住后不再有读屏移焦', [[0, OPEN, [T]], [1000, CLOSE, [P]], [1000 + GAP, (x) => x.cover(), []]],
      ['打开', '关闭', '被盖住'], []);
    // v3（Codex r2 S2）：被详情盖住算离页，盖住之后旧 / 新的读屏移焦请求都不得发出；解除覆盖后正常开关仍要移焦。
    def('AH5-sheet-cover-open', '打开后 ' + GAP + ' ms 被详情盖住、再 ' + GAP + ' ms 半屏收起：盖住后不再有读屏移焦（收起不得新排回【价格】）',
      [[0, OPEN, [T]], [GAP, COVER, []], [2 * GAP, CLOSE_SYS, []]], ['打开', '被盖住', '盖住时半屏收起'], []);
    def('AH5-sheet-uncover', '开着被盖住、收起，返回解除覆盖后再正常开关：盖住期间不移焦，恢复后打开进标题、关闭回【价格】',
      [[0, OPEN, [T]], [1000, COVER, []], [1000 + GAP, CLOSE_SYS, []], [2000, UNCOVER, [P]], [3000, OPEN, [T]], [4000, CLOSE, [P]]],
      ['打开', '被盖住', '盖住时半屏收起', '解除覆盖', '恢复后打开', '恢复后关闭'], [[T, 4], [P, 5]]);
    def('AH5-sheet-uncover-open', '开着被盖住、半屏没收起，解除覆盖后再关闭：读屏焦点回【价格】',
      [[0, OPEN, [T]], [1000, COVER, []], [2000, UNCOVER, [T]], [3000, CLOSE, [P]]],
      ['打开', '被盖住', '解除覆盖', '恢复后关闭'], [[P, 3]]);
    def('AH5-sheet-late-appear-cover', '点【价格】后 ' + GAP + ' ms 被盖住、半屏出现回调迟到：标题移焦不得排队',
      [[0, TAP, [T]], [GAP, COVER, []], [2 * GAP, APPEAR, []]], ['点【价格】', '被盖住', '迟到的半屏出现'], []);
    def('AH5-sheet-late-appear-leave', '点【价格】后 ' + GAP + ' ms 离页、半屏出现回调迟到：标题移焦不得排队',
      [[0, TAP, [T]], [GAP, (x) => x.leave(), []], [2 * GAP, APPEAR, []]], ['点【价格】', '离页', '迟到的半屏出现'], []);
  }
  if (pspec) {
    const mk = () => new PopupWorld(pspec);
    const C = ID_POPUP_CLOSE;
    const def = (rule, name, steps, labels, expect) => scenarios.push({ rule: rule, name: name, file: HOME, line: pspec.line, make: mk,
      steps: steps.map((s, i) => ({ at: s[0], act: s[1], allowed: s[2], label: labels[i] })), expect: expect });
    def('AH5-popup-shown', '首页弹窗出现：读屏焦点到【关闭】', [[0, (x) => x.show(), [C]]], ['出现'], [[C, 0]]);
    def('AH5-popup-close', '弹窗出现后 ' + GAP + ' ms 关闭：移到【关闭】的旧请求作废（只允许回首页搜索入口）',
      [[0, (x) => x.show(), [C]], [GAP, (x) => x.dismiss(false), [pspec.returnId]]], ['出现', '关闭'], [[pspec.returnId, 1]]);
    def('AH5-popup-nav', '弹窗出现后 ' + GAP + ' ms 点图片跳转：之后不再有读屏移焦', [[0, (x) => x.show(), [C]], [GAP, (x) => x.dismiss(true), []]],
      ['出现', '跳转'], []);
  }
  for (const sc of scenarios) {
    try {
      const problems = await runScenario(sc, sc.make);
      for (const p of problems) { violations.push({ rule: sc.rule, file: sc.file, line: sc.line, msg: sc.name + '——' + p }); }
    } catch (e) {
      if (e instanceof Incomplete) { incomplete.push(sc.rule + ' ' + e.message); } else { incomplete.push(sc.rule + ' 模拟器内部错误：' + (e && e.stack ? e.stack : e)); }
    }
  }
  process.stdout.write(JSON.stringify({ violations: violations, incomplete: incomplete, log: log }));
}

main().catch((e) => { process.stdout.write(JSON.stringify({ violations: [], incomplete: ['focus_sim 内部错误：' + (e && e.stack ? e.stack : e)], log: log })); });
