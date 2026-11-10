#!/usr/bin/env node
// HM-L2-SKELETON-harmony 测试作者 v1：没有 hvigor 时用 node 执行真实 .ets（SDK TypeScript 转译，照 tools/ci/feelkit/run-logic.cjs）。
// 跑 common/designsystem/src/test/SkeletonGate.test.ets（hvigor 在 designsystem 本机单测里真跑同一份）对真实 logic/SkeletonGate.ets。
// 先红口径（书 §3「逻辑红是契约缺失，不能是导入错误」）：logic/SkeletonGate.ets 不存在或缺导出名时，换成「契约缺失」桩——
// 用到就抛 AssertionError('CONTRACT_MISSING …')，每条用例照常注册、各自红在断言（FAIL[ASSERT]），不是 LOAD_FAIL / THROW。
// 用法：
//   node tools/ci/l2skeleton/run-logic.cjs                           真实产品（任一用例失败退出 1）
//   node tools/ci/l2skeleton/run-logic.cjs --root <树>               换一棵树（先红副本、参照实现副本）
//   node tools/ci/l2skeleton/run-logic.cjs --swap <相对路径> <文件>   把某个源码换成 <文件>（变异体用，可多次）
//   node tools/ci/l2skeleton/run-logic.cjs --expect-red              退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
    'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

const args = process.argv.slice(2);
const rootIndex = args.indexOf('--root');
const root = rootIndex >= 0 ? path.resolve(args[rootIndex + 1]) : path.resolve(__dirname, '../../..');
const swaps = new Map();
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--swap') { swaps.set(path.join(root, args[i + 1]), path.resolve(args[i + 2])); i += 2; }
}
const expectRed = args.includes('--expect-red');
// 用例文件：--root 那棵树里有就用它，否则用本仓库的（参照件夹具只放产品侧文件）。
const SUITE_REL = 'common/designsystem/src/test/SkeletonGate.test.ets';
const SUITE = fs.existsSync(path.join(root, SUITE_REL)) ? path.join(root, SUITE_REL) : path.resolve(__dirname, '../../..', SUITE_REL);
const GATE = path.join(root, 'common/designsystem/src/main/ets/logic/SkeletonGate.ets');
// 书 §2.4 + 测试作者约定的契约名（SkeletonGate.test.ets 文件头）。
const CONTRACT = ['SkeletonGate', 'SkeletonPhase', 'shimmerEnabled'];

function contractStub(missing, why) {
  const fail = () => { throw new assert.AssertionError({ message: 'CONTRACT_MISSING ' + missing + '：' + why }); };
  const handler = { get: (_t, key) => (key === Symbol.toPrimitive ? fail : fail()), apply: fail, construct: fail };
  return new Proxy(function stub() {}, handler);
}

function makeLoader(fakes) {
  const cache = new Map();
  function load(filename) {
    if (cache.has(filename)) return cache.get(filename).exports;
    const module = { exports: {} };
    cache.set(filename, module);
    const source = swaps.has(filename) ? swaps.get(filename) : filename;
    if (filename === GATE && !fs.existsSync(source)) {
      for (const name of CONTRACT) {
        module.exports[name] = contractStub(name, 'common/designsystem/src/main/ets/logic/SkeletonGate.ets 不存在（书 §2.4）');
      }
      return module.exports;
    }
    if (!fs.existsSync(source)) throw new Error('MISSING_SOURCE ' + path.relative(root, filename));
    const result = ts.transpileModule(fs.readFileSync(source, 'utf8'), { fileName: filename.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
    function localRequire(name) {
      if (name in fakes) return fakes[name];
      // 纯逻辑文件不得依赖系统能力（宿主 K3 另钉）；这里遇到 @kit / @ohos 直接报错，不给假实现。
      if (name.startsWith('@kit.') || name.startsWith('@ohos.')) {
        throw new Error('PURE_LOGIC_VIOLATION ' + path.relative(root, filename) + ' import ' + name);
      }
      if (!name.startsWith('.')) throw new Error('Unsupported dependency: ' + name);
      let target = path.resolve(path.dirname(filename), name.endsWith('.ets') ? name : name + '.ets');
      // 用例文件来自本仓库、被测文件来自 --root：把 ../main/ets/… 映射到 --root 下的同一相对路径。
      const rel = path.relative(path.resolve(__dirname, '../../..'), target);
      if (filename === SUITE && !rel.startsWith('..')) { target = path.join(root, rel); }
      return load(target);
    }
    new vm.Script('(function(require,module,exports){\n' + result.outputText + '\n})', { filename })
      .runInThisContext()(localRequire, module, module.exports);
    if (filename === GATE) {
      for (const name of CONTRACT) {
        if (!(name in module.exports)) {
          module.exports[name] = contractStub(name, 'logic/SkeletonGate.ets 没有导出 ' + name);
        }
      }
    }
    return module.exports;
  }
  return load;
}

const results = [];
function record(name, error) {
  if (!error) { results.push(true); console.log('PASS ' + name); return; }
  results.push(false);
  const kind = error instanceof assert.AssertionError ? 'ASSERT' : 'THROW';
  const detail = error instanceof assert.AssertionError
    ? (error.generatedMessage ? JSON.stringify(error.actual) + ' != ' + JSON.stringify(error.expected) : error.message)
    : String(error && error.message);
  console.log('FAIL[' + kind + '] ' + name + ': ' + detail);
}

function runSuite() {
  const tests = [];
  const hypium = {
    describe: (_name, fn) => fn(),
    it: (name, _flags, fn) => tests.push({ name, fn }),
    expect: value => ({
      assertEqual: expected => assert.strictEqual(value, expected),
      assertTrue: () => assert.strictEqual(value, true),
      assertFalse: () => assert.strictEqual(value, false),
    }),
  };
  try {
    makeLoader({ '@ohos/hypium': hypium })(SUITE).default();
  } catch (e) {
    console.log('LOAD_FAIL suite ' + (e && e.message));
    results.push(false);
    return;
  }
  if (tests.length === 0) { console.log('LOAD_FAIL no tests registered'); results.push(false); return; }
  for (const test of tests) {
    try { test.fn(); record(test.name); } catch (e) { record(test.name, e); }
  }
}

runSuite();
const failed = results.filter(r => !r).length;
console.log('L2SKEL logic: ' + (results.length - failed) + '/' + results.length + ' passed; root=' + root +
  (swaps.size ? '; swaps=' + swaps.size : ''));
process.exitCode = expectRed ? (failed ? 0 : 1) : (failed ? 1 : 0);
