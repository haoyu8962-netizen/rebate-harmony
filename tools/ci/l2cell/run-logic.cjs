#!/usr/bin/env node
// HM-L2-PRODUCT-CELL-harmony 测试作者 v1（新鲜独立 Claude，先红）：没有 hvigor 时用 node 执行真实 .ets（SDK ohos-typescript 转译）——
//   common/designsystem/src/test/L2ProductCell.test.ets（hvigor 在 designsystem 本机单测里真跑同一份）对真实的 ProductCard（ProductCardA11y /
//   ProductCardData）/ PriceModels / ProductCardMapper 与生成的 DefaultTexts。照 tools/ci/l2button/run-logic.cjs（同一套加载器）。
// 组件文件含 ArkUI struct，node 跑不了整文件：用 SDK 解析器去掉 struct 声明，其余语句原文转译；相对 import 按需（首次取属性时）才加载。
// 用法：
//   node tools/ci/l2cell/run-logic.cjs                           真实产品（任一用例失败退出 1）
//   node tools/ci/l2cell/run-logic.cjs --root <树>               换一棵树
//   node tools/ci/l2cell/run-logic.cjs --swap <相对路径> <文件>   把某个源码换成 <文件>（参照件 / 变异体用，可多次）
//   node tools/ci/l2cell/run-logic.cjs --expect-red              退出码取反（变异体必须至少一条失败）
//   node tools/ci/l2cell/run-logic.cjs --self-test               参照件（fixtures/good 的 ProductCard.ets）全绿 + 逐个变异体至少一条红
// 现树（未实现）：c1–c4、c7 红在 ProductCardA11y.cellLabel 不存在（THROW），c5 / c6 是 BUTTON 已落行为的钉子（绿）。
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const { spawnSync } = require('child_process');
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
const SUITE = path.join(DS, 'src/test/L2ProductCell.test.ets');

const PM = 'common/designsystem/src/main/ets/format/PriceModels.ets';
const MAPPER = 'common/designsystem/src/main/ets/format/ProductCardMapper.ets';
const CARD = 'common/designsystem/src/main/ets/components/ProductCard.ets';
const GOOD = path.join(__dirname, 'fixtures', 'good');
const REAL = path.resolve(__dirname, '../../..');

// ---------------------------------------------------------------- 自测：参照件全绿、变异体逐个打红
// （名字，文件，原串，新串，基准）：基准 'good' = fixtures/good 下的参照 ProductCard；'real' = 本仓库真实文件（PriceModels / Mapper 的行为钉子）。
const MUTANTS = [
  ['cellLabel 带推广标识（照抄横滑卡）', CARD, 'return ProductCardA11y.spoken(data, null, tags);',
    "return ProductCardA11y.spoken(data, '推广', tags);", 'good'],
  ['cellLabel 拼预估返后', CARD, 'return ProductCardA11y.spoken(data, null, tags);',
    "return ProductCardA11y.spoken(data, null, tags) + (data.estNet !== null ? PriceTerms.comma + data.estNet : '');", 'good'],
  ['cellLabel 拼图片占位', CARD, 'return ProductCardA11y.spoken(data, null, tags);',
    'return data.imageLabel + PriceTerms.comma + ProductCardA11y.spoken(data, null, tags);', 'good'],
  ['cellLabel 拼购买按钮文字', CARD, 'return ProductCardA11y.spoken(data, null, tags);',
    'return ProductCardA11y.spoken(data, null, tags) + PriceTerms.comma + data.buyBase;', 'good'],
  ['cellLabel 只读平台和标题（标题组照旧）', CARD, 'return ProductCardA11y.spoken(data, null, tags);',
    'return data.platformLabel + PriceTerms.comma + data.title;', 'good'],
  ['cellLabel 金额隐藏不遮罩', CARD, "        parts.push(CardAmountMask.rebate(data.rebate, data.amountHidden).spokenText);",
    "        parts.push(data.rebate.spokenText);", 'good'],
  ['cellLabel 平台 not_launched 仍读返利', CARD, "      if (!data.rebateHidden && data.rebate.kindRaw !== 'none') {\n        parts.push(CardAmountMask",
    "      if (data.rebate.kindRaw !== 'none') {\n        parts.push(CardAmountMask", 'good'],
  // FU-HM-A11Y-AGENT（#24，D10-1248 ⑦ / S3-1）：读看得见的。
  ['cellLabel 不读优惠标签（S3-1 原状）', CARD, 'return ProductCardA11y.spoken(data, null, tags);',
    'return ProductCardA11y.spoken(data, null, []);', 'good'],
  ['cellLabel 读视觉隐藏的「暂无返利」（S3-1 原状）', CARD, "      if (!data.rebateHidden && data.rebate.kindRaw !== 'none') {",
    "      if (!data.rebateHidden) {", 'good'],
  ['cellLabel amount_unknown 读价格', CARD, "    } else if (data.rebate.kindRaw === 'unknown') {",
    "    } else if (data.rebate.kindRaw === 'unknown-x') {", 'good'],
  ['cellLabel 平台读两次', CARD, 'return ProductCardA11y.spoken(data, null, tags);',
    'return data.platformLabel + PriceTerms.comma + ProductCardA11y.spoken(data, null, tags);', 'good'],
  ['D10-871 回落只认字面 {amount}（一行句式隐藏时露金额）', PM,
    "    if (base.indexOf(AMOUNT_PLACEHOLDER) < 0 && !BuyButtonModel.namesAmount(base, rebate)) {",
    "    if (base.indexOf(AMOUNT_PLACEHOLDER) < 0) {", 'real'],
  ['一行句式又拼旧后缀', PM, "      || BuyButtonModel.namesAmount(base, rebate)) {\n      return base;",
    "      ) {\n      return base;", 'real'],
];

function selfTest() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'l2cell-logic-'));
  const failures = [];
  const run = (extra, wantRed) => {
    const swapArgs = ['--swap', CARD, extra[CARD] || path.join(GOOD, CARD)];
    for (const rel of Object.keys(extra)) { if (rel !== CARD) swapArgs.push('--swap', rel, extra[rel]); }
    return spawnSync(process.execPath, [__filename, '--root', root, ...swapArgs].concat(wantRed ? ['--expect-red'] : []),
      { encoding: 'utf8' });
  };
  try {
    const good = run({}, false);
    if (good.status !== 0) failures.push('参照件不全绿：\n' + good.stdout.split('\n').filter(l => !l.startsWith('PASS')).join('\n'));
    else console.log('REFERENCE ' + good.stdout.trim().split('\n').pop());
    MUTANTS.forEach(([name, rel, from, to, base], i) => {
      const src = base === 'good' ? path.join(GOOD, rel) : path.join(REAL, rel);
      const text = fs.readFileSync(src, 'utf8');
      const count = text.split(from).length - 1;
      if (count !== 1) { failures.push('变异「' + name + '」原串出现 ' + count + ' 次（应 1 次）'); return; }
      const file = path.join(tmp, 'm' + i + '-' + path.basename(rel));
      fs.writeFileSync(file, text.replace(from, () => to));
      const r = run({ [rel]: file }, true);
      const red = r.stdout.split('\n').filter(l => l.startsWith('FAIL') || l.startsWith('LOAD_FAIL'));
      if (r.status !== 0) failures.push('变异「' + name + '」没被杀（逻辑用例全绿）');
      else console.log('KILLED ' + name + ' ← ' + red.map(l => l.replace(/:.*$/, '')).join(', '));
    });
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  if (failures.length) {
    failures.forEach(f => console.log('SELFTEST FAIL: ' + f));
    console.log('L2CELL_LOGIC_SELFTEST 失败 ' + failures.length + ' / ' + (MUTANTS.length + 1));
    process.exitCode = 1;
  } else {
    console.log('L2CELL_LOGIC_SELFTEST 通过：参照件全绿 + 变异 ' + MUTANTS.length + ' 个全杀');
  }
}

if (args.includes('--self-test')) { selfTest(); return; }

// ---------------------------------------------------------------- 执行
const tests = [];
const hypium = {
  describe: (_name, fn) => fn(),
  it: (name, _flags, fn) => tests.push({ name, fn }),
  expect: value => ({
    assertEqual: expected => assert.strictEqual(value, expected),
    assertTrue: () => assert.strictEqual(value, true),
    assertFalse: () => assert.strictEqual(value, false),
    assertNull: () => assert.strictEqual(value, null),
  }),
};
const noop = () => undefined;
for (const name of ['ObservedV2', 'Trace', 'Observed', 'Track', 'Local', 'Param', 'Once', 'Event', 'Provider', 'Consumer',
  'Monitor', 'Computed', 'Builder', 'BuilderParam', 'Component', 'ComponentV2', 'Entry', 'Concurrent', 'Sendable']) {
  if (global[name] === undefined) global[name] = noop;
}
const kitStub = new Proxy({}, { get: (_t, key) => key === '__esModule' ? false : (key === 'hilog'
  ? { warn: noop, info: noop, error: noop, debug: noop, fatal: noop, isLoggable: () => false } : undefined) });

const readSource = filename => fs.readFileSync(swaps.has(filename) ? swaps.get(filename) : filename, 'utf8');

function compile(filename) {
  const text = readSource(filename);
  let source = text;
  if (filename.endsWith('.ets')) {
    const tree = ts.createSourceFile(filename, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options);
    if (tree.parseDiagnostics.length) {
      throw new Error('PARSE_FAIL ' + path.relative(root, filename) + ': ' +
        ts.flattenDiagnosticMessageText(tree.parseDiagnostics[0].messageText, ' '));
    }
    source = tree.statements.filter(s => !(ts.isStructDeclaration && ts.isStructDeclaration(s))).map(s => s.getText()).join('\n');
  }
  return ts.transpileModule(source, { fileName: filename.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true } }).outputText;
}

const cache = new Map();
function load(filename) {
  if (cache.has(filename)) return cache.get(filename).exports;
  if (!fs.existsSync(swaps.has(filename) ? swaps.get(filename) : filename)) throw new Error('MISSING_SOURCE ' + path.relative(root, filename));
  const module = { exports: {} };
  cache.set(filename, module);
  new vm.Script('(function(require,module,exports){\n' + compile(filename) + '\n})', { filename })
    .runInThisContext()(name => resolve(filename, name), module, module.exports);
  return module.exports;
}

/** 相对 import 按需加载：首次取属性时才执行该文件（只被 struct 用到的界面依赖不执行）。 */
function lazy(filename) {
  let real = null;
  const get = () => (real === null ? (real = load(filename)) : real);
  return new Proxy({}, {
    get: (_t, key) => (key === '__esModule' ? true : get()[key]),
    has: (_t, key) => key in get(),
  });
}

function resolve(from, name) {
  if (name === '@ohos/hypium') return hypium;
  if (name === 'generated') return lazy(path.join(root, 'common/generated/Index.ets'));
  if (name.startsWith('generated/')) {
    const rest = name.slice('generated/'.length) + '.ets';
    const hit = ['src/main', 'src/release'].map(d => path.join(root, 'common/generated', d, rest)).find(f => fs.existsSync(f));
    if (!hit) throw new Error('MISSING_SOURCE generated ' + name);
    return lazy(hit);
  }
  if (name.startsWith('@kit.') || name.startsWith('@ohos.') || name.startsWith('@hms.')) return kitStub;
  if (!name.startsWith('.')) throw new Error('Unsupported dependency: ' + name);
  const target = path.resolve(path.dirname(from), name);
  return lazy(target.endsWith('.ets') ? target : target + '.ets');
}

try {
  load(SUITE).default();
} catch (e) {
  console.log('LOAD_FAIL ' + (e && e.message));
  process.exitCode = expectRed ? 0 : 1;
  process.exit();
}
if (tests.length === 0) { console.log('LOAD_FAIL no tests registered'); process.exitCode = expectRed ? 0 : 1; process.exit(); }
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
console.log('L2CELL logic: ' + (tests.length - failures) + '/' + tests.length + ' passed; root=' + root + (swaps.size ? '; swaps=' + swaps.size : ''));
process.exitCode = expectRed ? (failures > 0 ? 0 : 1) : (failures > 0 ? 1 : 0);
