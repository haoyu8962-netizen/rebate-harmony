#!/usr/bin/env node
// F-X-05a 测试 v3（评审 r1 R1-01）：没有 hvigor 时用 node 对真实源码执行剪贴板徽标图标键的纯逻辑断言
// （entry/src/ohosTest/ets/test/Fx05aClipboardBadge.ets；设备上同一份由宿主页 Fx05aFixture 的 clips 模式执行）。
// 识别链路（ClipboardCandidates / ClipboardPromptDisplay / SharePromptTexts）、文案（ClipboardDraftTexts）、取图映射
// （PlatformIconSource）一律是产品真实源码；--self-test 只替换 ClipboardBadgeIcon 为内存参考件，证明断言有牙齿（参考件绝不算产品通过）。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const logic = path.join(root, 'entry/src/ohosTest/ets/test/Fx05aClipboardBadge.ets');
const coreSuite = path.join(root, 'common/core/src/test/Fx05aClipboardBadge.test.ets');
const clipboardCore = path.join(root, 'common/core/src/main/ets/clipboard/Clipboard.ets');
const badgeIcon = path.join(root, 'common/core/src/main/ets/clipboard/ClipboardBadgeIcon.ets');
const assert = require('assert/strict');

function loader(overrides = new Map(), hypium = {}) {
  const cache = new Map();
  function load(filename) {
    if (overrides.has(filename)) return overrides.get(filename);
    if (cache.has(filename)) return cache.get(filename).exports;
    if (!fs.existsSync(filename)) throw new Error('MISSING_PRODUCTION_INTERFACE ' + path.relative(root, filename));
    const source = fs.readFileSync(filename, 'utf8');
    const result = ts.transpileModule(source, { fileName: filename.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
    const module = { exports: {} };
    cache.set(filename, module);
    function localRequire(name) {
      // 纯逻辑只需要剪贴板识别与文案；@kit.* 给空对象（url 解析器不可用时 ClipboardHostPolicy 按字面检查，规则空白 HS01）。
      if (name === '@ohos/hypium') return hypium;
      if (name.startsWith('@kit.') || name.startsWith('@ohos.')) return {};
      // core：只并入剪贴板识别与图标键派生两份源码（core/Index 是否导出 ClipboardBadgeIcon 由宿主 W5 与 ArkTS --real 守）。
      if (name === 'core' || /\/core\/Index(\.ets)?$/.test(name) || (name === '../../Index' && filename === coreSuite)) {
        return Object.assign({}, load(clipboardCore), load(badgeIcon));
      }
      // designsystem 走无资源入口 Logic.ets（同一份 PlatformIconSource，S1 守两处导出）。
      if (name === 'designsystem') return load(path.join(root, 'common/designsystem/Logic.ets'));
      if (name === 'generated') return load(path.join(root, 'common/generated/Index.ets'));
      if (name === 'generated/ets/DebugOnly') return load(path.join(root, 'common/generated/src/release/ets/DebugOnly.ets'));
      if (!name.startsWith('.')) throw new Error('Unsupported native dependency: ' + name);
      return load(path.resolve(path.dirname(filename), name.endsWith('.ets') ? name : name + '.ets'));
    }
    new vm.Script('(function(require,module,exports,$r,ObservedV2,Trace){\n' + result.outputText + '\n})', { filename })
      .runInThisContext()(localRequire, module, module.exports, name => ({ id: -1, params: [name] }), value => value, () => {});
    return module.exports;
  }
  return load;
}

function run(overrides) {
  const failures = [];
  let total = 0;
  // ① core 的 Hypium 套件（verify 里由 hvigor 在 core 4628+ 条里真跑；这里 node 执行同一份）。
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
  try {
    loader(overrides, hypium)(coreSuite).default();
  } catch (error) { failures.push('core suite load: ' + error.message.split('\n')[0]); }
  for (const test of tests) {
    total++;
    try { test.fn(); } catch (error) { failures.push('core ' + test.name + ': ' + error.message.replace(/\s+/g, ' ').slice(0, 240)); }
  }
  // ② entry 设备宿主同一份逻辑（真实文案 ClipboardDraftTexts + 真实取图映射 PlatformIconSource）。
  try {
    const exported = loader(overrides)(logic);
    total += exported.FX05A_CLIP_SAMPLES.length;
    failures.push(...exported.fx05aClipFailures().map(f => 'entry ' + f));
  } catch (error) {
    failures.push('entry logic load: ' + error.message.split('\n')[0]);
  }
  return { total, tests: tests.length, failures };
}

// 参考件与常见错误实现。good：按命中的显示名派生（也可按主机，产品任选；断言只看结果）。
function reference(mutation = '') {
  const good = info => (info.displayName === '天猫' ? 'tmall' : info.platform);
  class ClipboardBadgeIcon {
    static of(info) {
      if (mutation === 'passthrough') return info.platform; // r1 时的产品：直接用识别平台取图 → 淘宝图 + 天猫
      const key = good(info);
      if (mutation === 'tmall-empty') return key === 'tmall' ? '' : key; // 天猫不给键（F-X-05 远程图无从按 tmall 取）
      if (mutation === 'all-taobao-as-tmall') return key === 'taobao' ? 'tmall' : key; // 淘宝也丢图
      if (mutation === 'jd-pdd-swapped') return key === 'jd' ? 'pdd' : key === 'pdd' ? 'jd' : key;
      if (mutation === 'pdd-as-pinduoduo') return key === 'pdd' ? 'pinduoduo' : key;
      if (mutation === 'tmall-root-only') return key === 'tmall' && !/^tmall\.com/.test(info.display || '') ? 'taobao' : key; // 漏子域名
      if (mutation === 'tpwd-no-icon') return info.display === null ? '' : key; // 淘口令丢图
      return key;
    }
  }
  return new Map([[badgeIcon, { ClipboardBadgeIcon }]]);
}

const MUTATIONS = ['passthrough', 'tmall-empty', 'all-taobao-as-tmall', 'jd-pdd-swapped', 'pdd-as-pinduoduo',
  'tmall-root-only', 'tpwd-no-icon'];

if (process.argv.includes('--self-test')) {
  const good = run(reference());
  if (good.failures.length !== 0 || good.tests < 3 || good.total < 12 + good.tests) {
    console.error('REFERENCE_ONLY 参考件本应全过：' + good.failures.join(' | '));
    process.exit(1);
  }
  console.log('REFERENCE_ONLY clipboard badge reference: core suite ' + good.tests + ' cases + entry ' + (good.total - good.tests) +
    ' samples pass on real core / texts / icon map');
  let survived = 0;
  for (const mutation of MUTATIONS) {
    const result = run(reference(mutation));
    // core 套件与 entry 宿主逻辑各自都要打红（任一份被删 / 被放宽，另一份仍拦得住）。
    const core = result.failures.filter(f => f.startsWith('core '));
    const entry = result.failures.filter(f => f.startsWith('entry '));
    if (!core.length || !entry.length) { survived++; console.error('SURVIVED ' + mutation + ' core=' + core.length + ' entry=' + entry.length); }
    else console.log('KILLED ' + mutation + ' → ' + entry[0] + ' ‖ ' + core[0]);
  }
  if (survived) process.exit(1);
  console.log('FX05A_CLIP_SELF_TEST all ' + MUTATIONS.length + ' mutants killed');
} else {
  const result = run(new Map());
  for (const failure of result.failures) console.log('FAIL ' + failure);
  console.log('FX05A_CLIP real product: core suite ' + result.tests + ' cases + entry ' + (result.total - result.tests) +
    ' samples, failures=' + result.failures.length);
  process.exitCode = result.failures.length ? 1 : 0;
}
