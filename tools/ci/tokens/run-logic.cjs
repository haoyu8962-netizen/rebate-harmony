#!/usr/bin/env node
// TOKENS-PIPE-harmony 测试作者 v1：没有 hvigor 时用 node 执行
//   ① common/generated/src/test/TokensPipe.test.ets（DesignTokens 对锁定快照逐叶；verify 里 hvigor 在 generated 本机单测中真跑同一份）；
//   ② common/designsystem/src/test/TokensPipeTheme.test.ets（CouliColorMode.hex / resolveColorTokens / resolveShadowTokens /
//      CouliComponentMetrics；hvigor 在 designsystem 本机单测中真跑同一份）；
//   ③ 设备测试 entry/src/ohosTest/ets/test/Ds02ResourcesDevice.test.ets 的离线演练（REFERENCE_ONLY，不算设备通过）：资源管理器换成
//      「读本仓库 resources/base|dark 的 color.json」，语义 getter / couliColorResource 用真实 CouliColors.ets，三个用例照原样执行，
//      证明按键比对的写法在当前资源上能过、能拦。真机取色仍以 entry 设备步为准（重启后跑）。
// 被测对象都是真实产品源码（'generated' 按真实 common/generated 载入）。
// 用法：
//   node tools/ci/tokens/run-logic.cjs                              真实产品
//   node tools/ci/tokens/run-logic.cjs --self-test                  合成参照件（v0.5.1 形状的最小快照 + 参照实现）全过、错误实现全红
//   node tools/ci/tokens/run-logic.cjs --swap <相对路径> <文件>        把某个源码 / 资源换成 <文件>（变异体用）
//   node tools/ci/tokens/run-logic.cjs --expect-red                 退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）或设备执行。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

const P = rel => path.join(root, rel);
const GEN_SUITE = P('common/generated/src/test/TokensPipe.test.ets');
const DS_SUITE = P('common/designsystem/src/test/TokensPipeTheme.test.ets');
const DEVICE_SUITE = P('entry/src/ohosTest/ets/test/Ds02ResourcesDevice.test.ets');
const GEN_INDEX = P('common/generated/Index.ets');
const SNAPSHOT_DATA = P('common/generated/src/test/ContractSnapshotData.ets');
const COLOR_MODE = P('common/designsystem/src/main/ets/components/ColorMode.ets');
const MAPPING = P('common/designsystem/src/main/ets/theme/CouliThemeMapping.ets');
const METRICS = P('common/designsystem/src/main/ets/CouliMetrics.ets');
const COLORS = P('common/designsystem/src/main/ets/CouliColors.ets');
const RES = mode => [P('common/designsystem/src/main/resources/' + mode + '/element/color.json'),
  P('entry/src/main/resources/' + mode + '/element/color.json')];

const args = process.argv.slice(2);
const swaps = new Map();
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--swap') { swaps.set(path.join(root, args[i + 1]), path.resolve(args[i + 2])); i += 2; }
}
const expectRed = args.includes('--expect-red');
const readSource = filename => fs.readFileSync(swaps.has(filename) ? swaps.get(filename) : filename, 'utf8');

function hypiumFor(tests, hooks) {
  return {
    describe: (_name, fn) => fn(),
    it: (name, _flags, fn) => tests.push({ name, fn }),
    afterAll: fn => hooks.push(fn),
    expect: value => ({
      assertEqual: expected => assert.strictEqual(value, expected),
      assertTrue: () => assert.strictEqual(value, true),
      assertFalse: () => assert.strictEqual(value, false),
    }),
  };
}

// 设备演练用的资源管理器：颜色模式 → 本仓库 color.json（designsystem + entry）的同名值。
function deviceKit(state) {
  const parse = value => Number.parseInt(value.length === 7 ? 'FF' + value.slice(1) : value.slice(1), 16) >>> 0;
  const table = mode => {
    const map = new Map();
    for (const file of RES(mode)) {
      for (const row of JSON.parse(readSource(file)).color) map.set(row.name, parse(row.value));
    }
    return map;
  };
  const delegator = { getAppContext: () => ({
    resourceManager: {
      getColorByNameSync: name => {
        const value = table(state.dark ? 'dark' : 'base').get(name);
        if (value === undefined) throw new Error('9001003 resource name not found: ' + name);
        return value;
      },
      getColorSync: () => { throw new Error('9001001 by-id lookup not expected in node rehearsal'); },
    },
    getApplicationContext: () => ({ setColorMode: mode => { state.dark = mode === 0; } }),
  }) };
  return {
    '@kit.TestKit': { abilityDelegatorRegistry: { getAbilityDelegator: () => delegator },
      Driver: { create: () => ({ waitForIdle: async () => true }) } },
    '@kit.AbilityKit': { ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1 } } },
  };
}

function loader(hypium, overrides, kits) {
  const cache = new Map();
  function load(filename) {
    if (overrides.has(filename)) return overrides.get(filename);
    if (cache.has(filename)) return cache.get(filename).exports;
    const source = swaps.has(filename) ? swaps.get(filename) : filename;
    if (!fs.existsSync(source)) throw new Error('MISSING_SOURCE ' + path.relative(root, filename));
    const result = ts.transpileModule(readSource(filename), { fileName: filename.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
    const module = { exports: {} };
    cache.set(filename, module);
    function localRequire(name) {
      if (name === '@ohos/hypium') return hypium;
      if (kits[name]) return kits[name];
      if (name === '@kit.ArkUI') return {
        LengthMetrics: { vp: value => ({ value, unit: 1 }) },
        ColorMetrics: { numeric: value => ({ argb: value >>> 0 }) },
        ThemeControl: { setDefaultTheme: () => {} },
      };
      if (name.startsWith('@kit.') || name.startsWith('@ohos.')) return {};
      if (name === 'generated' || (name === '../../Index' && filename.startsWith(P('common/generated/')))) return load(GEN_INDEX);
      if (name === 'generated/ets/DebugOnly') return load(P('common/generated/src/release/ets/DebugOnly.ets'));
      if (name === 'designsystem') return load(COLORS);
      if (!name.startsWith('.')) throw new Error('Unsupported dependency: ' + name);
      return load(path.resolve(path.dirname(filename), name.endsWith('.ets') ? name : name + '.ets'));
    }
    new vm.Script('(function(require,module,exports,$r,ObservedV2,Trace){\n' + result.outputText + '\n})', { filename })
      .runInThisContext()(localRequire, module, module.exports, n => ({ id: -1, params: [n] }), v => v, () => {});
    return module.exports;
  }
  return load;
}

async function run(overrides = new Map(), options = {}) {
  const failures = [];
  let total = 0;
  const groups = [[GEN_SUITE, {}], [DS_SUITE, {}]];
  if (!options.skipDevice) groups.push([DEVICE_SUITE, 'device']);
  for (const [suite, kind] of groups) {
    const tests = [];
    const hooks = [];
    const state = { dark: false };
    const kits = kind === 'device' ? deviceKit(state) : {};
    try {
      loader(hypiumFor(tests, hooks), overrides, kits)(suite).default();
    } catch (error) {
      failures.push(path.basename(suite) + ' load: ' + String(error.message).split('\n')[0]);
      continue;
    }
    for (const test of tests) {
      total++;
      try { await test.fn(); } catch (error) {
        failures.push(path.basename(suite) + ' ' + test.name + ': ' + String(error.message).replace(/\s+/g, ' ').slice(0, 260));
      }
    }
    for (const hook of hooks) hook();
  }
  return { total, failures };
}

// ---------------------------------------------------------------- 自测：v0.5.1 形状的合成快照 + 参照实现（REFERENCE_ONLY）

function referenceFixture() {
  const color = (value, dark) => ({ type: 'color', value, dark });
  const dim = value => ({ type: 'dimension', value });
  const component = {};
  for (const [key, value] of [['button.min-height', 48], ['button.padding-inline', 20], ['button.padding-block', 12], ['button.gap', 8],
    ['control.min-height', 44], ['control.border-width', 1], ['icon.default', 24], ['icon.small', 14], ['icon.inline', 16],
    ['icon.medium', 20], ['field.min-height', 52], ['code-cell.height', 56], ['checkbox.size', 18], ['checkbox.max-scale', 1.5],
    ['chip.height', 32], ['tab-indicator.height', 2], ['tag.min-height', 22], ['platform-badge.min-height', 20],
    ['count-badge.size', 18], ['image.list', 96], ['grid-cell.min-height', 72], ['oauth.size', 48], ['oauth.gap', 32]]) {
    const [group, leaf] = key.split('.');
    component[group] = component[group] || {};
    component[group][leaf] = { type: key === 'checkbox.max-scale' ? 'number' : 'dimension', value };
  }
  const layer = (y, blur, color, opacity) => ({ x: 0, y, blur, spread: 0, color, opacity });
  return { metadata: { version: '0.5.1' }, tokens: {
    color: { text: { primary: color('#28251F', '#F2EEE6') }, background: { canvas: color('#F2EEE6', '#171513') },
      brand: { primary: color('#C44820', '#C44820') }, status: { error: { text: color('#B42345', '#F28DA4') } },
      platform: { tag: { taobao: color('#D53D00', '#D53D00') } },
      overlay: { scrim: color('#28251F66', '#0000008C'), 'on-image': color('#0000008C', '#0000008C') } },
    font: { size: { body: { type: 'fontSize', value: 17 } }, 'line-height': { body: { type: 'lineHeight', value: 25.5 } },
      weight: { bold: { type: 'fontWeight', value: 700 } } },
    space: { 0: dim(0), 4: dim(16) }, radius: { tag: dim(4), avatar: dim(10), card: dim(16) },
    shadow: { none: { type: 'shadow', value: [] },
      card: { type: 'shadow', value: [layer(2, 8, '#28251F', 0.06)], dark: [layer(2, 8, '#000000', 0.3)] } },
    focus: { width: dim(2), offset: dim(2) }, interaction: { target: { harmony: dim(48) } }, component,
  } };
}

function leavesOf(node, prefix = '', out = new Map()) {
  for (const [key, child] of Object.entries(node)) {
    const p = prefix ? prefix + '.' + key : key;
    if (child.type !== undefined) out.set(p, child); else leavesOf(child, p, out);
  }
  return out;
}

const argbOf = css => { const v = css.toUpperCase(); return v.length === 9 ? '#' + v.slice(7, 9) + v.slice(1, 7) : v; };

function reference(mutation = '') {
  const snap = referenceFixture();
  const t = snap.tokens;
  class ShadowLayerToken { constructor(x, y, blur, spread, color, opacity) { Object.assign(this, { x, y, blur, spread, color, opacity }); } }
  const layers = list => list.map(l => new ShadowLayerToken(l.x, l.y, l.blur, l.spread, l.color, l.opacity));
  const colors = new Map([...leavesOf(t.color)].map(([k, l]) => [k, mutation === 'design-argb' ? argbOf(l.value) : l.value]));
  const colorsDark = new Map([...leavesOf(t.color)].map(([k, l]) => [k, mutation === 'dark-fallback' && k === 'text.primary' ? l.value : l.dark]));
  const numbers = node => new Map([...leavesOf(node)].map(([k, l]) => [k, l.value]));
  const component = numbers(t.component);
  if (mutation === 'component-int') component.set('checkbox.max-scale', 1);
  const radius = numbers(t.radius);
  if (mutation === 'radius-missing-tag') radius.delete('tag');
  const DesignTokens = {
    version: mutation === 'version' ? '0.5.0' : '0.5.1', colors, colorsDark, spacing: numbers(t.space), radius,
    fontSize: numbers(t.font.size), lineHeight: numbers(t.font['line-height']), fontWeight: numbers(t.font.weight),
    touchTarget: numbers(t.interaction.target), focus: numbers(t.focus), component,
    shadows: new Map(Object.entries(t.shadow).map(([k, l]) => [k, layers(l.value)])),
    shadowsDark: new Map(Object.entries(t.shadow).map(([k, l]) => [k, layers(mutation === 'shadow-dark-light' ? l.value : (l.dark || l.value))])),
  };
  if (mutation === 'no-colors-dark') delete DesignTokens.colorsDark;
  const hex = (key, dark) => {
    const css = (dark ? colorsDark : colors).get(key);
    if (css === undefined) throw new Error('missing color token: ' + key);
    if (mutation === 'hex-css') return css;
    if (mutation === 'hex-double-swap') return argbOf(argbOf(css));
    return argbOf(css);
  };
  const metrics = {};
  const names = { 'button.min-height': 'buttonMinHeight', 'button.padding-inline': 'buttonPaddingInline',
    'button.padding-block': 'buttonPaddingBlock', 'button.gap': 'buttonGap', 'control.border-width': 'controlBorderWidth',
    'icon.default': 'iconDefault', 'icon.small': 'iconSmall', 'icon.inline': 'iconInline', 'icon.medium': 'iconMedium',
    'field.min-height': 'fieldMinHeight', 'code-cell.height': 'codeCellHeight', 'checkbox.size': 'checkboxSize',
    'checkbox.max-scale': 'checkboxMaxScale', 'chip.height': 'chipHeight', 'tab-indicator.height': 'tabIndicatorHeight',
    'tag.min-height': 'tagMinHeight', 'platform-badge.min-height': 'platformBadgeMinHeight', 'count-badge.size': 'countBadgeSize',
    'image.list': 'imageList', 'grid-cell.min-height': 'gridCellMinHeight', 'oauth.size': 'oauthSize', 'oauth.gap': 'oauthGap' };
  for (const [key, name] of Object.entries(names)) metrics[name] = component.get(key);
  if (mutation === 'metrics-truncated') metrics.checkboxMaxScale = 1;
  metrics.focusWidth = DesignTokens.focus.get('width');
  metrics.focusOffset = DesignTokens.focus.get('offset');
  const overrides = new Map();
  overrides.set(GEN_INDEX, { DesignTokens, ShadowLayerToken });
  overrides.set(SNAPSHOT_DATA, { SNAPSHOT_JSON: new Map([['design/design-tokens.json', JSON.stringify(snap)]]) });
  overrides.set(COLOR_MODE, { CouliColorMode: { hex } });
  overrides.set(MAPPING, {
    resolveColorTokens: dark => {
      const map = new Map([...colors.keys()].map(k => [k, hex(k, dark)]));
      if (mutation === 'resolve-missing-key') map.delete('overlay.on-image');
      return map;
    },
    resolveShadowTokens: dark => new Map(DesignTokens[dark ? 'shadowsDark' : 'shadows']),
  });
  overrides.set(METRICS, { CouliComponentMetrics: metrics });
  return overrides;
}

const MUTANTS = ['design-argb', 'dark-fallback', 'no-colors-dark', 'component-int', 'radius-missing-tag', 'version', 'shadow-dark-light',
  'hex-css', 'hex-double-swap', 'resolve-missing-key', 'metrics-truncated'];

async function selfTest() {
  const legal = await run(reference(), { skipDevice: true });
  assert.equal(legal.failures.length, 0, 'REFERENCE legal must pass: ' + legal.failures.join(' | '));
  assert.ok(legal.total >= 10, 'suites registered too few tests: ' + legal.total);
  console.log('REFERENCE_ONLY legal: ' + legal.total + ' tests passed');
  for (const mutation of MUTANTS) {
    const result = await run(reference(mutation), { skipDevice: true });
    assert.ok(result.failures.length > 0, 'mutant survived: ' + mutation);
    console.log('REFERENCE_ONLY mutant killed ' + mutation + ': ' + result.failures[0].slice(0, 150));
  }
  console.log('TOKENS_LOGIC --self-test: legal pass, ' + MUTANTS.length + ' mutants killed (REFERENCE_ONLY, not product pass)');
}

async function main() {
  if (args.includes('--self-test')) {
    await selfTest();
    return;
  }
  const result = await run();
  for (const f of result.failures) console.log('FAIL ' + f);
  const label = swaps.size === 0 ? 'real product' : 'swapped ' + [...swaps.values()].map(p => path.basename(p)).join(',');
  console.log('TOKENS_LOGIC ' + label + ': ' + result.total + ' tests (device suite = REFERENCE_ONLY rehearsal); failures=' +
    result.failures.length);
  const red = result.failures.length > 0 || result.total === 0;
  process.exitCode = expectRed ? (red ? 0 : 1) : (red ? 1 : 0);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
