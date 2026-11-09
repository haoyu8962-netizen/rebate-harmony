#!/usr/bin/env node
// FU-HM-ICON-SYMBOL-harmony 测试作者 v1：没有 hvigor 时用 node 执行真实 .ets（SDK TypeScript 转译）——
//   common/designsystem/src/test/IconSymbol.test.ets（hvigor 在 designsystem 本机单测里真跑同一份）对真实的 Logic.ets 与 CouliIcon.ets 路径表。
// CouliIcon.ets 含 ArkUI 组件，node 跑不了整文件：用 SDK 解析器切掉 import 和 struct，其余语句原文转译；'../../Index' 只给 CouliIconPaths，
// 且先用解析器核 Index.ets 确实从 CouliIcon 导出它（导出没了就是真红）。
// 用法：
//   node tools/ci/iconsymbol/run-logic.cjs                           真实产品（任一用例失败退出 1）
//   node tools/ci/iconsymbol/run-logic.cjs --root <树>               换一棵树（桩 / 参考实现副本）
//   node tools/ci/iconsymbol/run-logic.cjs --swap <相对路径> <文件>   把某个源码换成 <文件>（变异体用，可多次）
//   node tools/ci/iconsymbol/run-logic.cjs --expect-red              退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const loader = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.COULI_HM_TYPESCRIPT || path.join(loader, 'node_modules/typescript'));
const options = { ets: ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets,
  etsLoaderPath: loader };

const args = process.argv.slice(2);
const rootIndex = args.indexOf('--root');
const root = rootIndex >= 0 ? path.resolve(args[rootIndex + 1]) : path.resolve(__dirname, '../../..');
const swaps = new Map();
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--swap') { swaps.set(path.join(root, args[i + 1]), path.resolve(args[i + 2])); i += 2; }
}
const expectRed = args.includes('--expect-red');
const DS = path.join(root, 'common/designsystem');
const SUITE = path.join(DS, 'src/test/IconSymbol.test.ets');
const ICON = path.join(DS, 'src/main/ets/components/CouliIcon.ets');
const INDEX = path.join(DS, 'Index.ets');

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

const readSource = filename => fs.readFileSync(swaps.has(filename) ? swaps.get(filename) : filename, 'utf8');
const parseEts = (filename, text) => ts.createSourceFile(filename, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options);

function run(filename, source, requireFn) {
  const result = ts.transpileModule(source, { fileName: filename.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
  const module = { exports: {} };
  new vm.Script('(function(require,module,exports){\n' + result.outputText + '\n})', { filename })
    .runInThisContext()(requireFn, module, module.exports);
  return module.exports;
}

/** Index.ets 的导出 + CouliIcon.ets 的切片。 */
function loadIndex() {
  const index = parseEts(INDEX, readSource(INDEX));
  const exported = index.statements.some(s => ts.isExportDeclaration(s) && s.moduleSpecifier && s.moduleSpecifier.text.endsWith('components/CouliIcon') &&
    s.exportClause && ts.isNamedExports(s.exportClause) && s.exportClause.elements.some(e => e.name.text === 'CouliIconPaths'));
  if (!exported) throw new Error('Index.ets 没有从 components/CouliIcon 导出 CouliIconPaths');
  const tree = parseEts(ICON, readSource(ICON));
  if (tree.parseDiagnostics.length) throw new Error('CouliIcon.ets 解析失败：' + ts.flattenDiagnosticMessageText(tree.parseDiagnostics[0].messageText, '\n'));
  const slice = tree.statements.filter(s => !ts.isImportDeclaration(s) && !(ts.isStructDeclaration && ts.isStructDeclaration(s)))
    .map(s => s.getText()).join('\n');
  // 切片里 couliSymbolOf 只声明不调用，$r 用不到；真调用它的是宿主检查。
  return run(ICON, slice, () => ({}));
}

const cache = new Map();
function load(filename) {
  if (cache.has(filename)) return cache.get(filename).exports;
  if (!fs.existsSync(swaps.has(filename) ? swaps.get(filename) : filename)) throw new Error('MISSING_SOURCE ' + path.relative(root, filename));
  const module = { exports: {} };
  cache.set(filename, module);
  module.exports = run(filename, readSource(filename), name => {
    if (name === '@ohos/hypium') return hypium;
    if (name === 'generated') return load(path.join(root, 'common/generated/Index.ets'));
    if (name.startsWith('generated/')) { // generated/ets/DebugOnly 只在 release / staging 源码集里，按 Release 取。
      const rest = name.slice('generated/'.length) + '.ets';
      const hit = ['src/main', 'src/release'].map(d => path.join(root, 'common/generated', d, rest)).find(f => fs.existsSync(f));
      if (!hit) throw new Error('MISSING_SOURCE generated ' + name);
      return load(hit);
    }
    if (name.startsWith('@kit.') || name.startsWith('@ohos.')) return {};
    if (!name.startsWith('.')) throw new Error('Unsupported dependency: ' + name);
    const target = path.resolve(path.dirname(filename), name);
    if (target === path.join(DS, 'Index')) return loadIndex();
    return load(target.endsWith('.ets') ? target : target + '.ets');
  });
  cache.get(filename).exports = module.exports;
  return module.exports;
}

function finish(failures) {
  const failed = failures > 0;
  console.log('ICONSYMBOL logic: ' + (tests.length - failures) + '/' + tests.length + ' passed; root=' + root + (swaps.size ? '; swaps=' + swaps.size : ''));
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
    console.log('FAIL[' + kind + '] ' + test.name + ': ' + detail.slice(0, 300));
  }
}
finish(failures);
