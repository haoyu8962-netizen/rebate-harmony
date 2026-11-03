#!/usr/bin/env node
// APP-12v-harmony 测试作者 v1：没有 hvigor 时用 node 执行 core 纯逻辑 Hypium 套件 common/core/src/test/Me12vVisual.test.ets
// （verify 里 hvigor 在 core 全量单测中真跑同一份）。被测对象是产品源码 common/core/src/main/ets/me/MeTabVisual.ets（§3.1 约定：
// 新纯函数都在这一个文件里，由 core Index 导出），以及它与套件用到的已有 Me 源码（MePresentation / MeJson / MeDraftTexts，按真实源码载入；
// 'generated' 按真实 common/generated 源码载入，草稿表的契约字典优先口径照常）。
// 用法：
//   node tools/ci/me12v/run-logic.cjs                 真实产品（实现前红：MISSING_PRODUCTION_INTERFACE）
//   node tools/ci/me12v/run-logic.cjs --ref <文件>    把 <文件> 当作 MeTabVisual.ets（测试作者参考件 / 变异体，只证明测试有牙齿）
//   node tools/ci/me12v/run-logic.cjs --drafts <文件> 把 <文件> 当作 MeDraftTexts.ets（参考件：补了两条新草稿）
//   node tools/ci/me12v/run-logic.cjs --expect-red    退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const meDir = path.join(root, 'common/core/src/main/ets/me');
const product = path.join(meDir, 'MeTabVisual.ets');
const draftsFile = path.join(meDir, 'MeDraftTexts.ets');
const indexParts = ['MeTabVisual.ets', 'MePresentation.ets', 'MeJson.ets', 'MeDraftTexts.ets'].map(p => path.join(meDir, p));
const generatedIndex = path.join(root, 'common/generated/Index.ets');
const suites = ['common/core/src/test/Me12vVisual.test.ets'].map(p => path.join(root, p));
const args = process.argv.slice(2);
const opt = name => (args.indexOf(name) >= 0 ? path.resolve(args[args.indexOf(name) + 1]) : null);
const ref = opt('--ref');
const drafts = opt('--drafts');
const expectRed = args.includes('--expect-red');

function loader(hypium) {
  const cache = new Map();
  function load(filename) {
    let source = filename;
    if (filename === product && ref !== null) source = ref;
    if (filename === draftsFile && drafts !== null) source = drafts;
    if (cache.has(filename)) return cache.get(filename).exports;
    if (!fs.existsSync(source)) throw new Error('MISSING_PRODUCTION_INTERFACE ' + path.relative(root, filename));
    const result = ts.transpileModule(fs.readFileSync(source, 'utf8'), { fileName: filename.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
    const module = { exports: {} };
    cache.set(filename, module);
    function localRequire(name) {
      if (name === '@ohos/hypium') return hypium;
      if (name.startsWith('@kit.') || name.startsWith('@ohos.') || name.startsWith('@hms.')) return {};
      // 套件经 core Index 取接口：只并入 Me 这几份源码（是否真的从 core/Index 导出由 check-arkts.cjs --real 与宿主检查 W5 守）。
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
  const label = ref === null ? 'real product' : 'ref ' + path.basename(ref);
  console.log('ME12V_LOGIC ' + label + ': ' + tests.length + ' tests; failures=' + failures.length);
  const red = failures.length > 0 || tests.length === 0;
  process.exitCode = expectRed ? (red ? 0 : 1) : (red ? 1 : 0);
}

main();
