#!/usr/bin/env node
// APP-12w-b-harmony 测试作者 v1：没有 hvigor 时用 node 执行 core 套件 common/core/src/test/Me12wbPrivacy.test.ets（verify 里 hvigor 在 core
// 全量单测中真跑同一份）。被测对象是真实产品源码（MePresentation / MeJson / MeDraftTexts / account/AccountDraftTexts，以及它们相对引用的源码；
// 'generated' 按真实 common/generated 源码载入）。本任务 Core 零改动，所以这一步今天就应绿；它守的是「视觉改动没碰逻辑结论」。
// 用法：
//   node tools/ci/me12wb/run-logic.cjs                      真实产品
//   node tools/ci/me12wb/run-logic.cjs --swap <相对路径> <文件>   把产品里某个 Me 源码换成 <文件>（变异体，只证明测试有牙齿）
//   node tools/ci/me12wb/run-logic.cjs --expect-red         退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const meDir = path.join(root, 'common/core/src/main/ets/me');
const indexParts = ['MePresentation.ets', 'MeJson.ets', 'MeDraftTexts.ets', 'account/AccountDraftTexts.ets'].map(p => path.join(meDir, p));
const generatedIndex = path.join(root, 'common/generated/Index.ets');
const suites = ['common/core/src/test/Me12wbPrivacy.test.ets'].map(p => path.join(root, p));
const args = process.argv.slice(2);
const swaps = new Map();
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--swap') {
    swaps.set(path.join(root, args[i + 1]), path.resolve(args[i + 2]));
    i += 2;
  }
}
const expectRed = args.includes('--expect-red');

function loader(hypium) {
  const cache = new Map();
  function load(filename) {
    const source = swaps.has(filename) ? swaps.get(filename) : filename;
    if (cache.has(filename)) return cache.get(filename).exports;
    if (!fs.existsSync(source)) throw new Error('MISSING_SOURCE ' + path.relative(root, filename));
    const result = ts.transpileModule(fs.readFileSync(source, 'utf8'), { fileName: filename.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
    const module = { exports: {} };
    cache.set(filename, module);
    function localRequire(name) {
      if (name === '@ohos/hypium') return hypium;
      if (name.startsWith('@kit.') || name.startsWith('@ohos.') || name.startsWith('@hms.')) return {};
      // 套件经 core Index 取接口：只并入这几份源码（是否真的从 core/Index 导出由 check-arkts.cjs --real 守）。
      if (name === '../../Index' || name === 'core') {
        const merged = {};
        for (const part of indexParts) Object.assign(merged, load(part));
        return merged;
      }
      if (name === 'generated') return load(generatedIndex);
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
      failures.push(path.basename(suite) + ' load: ' + String(error.message).split('\n')[0]);
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
  const label = swaps.size === 0 ? 'real product' : 'swapped ' + [...swaps.values()].map(p => path.basename(p)).join(',');
  console.log('ME12WB_LOGIC ' + label + ': ' + tests.length + ' tests; failures=' + failures.length);
  const red = failures.length > 0 || tests.length === 0;
  process.exitCode = expectRed ? (red ? 0 : 1) : (red ? 1 : 0);
}

main();
