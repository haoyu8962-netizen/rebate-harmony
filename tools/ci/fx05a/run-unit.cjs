#!/usr/bin/env node
// F-X-05a：没有 hvigor 时用 node 执行同一份 Hypium 纯逻辑断言（Fx05aPlatformIcon.test.ets）。只跑产品真实源码；
// --self-test 用内存参考件证明断言有牙齿（参考件只自证测试，绝不算产品通过）。不模拟 ArkUI / 设备。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const suite = path.join(root, 'common/designsystem/src/test/Fx05aPlatformIcon.test.ets');
const iconPath = path.join(root, 'common/designsystem/src/main/ets/components/PlatformIconSource.ets');

function runner(overrides = new Map()) {
  const cache = new Map();
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
  function load(filename) {
    if (overrides.has(filename)) return overrides.get(filename);
    if (cache.has(filename)) return cache.get(filename).exports;
    if (!fs.existsSync(filename)) throw new Error('MISSING_PRODUCTION_INTERFACE ' + path.relative(root, filename));
    const source = fs.readFileSync(filename, 'utf8');
    const result = ts.transpileModule(source, { fileName: filename.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
    const module = { exports: {} };
    cache.set(filename, module);
    function localRequire(name) {
      if (name === '@ohos/hypium') return hypium;
      if (name === '@kit.ArkUI') return {
        LengthMetrics: { vp: value => ({ value, unit: 1 }) },
        ColorMetrics: { numeric: value => ({ red: (value >>> 16) & 255, green: (value >>> 8) & 255, blue: value & 255 }) },
      };
      if (name.startsWith('@kit.')) return {};
      if (name === 'generated') return load(path.join(root, 'common/generated/Index.ets'));
      if (name === 'generated/ets/DebugOnly') return load(path.join(root, 'common/generated/src/release/ets/DebugOnly.ets'));
      if (!name.startsWith('.')) throw new Error('Unsupported native dependency: ' + name);
      return load(path.resolve(path.dirname(filename), name.endsWith('.ets') ? name : name + '.ets'));
    }
    new vm.Script('(function(require,module,exports,$r,ObservedV2,Trace){\n' + result.outputText + '\n})', { filename })
      .runInThisContext()(localRequire, module, module.exports, name => ({ id: -1, params: [name] }), value => value, () => {});
    return module.exports;
  }
  return {
    run() {
      const failures = [];
      try { load(suite).default(); } catch (error) { failures.push('load: ' + error.message); }
      for (const test of tests) {
        try { test.fn(); } catch (error) { failures.push(test.name + ': ' + error.message.split('\n')[0]); }
      }
      return { total: tests.length, failures };
    },
  };
}

// 参考件：照 BR-TEXT-24 标识键表；mutation 模拟常见错误实现。
function reference(mutation = '') {
  const table = { taobao: 'taobao', jd: 'jd', pdd: 'pinduoduo' };
  if (mutation === 'pdd-as-pinduoduo') { delete table.pdd; table.pinduoduo = 'pinduoduo'; }
  if (mutation === 'pdd-to-taobao') table.pdd = 'taobao';
  if (mutation === 'tmall-placeholder') table.tmall = 'platform_placeholder';
  const mediaName = key => {
    if (mutation === 'case-insensitive') key = String(key).trim().toLowerCase();
    if (mutation === 'prototype-lookup') return table[key] || '';
    return Object.prototype.hasOwnProperty.call(table, key) ? table[key] : '';
  };
  class PlatformIconSource {
    static mediaName(key) { return mediaName(key); }
    static builtin(key) { const m = mediaName(key); return m ? m + '.png' : ''; }
    static hasBuiltin(key) { return mediaName(key).length > 0; }
  }
  const PlatformIconSize = { BADGE: 14, GRID: mutation === 'grid-48' ? 48 : 44 };
  // Logic.ets 是否真的重导出由 check_platform_icons.py S1 守；参考件这里两处给同一份。
  const exportsRef = { PlatformIconSource, PlatformIconSize };
  return new Map([[iconPath, exportsRef], [path.join(root, 'common/designsystem/Logic.ets'), exportsRef]]);
}

if (process.argv.includes('--self-test')) {
  const legal = runner(reference()).run();
  assert.equal(legal.failures.length, 0, JSON.stringify(legal));
  console.log('REFERENCE_ONLY legal: ' + legal.total + ' tests passed');
  for (const mutation of ['pdd-as-pinduoduo', 'pdd-to-taobao', 'tmall-placeholder', 'case-insensitive', 'prototype-lookup', 'grid-48']) {
    const result = runner(reference(mutation)).run();
    assert.ok(result.failures.length > 0, 'mutant survived: ' + mutation);
    console.log('REFERENCE_ONLY mutant killed ' + mutation + ': ' + result.failures[0]);
  }
} else {
  const result = runner().run();
  for (const failure of result.failures) console.error(failure);
  console.log('FX05A_NODE_REAL_SOURCE tests=' + result.total + ' failures=' + result.failures.length);
  process.exitCode = result.failures.length ? 1 : 0;
}
