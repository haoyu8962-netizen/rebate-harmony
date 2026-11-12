#!/usr/bin/env node
// FU-HM-A11Y-COMMON-harmony 测试作者 v1：没有 hvigor 时用 node 执行真实 .ets（SDK ohos-typescript 转译）——
//   common/core/src/test/A11yCommon.test.ets（hvigor 在 core 本机单测里真跑同一份，登记走 #24）对真实的 core OrderDraftTexts.ets。
// 写法照 tools/ci/l2button/run-logic.cjs：struct 声明去掉、相对 import 按需（首次取属性时）加载、@kit.* 空桩、装饰器空实现。
// 用法：
//   node tools/ci/a11ycommon/run-logic.cjs                           真实产品（任一用例失败退出 1）
//   node tools/ci/a11ycommon/run-logic.cjs --root <树>               换一棵树
//   node tools/ci/a11ycommon/run-logic.cjs --swap <相对路径> <文件>   把某个源码换成 <文件>（参照件 / 变异体用，可多次）
//   node tools/ci/a11ycommon/run-logic.cjs --expect-red              退出码取反（变异体必须至少一条失败）
//   node tools/ci/a11ycommon/run-logic.cjs --self-test               参照件（fixtures/good 的 OrderDraftTexts.ets，即参照实现）全绿 + 逐个变异体至少一条红
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
const SUITE = path.join(root, 'common/core/src/test/A11yCommon.test.ets');
const FLOW = 'common/core/src/main/ets/orders/OrderDraftTexts.ets';
const GOOD = path.join(__dirname, 'fixtures', 'good');

// （名字，原串，新串）：原串在参照件里必须唯一。
const COPY_LINE = "    m.set('order_list.copy_spoken', '复制订单号 {no}');";
const MUTANTS = [
  ['草稿值回「复制订单号」（不带单号）', COPY_LINE, "    m.set('order_list.copy_spoken', '复制订单号');"],
  ['占位名拼错 {num}', COPY_LINE, "    m.set('order_list.copy_spoken', '复制订单号 {num}');"],
  ['单号前少空格', COPY_LINE, "    m.set('order_list.copy_spoken', '复制订单号{no}');"],
  ['单号放前面', COPY_LINE, "    m.set('order_list.copy_spoken', '{no} 复制订单号');"],
  ['只读「复制」+ 单号', COPY_LINE, "    m.set('order_list.copy_spoken', '复制 {no}');"],
  ['单号读两遍', COPY_LINE, "    m.set('order_list.copy_spoken', '复制订单号 {no}，{no}');"],
  ['草稿表没有 copy_label（仍是旧键 order_list.copy）', "    m.set('order_list.copy_label', '复制');", "    m.set('order_list.copy', '复制');"],
  ['copy_label 文字不是「复制」', "    m.set('order_list.copy_label', '复制');", "    m.set('order_list.copy_label', '复制单号');"],
  ['订单号读法改了口径（与复制名不一致）', "    m.set('order_list.order_no_spoken', '订单号 {no}');",
    "    m.set('order_list.order_no_spoken', '订单编号 {no}');"],
];

function selfTest() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'a11ycommon-logic-'));
  const failures = [];
  const run = (file, wantRed) => spawnSync(process.execPath, [__filename, '--root', root, '--swap', FLOW, file]
    .concat(wantRed ? ['--expect-red'] : []), { encoding: 'utf8' });
  try {
    const goodFile = path.join(GOOD, FLOW);
    const good = run(goodFile, false);
    if (good.status !== 0) failures.push('参照件不全绿：\n' + good.stdout.split('\n').filter(l => !l.startsWith('PASS')).join('\n'));
    else console.log('REFERENCE ' + good.stdout.trim().split('\n').pop());
    const text = fs.readFileSync(goodFile, 'utf8');
    MUTANTS.forEach(([name, from, to], i) => {
      const count = text.split(from).length - 1;
      if (count !== 1) { failures.push('变异「' + name + '」原串出现 ' + count + ' 次（应 1 次）'); return; }
      const file = path.join(tmp, 'm' + i + '-OrderDraftTexts.ets');
      fs.writeFileSync(file, text.replace(from, () => to));
      const r = run(file, true);
      const red = r.stdout.split('\n').filter(l => l.startsWith('FAIL') || l.startsWith('LOAD_FAIL'));
      if (r.status !== 0) failures.push('变异「' + name + '」没被杀（逻辑用例全绿）');
      else console.log('KILLED ' + name + ' ← ' + red.map(l => l.replace(/:.*$/, '')).join(', '));
    });
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  if (failures.length) {
    failures.forEach(f => console.log('SELFTEST FAIL: ' + f));
    console.log('A11YCOMMON_LOGIC_SELFTEST 失败 ' + failures.length + ' / ' + (MUTANTS.length + 1));
    process.exitCode = 1;
  } else {
    console.log('A11YCOMMON_LOGIC_SELFTEST 通过：参照件全绿 + 变异 ' + MUTANTS.length + ' 个全杀');
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

/** 相对 import 按需加载：首次取属性时才执行该文件。 */
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
console.log('A11YCOMMON logic: ' + (tests.length - failures) + '/' + tests.length + ' passed; root=' + root + (swaps.size ? '; swaps=' + swaps.size : ''));
process.exitCode = expectRed ? (failures > 0 ? 0 : 1) : (failures > 0 ? 1 : 0);
