#!/usr/bin/env node
// FU-HM-FEEL-KIT-harmony 测试作者 v3（评审 r1 S2-4）：真执行 staging BuildVariant.environmentSettled 可达的静态方法 + 真实 CatalogLaunch.ets，接假 setTimeout，
// 记录每个场景的推目录次数与调度次数；规则判定在 check_feel_kit.py check_cold_retry。
// stdin：{ catalogLaunch: 源码, methods: {名: {body, params}}, properties: {名: {init}}, consts: {名: {init}} }；
// stdout：{ incomplete } 或 { results: [{ name, pushes, timers, firstTimers, drained, minDelay, error? }] }。
// 只切字面量初值的静态字段与常量，其余标识符接假对象。方法名含 push / open / navigate / replace 且实参带目录路由才算推了目录。不冒充设备执行。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
    'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

const ROUTE = 'CouliComponentCatalog';
const PRIVACY = { CONSENTED: 'consented', BASIC_MODE: 'basic_mode', NOT_DECIDED: 'not_decided' };
const LITERAL = /^(-?\d+(\.\d+)?|true|false|'[^']*'|"[^"]*")$/;
const DRAIN_CAP = 5000;
const input = JSON.parse(fs.readFileSync(0, 'utf8'));

function transpile(source, module) {
  return ts.transpileModule(source, { fileName: 'slice.ts', compilerOptions: { module, target: ts.ScriptTarget.ES2020 } }).outputText;
}

function reachable() {
  const seen = new Set();
  const queue = ['environmentSettled'];
  while (queue.length) {
    const name = queue.pop();
    if (seen.has(name) || !input.methods[name]) continue;
    seen.add(name);
    for (const match of input.methods[name].body.matchAll(/\b(?:BuildVariant|this)\.(\w+)/g)) queue.push(match[1]);
  }
  return [...seen];
}

const carriesRoute = args => args.some(a => a === ROUTE || (a && a.__catalogRoute === true));

function makeProxy(state, overrides) {
  const make = (trail, name) => new Proxy(function () {}, {
    get(_target, key) {
      if (typeof key === 'symbol' || key === 'then') return undefined;
      if (key === '__catalogRoute') return undefined;
      const next = trail ? trail + '.' + key : key;
      return Object.prototype.hasOwnProperty.call(overrides, next) ? overrides[next] : make(next, key);
    },
    apply(_target, _self, args) {
      if (carriesRoute(args)) {
        if (/push|open|navigate|replace/i.test(name)) state.pushes++;
        else return { __catalogRoute: true };
      }
      return make(trail + '()', name);
    },
    construct(_target, args) { return carriesRoute(args) ? { __catalogRoute: true } : make(trail + '#new', name); },
  });
  return make('', '');
}

function loadCatalogLaunch() {
  const module = { exports: {} };
  const require_ = name => {
    if (name === './CatalogManifest') return { catalogComponent: n => (n === 'FeelLab' ? {} : undefined) };
    throw new Error('CatalogLaunch 不应依赖 ' + name);
  };
  new vm.Script('(function(require,module,exports){\n' + transpile(input.catalogLaunch, ts.ModuleKind.CommonJS) + '\n})')
    .runInThisContext()(require_, module, module.exports);
  return module.exports.CatalogLaunch;
}

const names = reachable();
if (!names.includes('environmentSettled')) {
  process.stdout.write(JSON.stringify({ incomplete: '找不到 environmentSettled' }));
  process.exit(0);
}
const members = names.map(n => n + '(' + (input.methods[n].params || []).map(p => p.name).join(', ') + ') ' + input.methods[n].body);
const fields = Object.entries(input.properties).filter(([, p]) => p.init && LITERAL.test(p.init)).map(([n, p]) => n + ': ' + p.init);
const constants = Object.entries(input.consts).filter(([, c]) => c.init && LITERAL.test(c.init)).map(([n, c]) => 'known[' + JSON.stringify(n) + '] = ' + c.init + ';');
let factory;
try {
  const body = transpile('function slice() { return { fields: {' + fields.join(', ') + '}, methods: {' + members.join(',\n') + '} }; }', ts.ModuleKind.None);
  factory = new vm.Script('(function(scope, known){' + constants.join('\n') + '\nwith(scope){\n' + body + '\nreturn slice;}})').runInThisContext();
} catch (e) {
  process.stdout.write(JSON.stringify({ incomplete: String(e && e.message) }));
  process.exit(0);
}

function environment(options) {
  const state = { pushes: 0, timers: [], timerCount: 0, delays: [] };
  const routing = { privacy: options.privacy, ready: options.ready };
  const CatalogLaunch = loadCatalogLaunch();
  const fallback = makeProxy(state, {});
  const appRouting = makeProxy(state, {});
  const shared = new Proxy({}, {
    get(_t, key) {
      if (key === 'privacyState') return routing.privacy;
      if (key === 'presentationReady') return routing.ready;
      return appRouting[key];
    },
  });
  const known = {
    CATALOG_ROUTE: ROUTE,
    PrivacyState: PRIVACY,
    CatalogLaunch,
    AppRouting: { shared },
    setTimeout: (fn, ms) => { state.timers.push(fn); state.timerCount++; state.delays.push(ms === undefined ? 0 : ms); return state.timerCount; },
  };
  const scope = new Proxy(known, {
    has: (target, key) => typeof key === 'string' && (key in target || !(key in globalThis)),
    get: (target, key) => (key === Symbol.unscopables ? undefined : (key in target ? target[key] : fallback[key])),
    set: (target, key, value) => { target[key] = value; return true; },
  });
  const slice = factory(scope, known)();
  const own = Object.assign({}, slice.fields, slice.methods);
  known.BuildVariant = new Proxy(own, {
    get: (target, key) => (key in target ? target[key] : fallback[key]),
    set: (target, key, value) => { target[key] = value; return true; },
  });
  const launch = CatalogLaunch.shared;
  if (options.pending !== false) launch.request('FeelLab');
  return {
    settled: () => known.BuildVariant.environmentSettled(),
    routing, launch, state,
    tick: () => { const fn = state.timers.shift(); if (fn) fn(); },
    drain: () => { let n = 0; while (state.timers.length && n < DRAIN_CAP) { state.timers.shift()(); n++; } return state.timers.length === 0; },
  };
}

const scenarios = {
  not_decided_not_ready(env) { env.settled(); env.routing.privacy = PRIVACY.CONSENTED; env.routing.ready = true; return env.drain(); },
  not_decided_ready(env) { env.settled(); return env.drain(); },
  later_ready_consented(env, row) { env.settled(); row.firstTimers = env.state.timerCount; env.tick(); env.tick(); env.routing.ready = true; return env.drain(); },
  later_ready_basic_mode(env, row) { env.settled(); row.firstTimers = env.state.timerCount; env.tick(); env.routing.ready = true; return env.drain(); },
  never_ready_is_bounded(env) { env.settled(); return env.drain(); },
  settled_twice_pushes_once(env) { env.settled(); env.settled(); return env.drain(); },
  settled_twice_while_waiting_pushes_once(env) { env.settled(); env.settled(); env.routing.ready = true; return env.drain(); },
  reopens_after_take(env) { env.settled(); env.launch.take(); env.launch.request('FeelLab'); env.settled(); return env.drain(); },
  no_pending_does_nothing(env) { env.settled(); return env.drain(); },
  privacy_reset_stops_retry(env, row) { env.settled(); row.firstTimers = env.state.timerCount; env.routing.privacy = PRIVACY.NOT_DECIDED; return env.drain(); },
};
const options = {
  not_decided_not_ready: { privacy: PRIVACY.NOT_DECIDED, ready: false },
  not_decided_ready: { privacy: PRIVACY.NOT_DECIDED, ready: true },
  later_ready_consented: { privacy: PRIVACY.CONSENTED, ready: false },
  later_ready_basic_mode: { privacy: PRIVACY.BASIC_MODE, ready: false },
  never_ready_is_bounded: { privacy: PRIVACY.CONSENTED, ready: false },
  settled_twice_pushes_once: { privacy: PRIVACY.CONSENTED, ready: true },
  settled_twice_while_waiting_pushes_once: { privacy: PRIVACY.CONSENTED, ready: false },
  reopens_after_take: { privacy: PRIVACY.BASIC_MODE, ready: true },
  no_pending_does_nothing: { privacy: PRIVACY.CONSENTED, ready: true, pending: false },
  privacy_reset_stops_retry: { privacy: PRIVACY.CONSENTED, ready: false },
};

const results = [];
for (const [name, run] of Object.entries(scenarios)) {
  const row = { name, pushes: 0, timers: 0, firstTimers: 0, drained: false, minDelay: 0 };
  try {
    const env = environment(options[name]);
    row.drained = run(env, row);
    row.pushes = env.state.pushes;
    row.timers = env.state.timerCount;
    row.minDelay = env.state.delays.length ? Math.min(...env.state.delays) : 0;
  } catch (e) {
    row.error = String(e && e.message);
  }
  results.push(row);
}
process.stdout.write(JSON.stringify({ results }));
