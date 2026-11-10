#!/usr/bin/env node
// HM-L2-CARD-harmony 测试作者 v1：没有 hvigor 时用 node 执行真实的 common/designsystem/src/test/L2Card.test.ets（照 tools/ci/feelkit/run-logic.cjs）。
// 被测：Index.ets 是否从 ./src/main/ets/components/CouliCard 导出 CouliCardKind，以及 CouliCard.ets 里 CouliCardKind 的真实取值。
// CouliCard.ets 含 @ComponentV2 struct，node 跑不了整文件：这里用 SDK ohos-typescript 解析，只取出其中的 enum 声明原文转译执行
// （取值即源码本身，不另写一份）；Index 只认 export { … } from '<CouliCard 模块>' 里列出的名字，没导出就拿不到（用例红）。
// 用法：
//   node tools/ci/l2card/run-logic.cjs                            真实产品（任一用例失败退出 1）
//   node tools/ci/l2card/run-logic.cjs --root <树>                换一棵树取产品文件（先红副本、桩、参照件 fixtures/good）；套件仍取本仓库
//   node tools/ci/l2card/run-logic.cjs --swap <相对路径> <文件>    把某个产品文件换成 <文件>（变异体用，可多次）
//   node tools/ci/l2card/run-logic.cjs --expect-red               退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
    'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

const REPO = path.resolve(__dirname, '../../..');
const args = process.argv.slice(2);
const rootIndex = args.indexOf('--root');
const root = rootIndex >= 0 ? path.resolve(args[rootIndex + 1]) : REPO;
const swaps = new Map();
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--swap') { swaps.set(args[i + 1], path.resolve(args[i + 2])); i += 2; }
}
const expectRed = args.includes('--expect-red');
const SUITE = path.join(REPO, 'common/designsystem/src/test/L2Card.test.ets');
const INDEX = 'common/designsystem/Index.ets';
const CARD = 'common/designsystem/src/main/ets/components/CouliCard.ets';
const CARD_MODULE = './src/main/ets/components/CouliCard';

function source(rel) {
  const file = swaps.has(rel) ? swaps.get(rel) : path.join(root, rel);
  if (!fs.existsSync(file)) { return null; }
  return fs.readFileSync(file, 'utf8');
}
const LOADER = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader');
const ETS_OPTIONS = { ets: ts.readConfigFile(path.join(LOADER, 'tsconfig.json'), ts.sys.readFile).config.compilerOptions.ets };
function parseEts(rel, text) {
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, ETS_OPTIONS);
  if (sf.parseDiagnostics.length) {
    throw new Error('PARSE ' + rel + ': ' + ts.flattenDiagnosticMessageText(sf.parseDiagnostics[0].messageText, ' '));
  }
  return sf;
}

/** Index.ets 从 CouliCard 模块导出的名字。 */
function indexNames() {
  const text = source(INDEX);
  if (text === null) { return new Set(); }
  const names = new Set();
  ts.forEachChild(parseEts(INDEX, text), (n) => {
    if (ts.isExportDeclaration(n) && n.moduleSpecifier && ts.isStringLiteral(n.moduleSpecifier) &&
        n.moduleSpecifier.text === CARD_MODULE && n.exportClause && ts.isNamedExports(n.exportClause)) {
      for (const e of n.exportClause.elements) {
        if (!e.propertyName) { names.add(e.name.text); }
      }
    }
  });
  return names;
}

/** CouliCard.ets 里导出的 enum，按源码原文转译执行。 */
function cardEnums() {
  const text = source(CARD);
  if (text === null) { return {}; }
  const pieces = [];
  ts.forEachChild(parseEts(CARD, text), (n) => {
    if (ts.isEnumDeclaration(n) && (n.modifiers || []).some((m) => m.kind === ts.SyntaxKind.ExportKeyword)) { pieces.push(n.getText()); }
  });
  const js = ts.transpileModule(pieces.join('\n'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  new vm.Script('(function(module,exports){\n' + js + '\n})', { filename: CARD }).runInThisContext()(module, module.exports);
  return module.exports;
}

function indexShim() {
  const names = indexNames();
  const enums = cardEnums();
  const out = {};
  for (const name of names) { if (name in enums) { out[name] = enums[name]; } }
  return out;
}

const tests = [];
const hypium = {
  describe: (_name, fn) => fn(),
  it: (name, _flags, fn) => tests.push({ name, fn }),
  expect: (value) => ({
    assertEqual: (expected) => assert.strictEqual(value, expected),
    assertTrue: () => assert.strictEqual(value, true),
    assertFalse: () => assert.strictEqual(value, false),
  }),
};

let results = [];
try {
  const shim = indexShim();
  const js = ts.transpileModule(fs.readFileSync(SUITE, 'utf8'), { fileName: 'L2Card.test.ts',
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  const localRequire = (name) => {
    if (name === '@ohos/hypium') { return hypium; }
    if (name === '../../Index') { return shim; }
    throw new Error('Unsupported dependency: ' + name);
  };
  new vm.Script('(function(require,module,exports){\n' + js + '\n})', { filename: SUITE }).runInThisContext()(localRequire, module, module.exports);
  module.exports.default();
  for (const t of tests) {
    try {
      t.fn();
      results.push(true);
      console.log('PASS ' + t.name);
    } catch (e) {
      results.push(false);
      const kind = e instanceof assert.AssertionError ? 'ASSERT' : 'THROW';
      console.log('FAIL[' + kind + '] ' + t.name + ': ' + (e instanceof assert.AssertionError
        ? JSON.stringify(e.actual) + ' != ' + JSON.stringify(e.expected) : String(e && e.message)));
    }
  }
} catch (e) {
  console.log('FAIL[LOAD] ' + String(e && e.message));
  results = [false];
}
const passed = results.filter((x) => x).length;
const red = results.length === 0 || passed !== results.length;
console.log('L2CARD_LOGIC ' + passed + '/' + results.length + ' root=' + root + (swaps.size ? ' swaps=' + [...swaps.keys()].join(',') : ''));
process.exitCode = expectRed ? (red ? 0 : 1) : (red ? 1 : 0);
