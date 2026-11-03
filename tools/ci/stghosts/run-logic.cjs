#!/usr/bin/env node
// FU-X-STAGING-HOSTS-harmony 测试作者 v1：没有 hvigor 时用 node 执行 core Hypium 套件 common/core/src/test/StagingHosts.test.ets
// （verify 里 hvigor 在 core 全量单测中真跑同一份）。被测对象按真实源码载入：core Index（'core/ets/…' 与 'generated/ets/…' 取 src/release，
// 与本机单测的 default target 一致）、src/staging 的 EnvironmentCatalog（套件按相对路径引入）、真实 ApiClient 与 NetworkTestRig。
// @kit.* / @ohos.* / @hms.* 换成惰性空桩（套件不碰系统能力；用到即为桩值，不冒充系统行为）。
// 用法：
//   node tools/ci/stghosts/run-logic.cjs                 本仓库（实现前红）
//   node tools/ci/stghosts/run-logic.cjs --root <目录>   换一棵树执行（参考实现 / 变异体，只证明测试有牙齿）
//   node tools/ci/stghosts/run-logic.cjs --expect-red    退出码取反（变异体必须至少一条失败）
//   node tools/ci/stghosts/run-logic.cjs --suite <相对路径>  换一个既有 core 套件（旁证用，见下）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const args = process.argv.slice(2);
const rootArg = args.indexOf('--root') >= 0 ? args[args.indexOf('--root') + 1] : null;
const root = rootArg ? path.resolve(rootArg) : path.resolve(__dirname, '../../..');
const expectRed = args.includes('--expect-red');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
// --suite <相对路径>：换一个既有 core 套件执行（只用于在参考实现树上旁证「streamBase 为空时既有网络 / Agent 套件不变」）。
const suite = path.join(root, args.indexOf('--suite') >= 0 ? args[args.indexOf('--suite') + 1] : 'common/core/src/test/StagingHosts.test.ets');

function kitStub() {
  const fn = function () {};
  return new Proxy(fn, {
    get: (_t, key) => (key === 'then' ? undefined : key === Symbol.toPrimitive ? () => '' : kitStub()),
    apply: () => kitStub(),
    construct: () => kitStub(),
  });
}

function loader(hypium) {
  const cache = new Map();
  function load(file) {
    if (cache.has(file)) return cache.get(file).exports;
    if (!fs.existsSync(file)) throw new Error('MISSING ' + path.relative(root, file));
    const out = ts.transpileModule(fs.readFileSync(file, 'utf8'), { fileName: file.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true } });
    const module = { exports: {} };
    cache.set(file, module);
    const resolve = base => [base, base + '.ets', base + '.ts'].find(f => fs.existsSync(f) && fs.statSync(f).isFile());
    function localRequire(name) {
      if (name === '@ohos/hypium') return hypium;
      if (name.startsWith('@kit.') || name.startsWith('@ohos.') || name.startsWith('@hms.')) return kitStub();
      const m = name.match(/^(core|generated|designsystem)(?:\/(.*))?$/);
      if (m) {
        const dir = path.join(root, 'common', m[1]);
        if (!m[2]) return load(path.join(dir, 'Index.ets'));
        const sub = m[2].startsWith('ets/') ? 'src/release/' + m[2] : m[2];
        const f = resolve(path.join(dir, sub));
        if (!f) throw new Error('cannot resolve ' + name);
        return load(f);
      }
      if (name.startsWith('.')) {
        const f = resolve(path.resolve(path.dirname(file), name));
        if (!f) throw new Error('cannot resolve ' + name + ' from ' + path.relative(root, file));
        return load(f);
      }
      throw new Error('unknown module ' + name + ' from ' + path.relative(root, file));
    }
    new vm.Script('(function(require,module,exports,$r,ObservedV2,Trace){\n' + out.outputText + '\n})', { filename: file })
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
  try {
    loader(hypium)(suite).default();
  } catch (error) {
    failures.push('load: ' + String(error.message).split('\n')[0]);
  }
  for (const test of tests) {
    try {
      await Promise.race([test.fn(), new Promise((_, bad) => setTimeout(() => bad(new Error('timeout 20s')), 20000).unref())]);
      console.log('ok   ' + test.name);
    } catch (error) {
      failures.push(test.name + ': ' + String(error.message).replace(/\s+/g, ' ').slice(0, 300));
    }
  }
  for (const f of failures) console.log('FAIL ' + f);
  console.log('STGHOSTS_LOGIC ' + path.relative(process.cwd(), root || '.') + ': ' + tests.length + ' tests; failures=' + failures.length);
  const red = failures.length > 0 || tests.length === 0;
  process.exitCode = expectRed ? (red ? 0 : 1) : (red ? 1 : 0);
}

main();
