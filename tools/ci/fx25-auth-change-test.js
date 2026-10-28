#!/usr/bin/env node
// F-X-25：离线补充执行；不代替 ArkTS 类型检查与设备测试。
'use strict';
const fs = require('fs');
const path = require('path');
const Module = require('module');
const assert = require('assert');
const vm = require('vm');
const { execFileSync } = require('child_process');

const root = process.env.FX25_SOURCE_ROOT || path.resolve(__dirname, '../..');
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
  // t1（R3-04）：生产 FileSlot 的 fileIo 落到测试沙盒端口（缺省关闭、一用就抛，和其他系统模块一样；只有 N7 生产组合打开，只放行其临时目录）。
  if (name === '@kit.CoreFileKit') return { fileIo: require('./fx25-v3-ports').sandboxFileIo };
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
  const source = require('./fx25-v3-mutations').mutate(filename, fs.readFileSync(filename, 'utf8'));
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
  const clockPort = filename.endsWith('/bridge/TrustedAuthSync.ets') ?
    'const { setTimeout, clearTimeout } = require(' + JSON.stringify(path.join(__dirname, 'fx25-v3-ports.js')) + ');\n' : '';
  mod._compile(clockPort + compiled.outputText, filename);
};

// t1：脚本执行进已销毁文档会以拒绝结束；产品没人等它时（例如变异去掉了等待）Node 不得因此整进程退出、吞掉其余用例的结果。
// ArkTS 运行时对没人处理的拒绝只记日志，这里同样只记一行。
process.on('unhandledRejection', reason => { console.log('UNHANDLED-REJECTION ' + (reason && reason.message ? reason.message : String(reason))); });
async function run() {
  console.log('F-X-25 supplemental Node — actual product source; NOT Hypium/typecheck/device');
  let failures = 0;
  try { require(path.join(root, 'common/core/src/test/AuthChangeDecision.test.ets')).default(); }
  catch (error) { failures++; console.log('FAIL Core interface: ' + error.message); }
  try { require('./fx25-native-auth-test')({ root, ts, tsDir, hypium }); }
  catch (error) { failures++; console.log('FAIL Native harness: ' + error.stack); }
  try { require('./fx25-auth-v3-test')({ root, ts, tsDir, hypium }); }
  catch (error) { failures++; console.log('FAIL V3 harness: ' + error.stack); }
  try { require('./fx25-auth-v6-test')({ root, ts, tsDir, hypium }); }
  catch (error) { failures++; console.log('FAIL V6 harness: ' + error.stack); }
  try { require('./fx25-auth-v7-test')({ root, ts, tsDir, hypium }); }
  catch (error) { failures++; console.log('FAIL V7 harness: ' + error.stack); }
  // t1（新方案「先拆后清再建」，D10-279）：N1–N7 + 生产沙盒归属记录 / 待清标记的 core 用例（R3-04）。
  try { require('./fx25-auth-t1-test')({ root, ts, tsDir, hypium }); }
  catch (error) { failures++; console.log('FAIL T1 harness: ' + error.stack); }
  // t3（设备问题修复后）：载体空白页 / 入口请求被吞 / 看门狗有界重发 / 17100001 字符串码。
  try { require('./fx25-auth-t3-test')({ root, ts, tsDir, hypium }); }
  catch (error) { failures++; console.log('FAIL T3 harness: ' + error.stack); }
  // t4（评审新 r1 之后）：NR1-01 隔离拦子资源 / 拆后宽限 / 清后读回复核，NR1-04 双信号缺一（已解绑、onDisAppear 未到）。
  try { require('./fx25-auth-t4-test')({ root, ts, tsDir, hypium }); }
  catch (error) { failures++; console.log('FAIL T4 harness: ' + error.stack); }
  try { require(path.join(root, 'common/core/src/test/TrustedWebRecordsFX25.test.ets')).default(); }
  catch (error) { failures++; console.log('FAIL Core records: ' + error.message); }
  const filter = process.env.FX25_TEST_FILTER ? new RegExp(process.env.FX25_TEST_FILTER) : null;
  let executed = 0;
  for (const test of tests) {
    if (filter && !filter.test(test.name)) continue;
    executed++;
    let timer;
    try {
      await Promise.race([Promise.resolve().then(test.run), new Promise((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error('no completion signal within 5s')), 5000);
      })]);
      console.log('PASS ' + test.name);
    } catch (error) { failures++; console.log('FAIL ' + test.name + '\n' + error.stack); }
    finally { clearTimeout(timer); }
  }
  if (executed === 0) { failures++; console.log('FAIL no tests selected'); }
  console.log('Executed: ' + executed);
  console.log('Registered: ' + tests.length + '; failures (including missing interfaces): ' + failures);
  process.exitCode = failures ? 1 : 0;
}
// 跑完即退出：产品里没人取消的轮询 / 计时器不得让门禁挂住（结果已全部打印）。
run().catch(error => { console.error(error.stack); process.exitCode = 2; }).finally(() => process.exit(process.exitCode));
