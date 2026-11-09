#!/usr/bin/env node
// FU-HM-FEEL-KIT-harmony 测试作者 v2（D10-1163 ②）：真执行 staging BuildVariant 里推 CATALOG_ROUTE 的方法体，判隐私口径（规则判定在 check_feel_kit.py C9）。
// stdin：{ "body": 方法体源码（含花括号）}；stdout：{ incomplete } 或 { results: [{ privacy, pending, ready, pushed, error? }] }。
// 方法体里的标识符都接假对象：AppRouting.shared 的 presentationReady / privacyState 取用例值，CatalogLaunch.shared 的方法按「有待打开组件」回答
// （has* / is* 回布尔，其余回组件名或空串），PrivacyState 用真实取值；任何调用的实参里出现 CATALOG_ROUTE 即算推了目录。不冒充设备执行。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
    'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

const ROUTE = 'CouliComponentCatalog';
const PRIVACY = { CONSENTED: 'consented', BASIC_MODE: 'basic_mode', NOT_DECIDED: 'not_decided' };

function makeProxy(state, overrides, answer) {
  const make = (trail, name) => new Proxy(function () {}, {
    get(_target, key) {
      if (typeof key === 'symbol' || key === 'then') return undefined;
      const next = trail ? trail + '.' + key : key;
      return Object.prototype.hasOwnProperty.call(overrides, next) ? overrides[next] : make(next, key);
    },
    apply(_target, _self, args) {
      if (args.includes(ROUTE)) state.pushed = true;
      return answer ? answer(name) : make(trail + '()', name);
    },
    construct() { return make(trail + '#new', name); },
  });
  return make('', '');
}

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const output = ts.transpileModule('function coldStart() ' + input.body, { fileName: 'cold.ts',
  compilerOptions: { module: ts.ModuleKind.None, target: ts.ScriptTarget.ES2020 } });
let run;
try {
  run = new vm.Script('(function(scope){with(scope){\n' + output.outputText + '\nreturn coldStart;}})').runInThisContext();
} catch (e) {
  process.stdout.write(JSON.stringify({ incomplete: String(e && e.message) }));
  process.exit(0);
}

const results = [];
for (const privacy of Object.values(PRIVACY)) {
  for (const pending of [true, false]) {
    for (const ready of [true, false]) {
      const state = { pushed: false };
      const known = {
        CATALOG_ROUTE: ROUTE,
        PrivacyState: PRIVACY,
        AppRouting: makeProxy(state, { 'shared.presentationReady': ready, 'shared.privacyState': privacy }),
        CatalogLaunch: makeProxy(state, {}, name => (/^(has|is)/.test(name) ? pending : (pending ? 'ProductCard' : ''))),
      };
      const fallback = makeProxy(state, {});
      const scope = new Proxy(known, {
        has: (target, key) => typeof key === 'string' && (key in target || !(key in globalThis)),
        get: (target, key) => (key === Symbol.unscopables ? undefined : (key in target ? target[key] : fallback[key])),
      });
      const row = { privacy, pending, ready, pushed: false };
      try {
        run(scope)();
        row.pushed = state.pushed;
      } catch (e) {
        row.error = String(e && e.message);
      }
      results.push(row);
    }
  }
}
process.stdout.write(JSON.stringify({ results }));
