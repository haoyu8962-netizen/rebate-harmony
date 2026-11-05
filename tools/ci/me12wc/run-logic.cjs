#!/usr/bin/env node
// APP-12w-c-harmony 测试作者 v1：没有 hvigor 时用 node 执行
//   ① core 套件 common/core/src/test/Me12wcRisk.test.ets（verify 里 hvigor 在 core 全量单测中真跑同一份）。被测对象是真实产品源码
//      （MePresentation / MeJson / MeDraftTexts / account/AccountDraftTexts / wallet/WalletDraftTexts / wallet/WalletPresentation，以及它们相对
//      引用的源码；'generated' 按真实 common/generated 源码载入）；
//   ② 私有件 features/me/src/main/ets/RiskAppealParts.ets 的五个纯函数取值表（§3.2「胶囊色映射只读 riskState，单独一个纯函数，宿主检查断言它
//      的取值表」；R4 / R12 / R17 / R24）：从源码抽出 `export function <名>(…) {…}`，用 SDK typescript 转写后在 node 里执行（DS 枚举按
//      common/designsystem 真实取值注入），逐项断言。实现前私有件不存在 → 这一组红（先红）。
// 用法：
//   node tools/ci/me12wc/run-logic.cjs                      真实产品
//   node tools/ci/me12wc/run-logic.cjs --swap <相对路径> <文件>   把产品里某个源码换成 <文件>（变异体，只证明测试有牙齿）
//   node tools/ci/me12wc/run-logic.cjs --expect-red         退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const coreDir = path.join(root, 'common/core/src/main/ets');
const indexParts = ['me/MePresentation.ets', 'me/MeJson.ets', 'me/MeDraftTexts.ets', 'me/account/AccountDraftTexts.ets',
  'wallet/WalletDraftTexts.ets', 'wallet/WalletPresentation.ets'].map(p => path.join(coreDir, p));
const generatedIndex = path.join(root, 'common/generated/Index.ets');
const suites = ['common/core/src/test/Me12wcRisk.test.ets'].map(p => path.join(root, p));
const partsFile = path.join(root, 'features/me/src/main/ets/RiskAppealParts.ets');
const basicsFile = path.join(root, 'common/designsystem/src/main/ets/components/Basics.ets');
const args = process.argv.slice(2);
const swaps = new Map();
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--swap') {
    swaps.set(path.join(root, args[i + 1]), path.resolve(args[i + 2]));
    i += 2;
  }
}
const expectRed = args.includes('--expect-red');
const sourceOf = filename => fs.readFileSync(swaps.has(filename) ? swaps.get(filename) : filename, 'utf8');

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

/** DS 枚举（CouliChipTone / CouliButtonVariant）的真实取值：从 Basics.ets 的 `export enum X { A = 'a', … }` 抽出。 */
function dsEnum(name) {
  const text = sourceOf(basicsFile);
  const m = text.match(new RegExp('export enum ' + name + '\\s*\\{([\\s\\S]*?)\\n\\}'));
  if (!m) throw new Error('DS 枚举缺失 ' + name);
  const out = {};
  for (const e of m[1].matchAll(/^\s*([A-Z_]+)\s*=\s*'([a-z_]+)'/gm)) out[e[1]] = e[2];
  return out;
}

/** 从私有件源码抽出 export function（大括号配对，跳过字符串），转写后执行，返回 {名: 函数}。 */
function partsFunctions(names) {
  if (!fs.existsSync(swaps.has(partsFile) ? swaps.get(partsFile) : partsFile)) {
    throw new Error('MISSING_SOURCE features/me/src/main/ets/RiskAppealParts.ets（H-R01 私有件，实现前预期缺）');
  }
  const text = sourceOf(partsFile);
  const chunks = [];
  for (const name of names) {
    const m = new RegExp('^export\\s+function\\s+' + name + '\\s*\\(', 'm').exec(text);
    if (!m) throw new Error('RiskAppealParts 缺 export function ' + name);
    let i = text.indexOf('{', text.indexOf(')', m.index));
    let depth = 0;
    let quote = null;
    const start = m.index;
    for (; i < text.length; i++) {
      const c = text[i];
      if (quote) {
        if (c === '\\') { i++; continue; }
        if (c === quote) quote = null;
      } else if (c === '\'' || c === '"' || c === '`') quote = c;
      else if (c === '{') depth++;
      else if (c === '}' && --depth === 0) break;
    }
    chunks.push(text.slice(start, i + 1).replace(/^export\s+/, ''));
  }
  const out = ts.transpileModule(chunks.join('\n') + '\nmodule.exports = { ' + names.join(', ') + ' };',
    { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const module = { exports: {} };
  new vm.Script('(function(module,CouliChipTone,CouliButtonVariant){\n' + out + '\n})', { filename: 'RiskAppealParts.functions' })
    .runInThisContext()(module, dsEnum('CouliChipTone'), dsEnum('CouliButtonVariant'));
  return module.exports;
}

function partsTests(tests) {
  const names = ['appealStateChipTone', 'appealStateChipIcon', 'riskRowChipTone', 'riskRowChipIcon', 'timelineStates'];
  tests.push({ name: 'me12wc_parts_chip_tone_icon_tables_only_by_risk_state_and_row_id', fn: () => {
    const f = partsFunctions(names);
    const tone = dsEnum('CouliChipTone');
    // R12 / R24：banned → ERROR + alert；frozen → WARNING + alert；其余（appealing / normal / 取不到）→ MUTED 无图标。只按本次 riskState。
    const want = [['banned', tone.ERROR, 'alert'], ['frozen', tone.WARNING, 'alert'], ['appealing', tone.MUTED, ''],
      ['normal', tone.MUTED, ''], [null, tone.MUTED, ''], ['visual_unlisted', tone.MUTED, '']];
    for (const [state, t, icon] of want) {
      assert.strictEqual(f.appealStateChipTone(state), t, 'appealStateChipTone(' + state + ')');
      assert.strictEqual(f.appealStateChipIcon(state), icon, 'appealStateChipIcon(' + state + ')');
    }
    // R4：按行 id 选件——risk_appeal → MUTED（status.pending）+ clock；risk_upheld → WARNING + alert；其余行不是胶囊（null / 空串）。
    const rows = [['risk_appeal', tone.MUTED, 'clock'], ['risk_upheld', tone.WARNING, 'alert'], ['risk_reason', null, ''],
      ['risk_limit', null, ''], ['risk_frozen_until', null, ''], ['risk_withdrawal_wd-visual-1', null, '']];
    for (const [id, t, icon] of rows) {
      assert.strictEqual(f.riskRowChipTone(id), t, 'riskRowChipTone(' + id + ')');
      assert.strictEqual(f.riskRowChipIcon(id), icon, 'riskRowChipIcon(' + id + ')');
    }
  } });
  tests.push({ name: 'me12wc_parts_timeline_states_by_layout_only', fn: () => {
    const f = partsFunctions(names);
    // R17 / R23：处理中 = 已提交 ✓ / 处理中（当前）/ 结果（未到）；维持 = ✓ ✓ ⚠。步态只由版式决定。
    assert.deepStrictEqual(Array.from(f.timelineStates(false)), ['done', 'current', 'pending']);
    assert.deepStrictEqual(Array.from(f.timelineStates(true)), ['done', 'done', 'warning']);
  } });
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
  partsTests(tests);
  for (const test of tests) {
    try {
      await test.fn();
    } catch (error) {
      failures.push(test.name + ': ' + String(error.message).replace(/\s+/g, ' ').slice(0, 300));
    }
  }
  for (const f of failures) console.log('FAIL ' + f);
  const label = swaps.size === 0 ? 'real product' : 'swapped ' + [...swaps.values()].map(p => path.basename(p)).join(',');
  console.log('ME12WC_LOGIC ' + label + ': ' + tests.length + ' tests; failures=' + failures.length);
  const red = failures.length > 0 || tests.length === 0;
  process.exitCode = expectRed ? (red ? 0 : 1) : (red ? 1 : 0);
}

main();
