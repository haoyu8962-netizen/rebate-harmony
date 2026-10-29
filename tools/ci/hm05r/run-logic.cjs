#!/usr/bin/env node
// HM-05r 测试 v1：没有 hvigor 时用 node 执行 core 的两份纯逻辑 Hypium 套件（Hm05rVector.test.ets、Hm05rLogic.test.ets；
// verify 里 hvigor 在 core 全量单测中真跑同一份）。被测对象是产品源码 common/core/src/main/ets/clipboard/ClipboardImport.ets
// （§3 约定：纯逻辑类都在这一个文件里，由 core Index 导出）；它的相对依赖（Clipboard.ets、ConfigStore.ets 等）一律按真实源码载入。
// 用法：
//   node tools/ci/hm05r/run-logic.cjs                 真实产品（实现前红：MISSING_PRODUCTION_INTERFACE）
//   node tools/ci/hm05r/run-logic.cjs --ref <文件>    把 <文件> 当作 ClipboardImport.ets（测试作者的参考件 / 变异体，只证明测试有牙齿）
//   node tools/ci/hm05r/run-logic.cjs --expect-red    退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const product = path.join(root, 'common/core/src/main/ets/clipboard/ClipboardImport.ets');
const suites = ['common/core/src/test/Hm05rVector.test.ets', 'common/core/src/test/Hm05rLogic.test.ets']
  .map(p => path.join(root, p));
const args = process.argv.slice(2);
const refAt = args.indexOf('--ref');
const ref = refAt >= 0 ? path.resolve(args[refAt + 1]) : null;
const expectRed = args.includes('--expect-red');

function loader(hypium) {
  const cache = new Map();
  function load(filename) {
    const source = filename === product && ref !== null ? ref : filename;
    if (cache.has(filename)) return cache.get(filename).exports;
    if (!fs.existsSync(source)) throw new Error('MISSING_PRODUCTION_INTERFACE ' + path.relative(root, filename));
    const result = ts.transpileModule(fs.readFileSync(source, 'utf8'), { fileName: filename.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
    const module = { exports: {} };
    cache.set(filename, module);
    function localRequire(name) {
      if (name === '@ohos/hypium') return hypium;
      if (name.startsWith('@kit.') || name.startsWith('@ohos.') || name.startsWith('@hms.')) return {};
      // 套件与替身经 core Index 取新接口：只并入 ClipboardImport.ets（是否真的从 core/Index 导出由 check-arkts.cjs --real 守）。
      if (name === '../../Index' || name === 'core') return load(product);
      // 纯逻辑用不到的模块级依赖（generated、按 target 选目录的 core/ets/*）给空对象：ClipboardImport.ets 的相对依赖链里只取常量类。
      if (!name.startsWith('.')) return {};
      return load(path.resolve(path.dirname(filename), name.endsWith('.ets') ? name : name + '.ets'));
    }
    new vm.Script('(function(require,module,exports,$r,ObservedV2,Trace){\n' + result.outputText + '\n})', { filename })
      .runInThisContext()(localRequire, module, module.exports, n => ({ id: -1, params: [n] }), v => v, () => {});
    return module.exports;
  }
  return load;
}

async function main() {
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
  const failures = [];
  const load = loader(hypium);
  for (const suite of suites) {
    try {
      load(suite).default();
    } catch (error) {
      failures.push(path.basename(suite) + ' load: ' + error.message.split('\n')[0]);
    }
  }
  for (const test of tests) {
    try {
      await test.fn();
    } catch (error) {
      failures.push(test.name + ': ' + String(error.message).replace(/\s+/g, ' ').slice(0, 300));
    }
  }
  for (const f of failures) console.log('FAIL ' + f);
  const label = ref === null ? 'real product' : 'ref ' + path.basename(ref);
  console.log('HM05R_LOGIC ' + label + ': ' + tests.length + ' tests; failures=' + failures.length);
  const red = failures.length > 0;
  process.exitCode = expectRed ? (red ? 0 : 1) : (red ? 1 : 0);
}

main();
