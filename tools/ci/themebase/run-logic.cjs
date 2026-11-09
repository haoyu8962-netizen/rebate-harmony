#!/usr/bin/env node
// FU-HM-THEME-BASE-harmony 测试作者 v1：没有 hvigor 时用 node 执行真实 .ets（SDK TypeScript 转译）——
//   common/designsystem/src/test/ThemeBase.test.ets（hvigor 在 designsystem 本机单测里真跑同一份）对真实的
//   common/designsystem/src/main/ets/theme/CouliThemeMapping.ets、CouliThemeTokens.ets、src/test/Ds02Expected.ets。
// 用法：
//   node tools/ci/themebase/run-logic.cjs                          真实产品（任一用例失败退出 1）
//   node tools/ci/themebase/run-logic.cjs --root <树>              换一棵树（先红副本、参考实现副本）
//   node tools/ci/themebase/run-logic.cjs --swap <相对路径> <文件>  把某个源码换成 <文件>（变异体用，可多次）
//   node tools/ci/themebase/run-logic.cjs --expect-red             退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

const args = process.argv.slice(2);
const rootIndex = args.indexOf('--root');
const root = rootIndex >= 0 ? path.resolve(args[rootIndex + 1]) : path.resolve(__dirname, '../../..');
const swaps = new Map();
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--swap') { swaps.set(path.join(root, args[i + 1]), path.resolve(args[i + 2])); i += 2; }
}
const expectRed = args.includes('--expect-red');
const SUITE = path.join(root, 'common/designsystem/src/test/ThemeBase.test.ets');

const tests = [];
const hypium = {
  describe: (_name, fn) => fn(),
  it: (name, _flags, fn) => tests.push({ name, fn }),
  expect: value => ({
    assertEqual: expected => assert.strictEqual(value, expected),
    assertTrue: () => assert.strictEqual(value, true),
    assertFalse: () => assert.strictEqual(value, false),
    assertUndefined: () => assert.strictEqual(value, undefined),
  }),
};

const cache = new Map();
function load(filename) {
  if (cache.has(filename)) return cache.get(filename).exports;
  const source = swaps.has(filename) ? swaps.get(filename) : filename;
  if (!fs.existsSync(source)) throw new Error('MISSING_SOURCE ' + path.relative(root, filename));
  const result = ts.transpileModule(fs.readFileSync(source, 'utf8'), { fileName: filename.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
  const module = { exports: {} };
  cache.set(filename, module);
  function localRequire(name) {
    if (name === '@ohos/hypium') return hypium;
    if (name.startsWith('@kit.') || name.startsWith('@ohos.')) return {};
    if (!name.startsWith('.')) throw new Error('Unsupported dependency: ' + name);
    return load(path.resolve(path.dirname(filename), name.endsWith('.ets') ? name : name + '.ets'));
  }
  new vm.Script('(function(require,module,exports){\n' + result.outputText + '\n})', { filename })
    .runInThisContext()(localRequire, module, module.exports);
  return module.exports;
}

function finish(failures) {
  const failed = failures > 0;
  console.log('THEMEBASE logic: ' + (tests.length - failures) + '/' + tests.length + ' passed; root=' + root +
    (swaps.size ? '; swaps=' + swaps.size : ''));
  process.exitCode = expectRed ? (failed ? 0 : 1) : (failed ? 1 : 0);
}

try {
  load(SUITE).default();
} catch (e) {
  console.log('LOAD_FAIL ' + (e && e.message));
  process.exitCode = expectRed ? 0 : 1;
  process.exit();
}
if (tests.length === 0) { console.log('LOAD_FAIL no tests registered'); process.exitCode = 1; process.exit(); }
let failures = 0;
for (const test of tests) {
  try {
    test.fn();
    console.log('PASS ' + test.name);
  } catch (e) {
    failures++;
    const kind = e instanceof assert.AssertionError ? 'ASSERT' : 'THROW';
    const detail = e instanceof assert.AssertionError ? JSON.stringify(e.actual) + ' != ' + JSON.stringify(e.expected) : String(e && e.message);
    console.log('FAIL[' + kind + '] ' + test.name + ': ' + detail);
  }
}
finish(failures);
