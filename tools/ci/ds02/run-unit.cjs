#!/usr/bin/env node
// 在没有 hvigor 时执行同一份纯 Hypium 断言；不模拟 ArkUI/设备。
// --self-test 的内存参考件只自证测试，绝不算产品通过。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.COULI_HM_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const suites = ['Ds02Catalog', 'Ds02Controls', 'Ds02Theme', 'Ds02Focus'];
const modelsPath = path.join(root, 'common/designsystem/src/main/ets/components/ControlModels.ets');
const manifestPath = path.join(root, 'entry/src/staging/ets/catalog/CatalogManifest.ets');
const themePath = path.join(root, 'common/designsystem/src/main/ets/theme/CouliThemeMapping.ets');
const iconPath = path.join(root, 'common/designsystem/src/main/ets/components/PlatformIconSource.ets');

function runner(overrides = new Map(), transform = (_file, source) => source) {
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
    let source = transform(filename, fs.readFileSync(filename, 'utf8'));
    if (filename.endsWith('/ExternalWebView.ets')) {
      // 只抽取真实纯类，方法体逐字保留；不把 ArkUI 页面交给 TS 转译器。
      const tree = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true);
      const declaration = tree.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'ExternalTitleColors');
      assert.ok(declaration, 'missing ExternalTitleColors');
      source = "import { CouliColors } from 'designsystem'; import { ExternalNavStyle } from 'core';\n" + declaration.getText(tree);
    }
    if (filename.endsWith('/WebChrome.ets')) {
      const tree = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true);
      const declaration = tree.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'ExternalNavStyle');
      assert.ok(declaration, 'missing ExternalNavStyle');
      source = declaration.getText(tree);
    }
    const result = ts.transpileModule(source, { fileName: filename.replace(/\.ets$/, ".ts"), reportDiagnostics: true,
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
    const errors = (result.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
    assert.equal(errors.length, 0, errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'));
    const module = { exports: {} }; cache.set(filename, module);
    function localRequire(name) {
      if (name === '@ohos/hypium') return hypium;
      if (name === '@kit.ArkUI') return {
        LengthMetrics: { vp: value => ({ value, unit: 1 }) },
        ColorMetrics: { numeric: value => ({ red: (value >>> 16) & 255, green: (value >>> 8) & 255, blue: value & 255 }) },
      };
      if (name === '@kit.AbilityKit' || name === '@kit.LocalizationKit') return {};
      if (name === 'designsystem') return load(path.join(root, 'common/designsystem/src/main/ets/CouliColors.ets'));
      if (name === 'core') return load(path.join(root, 'common/core/src/main/ets/bridge/WebChrome.ets'));
      if (name === 'generated') return load(path.join(root, 'common/generated/Index.ets'));
      if (name === 'generated/ets/DebugOnly') return load(path.join(root, 'common/generated/src/release/ets/DebugOnly.ets'));
      if (!name.startsWith('.')) throw new Error('Unsupported native dependency: ' + name);
      return load(path.resolve(path.dirname(filename), name.endsWith('.ets') ? name : name + '.ets'));
    }
    new vm.Script('(function(require,module,exports,$r,ObservedV2,Trace){\n' + result.outputText + '\n})', { filename })
      .runInThisContext()(localRequire, module, module.exports, name => ({ id: -1, params: [name] }), value => value, () => {});
    return module.exports;
  }
  function run() {
    const failures = [];
    for (const suite of suites) {
      try { load(path.join(root, suite === 'Ds02Catalog' ? 'entry/src/ohosTest/ets/test/Ds02Catalog.test.ets' :
        'common/designsystem/src/test/' + suite + '.test.ets')).default(); }
      catch (error) { failures.push(suite + ': ' + error.message); }
    }
    for (const test of tests) {
      try { test.fn(); }
      catch (error) { failures.push(test.name + ': ' + error.message); }
    }
    return { total: tests.length, failures };
  }
  return { load, run };
}

function reference(variant = 'system', mutation = '') {
  const expected = runner().load(path.join(root, 'common/designsystem/src/test/Ds02Expected.ets'));
  class CheckboxMetrics {
    static compute(scale = 1, image = false) {
      return { shape: mutation === 'square' ? 'square' : 'circle', diameter: (image ? 22 : 18) * Math.min(scale, 1.5),
        hitWidth: 48, hitHeight: 48, strokeWidth: 2 * Math.min(scale, 1.5) };
    }
  }
  class ChoiceState {
    constructor(checked, enabled, label, change) { Object.assign(this, { checked, enabled, accessibilityName: label, change }); }
    toggle() { if (this.enabled) { this.checked = !this.checked; this.change(this.checked); } }
  }
  class LoginRowModel {
    static create(quick, wechat) { return { providers: [...(!quick ? ['huawei'] : []), ...(wechat ? ['wechat'] : [])],
      showDivider: !quick || wechat, showHelp: true, buttonDiameter: 48, gap: 32, hitWidth: variant === 'custom' ? 64 : 48 }; }
  }
  class SingleSelection {
    constructor(value, options, onChange, enabled = true) { Object.assign(this, { value, options, onChange, enabled }); }
    select(value) {
      if (this.enabled && value !== this.value && this.options.includes(value)) { this.value = value; this.onChange(value); }
    }
  }
  class OAuthAction {
    constructor(provider, callback, busy = false, enabled = true) { this.callback = callback; this.enabled = enabled && !busy; }
    activate() { if (this.enabled) this.callback(); }
  }
  const SheetDismissPolicy = { allows: (reason, protectedSheet) => !protectedSheet || ['back', 'close'].includes(reason) };
  const rows = expected.EXPECTED_CASES.map(row => ({ component: row.component, variant: row.variant, state: row.state,
    kind: row.kinds[variant === 'custom' && row.kinds.length > 1 ? 1 : 0] }));
  if (mutation === 'missing-state') rows.splice(rows.findIndex(r => r.state === 'disabled-checked'), 1);
  if (variant === 'custom') rows.push({ component: 'FilterChip', variant: 'extra', state: 'default', kind: '自绘' });
  const roles = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/system-color-roles.json')));
  const semantic = { brand: 'brand.primary', fontPrimary: 'text.primary', fontSecondary: 'text.secondary',
    backgroundPrimary: 'background.canvas', compDivider: 'border.subtle', interactiveFocus: 'focus.ring' };
  const overrides = new Map();
  overrides.set(modelsPath, { CheckboxMetrics, ChoiceState, SingleSelection, LoginRowModel, OAuthAction, SheetDismissPolicy });
  overrides.set(manifestPath, { catalogCases: () => rows });
  overrides.set(iconPath, { PlatformIconSource: { builtin: key => ({ taobao: 'taobao.png', jd: 'jd.png', pdd: 'pinduoduo.png' })[key] || '' } });
  overrides.set(themePath, {
    resolveShadowTokens: dark => new Map(expected.EXPECTED_SHADOWS.map(r => [r.key, dark ? r.dark : r.light])),
    resolveColorTokens: dark => new Map(expected.EXPECTED_COLORS.filter((r, i) => !(dark && mutation === 'missing-dark' && i === 0))
      .map(r => [r.key, dark ? r.dark : r.light])),
    buildSystemColors: tokens => Object.fromEntries(roles.map(role => [role,
      mutation === 'default-role' && role === 'iconFourth' ? 0 : tokens.get(semantic[role] || 'brand.primary')])),
  });
  return overrides;
}

module.exports = { runner, root };
if (require.main === module) {
if (process.argv.includes('--self-test')) {
  for (const variant of ['system', 'custom']) {
    const result = runner(reference(variant)).run();
    assert.equal(result.failures.length, 0, JSON.stringify(result));
    console.log('REFERENCE_ONLY legal ' + variant + ': ' + result.total + ' assertions/tests passed');
  }
  for (const mutation of ['missing-dark', 'square', 'missing-state', 'default-role']) {
    const result = runner(reference('system', mutation)).run();
    assert.ok(result.failures.length > 0, 'mutant survived: ' + mutation);
    console.log('REFERENCE_ONLY mutant killed ' + mutation + ': ' + result.failures.join(' | '));
  }
} else {
  const result = runner().run();
  for (const failure of result.failures) console.error(failure);
  console.log('DS02_NODE_REAL_SOURCE tests=' + result.total + ' failures=' + result.failures.length);
  process.exitCode = result.failures.length ? 1 : 0;
}

}
