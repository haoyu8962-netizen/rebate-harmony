#!/usr/bin/env node
// F-X-24 远程禁用桥方法的 Node 执行测试（verify.sh 固定入口调用）：转译并执行同一份 ArkTS 测试、锁定版本 H5 SDK 的 has()
// 与原生推送 / 去重 / 令牌门控（fx24-native-push-test.js）。不代替 ArkTS 类型检查 / Hypium / 设备测试。
// 用法：DevEco 的 node tools/ci/bridge-disabled-methods-test.js；REBATE_PLATFORM_DIR 指定锁定 SDK 源码所在仓库，
// 可用 COULI_HM_TYPESCRIPT 指定现有 SDK TypeScript。
'use strict';
const fs = require('fs');
const path = require('path');
const Module = require('module');
const assert = require('assert');
const vm = require('vm');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '../..');
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const tsDir = process.env.COULI_HM_TYPESCRIPT || path.join(sdk,
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const ts = require(tsDir);
const tests = [];
let suite = '';
const hypium = {
  describe(name, run) {
    const previous = suite;
    suite = name;
    try { run(); } finally { suite = previous; }
  },
  it(name, _flags, run) { tests.push({ name: suite + '.' + name, run }); },
  expect(actual) {
    return {
      assertEqual(expected) { assert.strictEqual(actual, expected); },
      assertTrue() { assert.strictEqual(actual, true); },
      assertFalse() { assert.strictEqual(actual, false); },
      assertNull() { assert.strictEqual(actual, null); }
    };
  }
};

const originalResolve = Module._resolveFilename;
Module._resolveFilename = function (name, parent, ...rest) {
  if (name === 'generated' || name === 'core') {
    name = path.join(root, 'common', name, 'Index.ets');
  } else if (name.startsWith('generated/ets/')) {
    name = path.join(root, 'common/generated/src/release', name.slice('generated/'.length));
  } else if (name.startsWith('generated/')) {
    name = path.join(root, 'common', name);
  } else if (name.startsWith('core/ets/')) {
    name = path.join(root, 'common/core/src/release', name.slice('core/'.length));
  }
  return originalResolve.call(this, name, parent, ...rest);
};

const originalLoad = Module._load;
Module._load = function (name, parent, isMain) {
  if (name === '@ohos/hypium') return hypium;
  // 网络 Rig 已注入 digest/random/transport。系统模块若真被使用就失败，不能默默伪造成功。
  if (name.startsWith('@kit.') || name.startsWith('@ohos.')) {
    return new Proxy({}, { get(_target, member) {
      throw new Error('Node fallback cannot use platform API: ' + name + '.' + String(member));
    } });
  }
  return originalLoad.call(this, name, parent, isMain);
};

let parsedFiles = 0;
Module._extensions['.ets'] = function (mod, filename) {
  const source = fs.readFileSync(filename, 'utf8');
  const ast = ts.createSourceFile(filename, source, ts.ScriptTarget.ES2021, true, ts.ScriptKind.ETS);
  if (ast.parseDiagnostics.length > 0) {
    throw new Error(filename + ': ' + ast.parseDiagnostics.map(d =>
      ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'));
  }
  parsedFiles++;
  // Barrel 仅懒加载测试实际使用的导出；不初始化无关的设备模块。导出映射直接读源码 AST。
  if (ast.statements.length > 0 && ast.statements.every(statement =>
    ts.isExportDeclaration(statement) && statement.moduleSpecifier)) {
    for (const statement of ast.statements) {
      if (!ts.isExportDeclaration(statement) || !statement.moduleSpecifier) continue;
      if (!statement.exportClause) {
        const exported = mod.require(statement.moduleSpecifier.text);
        for (const name of Object.keys(exported)) {
          if (Object.prototype.hasOwnProperty.call(mod.exports, name)) continue;
          Object.defineProperty(mod.exports, name, { enumerable: true, get: () => exported[name] });
        }
        continue;
      }
      if (!ts.isNamedExports(statement.exportClause)) {
        throw new Error('Unsupported barrel export: ' + filename);
      }
      for (const item of statement.exportClause.elements) {
        Object.defineProperty(mod.exports, item.name.text, {
          enumerable: true,
          get: () => mod.require(statement.moduleSpecifier.text)[(item.propertyName || item.name).text]
        });
      }
    }
    return;
  }
  const compiled = ts.transpileModule(source, {
    fileName: filename,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  });
  mod._compile(compiled.outputText, filename);
};

// 同仓库现有 bridge-bootstrap-test.js 的 VM 做法：执行真实启动脚本和锁定版本的 H5 SDK has()。
// SDK 与它的生成契约只读 git show，不改上游；禁止用自己写的 includes() 假冒 has()。
function registerHasTests() {
  const lock = JSON.parse(fs.readFileSync(path.join(root, 'contract.lock'), 'utf8'));
  const platform = process.env.REBATE_PLATFORM_DIR || '/Users/zhixing/我的项目/rebate-platform';
  const readLocked = file => execFileSync('git', ['-C', platform, 'show',
    lock.rebate_platform.commit + ':' + file], { encoding: 'utf8' });
  const compile = source => ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const contractCode = compile(readLocked('packages/contracts-ts/src/bridge.gen.ts'));
  const sdkCode = compile(readLocked('packages/bridge-sdk/src/bridge.ts'));
  console.log('H5 has() source: rebate-platform@' + lock.rebate_platform.commit);
  const { BridgeHost } = require(path.join(root, 'common/core/src/main/ets/bridge/BridgeHost.ets'));
  const { FakeState, ManualClock } = require(path.join(root, 'common/core/src/test/BridgeHost.test.ets'));
  const { Fx24ConfigRig } = require(path.join(root, 'common/core/src/test/Fx24ConfigRig.ets'));
  const { bridgeBootstrapScript } = require(path.join(root, 'features/web/src/main/ets/BridgeBootstrapScript.ets'));
  function pageFor(raw) {
    const config = new Fx24ConfigRig();
    config.apply(raw);
    const host = new BridgeHost(new FakeState(), new ManualClock());
    host.disabledMethods = () => config.methods();
    const window = { __couliBridgeNative: { post() {}, hello() {} } };
    window.top = window;
    window.window = window;
    const context = vm.createContext(window);
    vm.runInContext(bridgeBootstrapScript(host.supportedMethods(), 90002, 'invalid params'), context);
    const contract = {};
    vm.runInContext('(function(exports){' + contractCode + '\n})', context)(contract);
    const sdkExports = {};
    vm.runInContext('(function(exports, require){' + sdkCode + '\n})', context)(sdkExports, name => {
      assert.strictEqual(name, '@couli/contracts-ts');
      return { bridge: contract };
    });
    return { window, context, config, host, has: sdkExports.has };
  }
  function hasFor(raw) {
    return pageFor(raw).has;
  }
  hypium.describe('BridgeSdkHas_FX24', () => {
    hypium.it('B2_real_sdk_has_is_false_when_native_disables_a_supported_method', 0, () => {
      assert.ok(hasFor('[]')('clipboard.write'));
      assert.strictEqual(hasFor('["clipboard.write"]')('clipboard.write'), null);
      assert.strictEqual(hasFor('["clipboard.read"]')('clipboard.read'), null);
    });
    hypium.it('B6_real_sdk_has_keeps_supported_methods_for_unknown_disabled_name', 0, () => {
      const has = hasFor('["unknown.method"]');
      assert.ok(has('clipboard.write'));
      assert.ok(has('app.getEnv'));
      assert.strictEqual(has('clipboard.read'), null);
    });
    hypium.it('B2_B5_open_page_real_sdk_has_sync_requires_current_token_and_recovers', 0, () => {
      const p = pageFor('[]');
      const bridge = p.window.__REBATE_BRIDGE__;
      // 测试用假令牌：运行时拼出 0..f 两遍，不在源码里写字面量。
      const token = Array.from({ length: 32 }, (_, i) => (i % 16).toString(16)).join('');
      p.window.__couliBridgeToken(token);
      const enabled = Array.from(bridge.methods);
      assert.ok(p.has('clipboard.write'));
      assert.ok(p.has('app.getEnv'));

      // 同一 ConfigStore / host / VM / SDK 实例；模拟宿主向已打开页面投递方法列表。
      p.config.apply('["clipboard.write"]', 'disabled');
      const disabled = p.host.supportedMethods();
      p.window.__couliBridgeMethods('wrong-token', disabled);
      assert.deepStrictEqual(Array.from(bridge.methods), enabled);
      assert.ok(p.has('clipboard.write'));
      p.window.__couliBridgeMethods(token, disabled);
      assert.deepStrictEqual(Array.from(bridge.methods), disabled);
      assert.strictEqual(p.has('clipboard.write'), null);
      assert.ok(p.has('app.getEnv'));

      p.config.apply('[]', 'restored');
      p.window.__couliBridgeMethods('wrong-token', p.host.supportedMethods());
      assert.deepStrictEqual(Array.from(bridge.methods), disabled);
      assert.strictEqual(p.has('clipboard.write'), null);
      p.window.__couliBridgeMethods(token, p.host.supportedMethods());
      assert.deepStrictEqual(Array.from(bridge.methods), enabled);
      assert.ok(p.has('clipboard.write'));
      assert.ok(p.has('app.getEnv'));
      assert.strictEqual(p.window.__REBATE_BRIDGE__, bridge);
    });
  });
  require('./fx24-native-push-test')({ root, ts, tsDir, hypium, pageFor });
}

async function run() {
  console.log('SUPPLEMENTAL NODE RUN — real product source, same F-X-24 test bodies; NOT Hypium/typecheck');
  for (const name of ['ClientCoreBridgeDisabled', 'BridgeDisabledMethods']) {
    require(path.join(root, 'common/core/src/test', name + '.test.ets')).default();
  }
  registerHasTests();
  let failures = 0;
  for (const test of tests) {
    let timer;
    try {
      await Promise.race([
        Promise.resolve().then(test.run),
        new Promise((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error('test exceeded 5s')), 5000);
        })
      ]);
      console.log('PASS ' + test.name);
    } catch (error) {
      failures++;
      console.log('FAIL ' + test.name + '\n' + error.stack);
    } finally {
      clearTimeout(timer);
    }
  }
  console.log('Parsed product/test files: ' + parsedFiles);
  console.log('Tests run: ' + tests.length + ', Passed: ' + (tests.length - failures) + ', Failed: ' + failures);
  process.exitCode = failures ? 1 : 0;
}
run().catch(error => {
  console.error('HARNESS ERROR: ' + error.stack);
  process.exitCode = 2;
});
