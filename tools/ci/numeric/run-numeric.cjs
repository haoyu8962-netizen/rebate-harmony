#!/usr/bin/env node
// FU-HM-NUMERIC-TRANSITION-harmony 测试作者 v1：node 执行真实 CouliMotion.ets（SDK TypeScript 转译），NumericTextTransition 换成
// 「照 API 20 模拟器崩溃栈写的桩」：构造时读 options.flipDirection / options.enableBlur。无参构造在真机上是
//   TypeError: Cannot read property flipDirection of undefined（jsEnumStyle.js:1656，NATIVE/HM-L2-PRICE-TAG/probe/try2）
// 桩里同样会抛 TypeError，所以 numeric() 无参构造在这里必红。另有 FlipDirection 全局（DOWN = 0 / UP = 1，SDK text_common.d.ts）。
// 用例：
//   numeric_does_not_throw_on_api20_constructor          sdk 20 / 24、减弱动态开 / 关四种环境下调 numeric() 都不抛
//   numeric_returns_numeric_text_transition_instance      返回值是 NumericTextTransition 实例（不是 undefined / 别的 ContentTransition）
//   numeric_passes_options_object_with_api20_fields       构造实参是非空普通对象；键 ⊆ {flipDirection, enableBlur}；enableBlur 是 boolean、
//                                                         flipDirection 是 FlipDirection 的成员值；实参恰 1 个
//   numeric_independent_of_reduced_motion                  减弱动态开着也照样返回过渡对象（挂不挂由 MotionPolicy.numericTransition 决定，不在 numeric 里）
// 用法：
//   node tools/ci/numeric/run-numeric.cjs                          真实产品（任一用例失败退出 1）
//   node tools/ci/numeric/run-numeric.cjs --root <树>              换一棵树
//   node tools/ci/numeric/run-numeric.cjs --swap <相对路径> <文件>  把某个源码换成 <文件>（变异体 / 参照件用，可多次）
//   node tools/ci/numeric/run-numeric.cjs --expect-red             退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查或设备执行（设备证据见交回 §4）。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
    'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

const args = process.argv.slice(2);
const rootIndex = args.indexOf('--root');
const root = rootIndex >= 0 ? path.resolve(args[rootIndex + 1]) : path.resolve(__dirname, '../../..');
const swaps = new Map();
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--swap') { swaps.set(path.join(root, args[i + 1]), path.resolve(args[i + 2])); i += 2; }
}
const expectRed = args.includes('--expect-red');
const MOTION = path.join(root, 'common/designsystem/src/main/ets/components/CouliMotion.ets');
const FLIP = Object.freeze({ DOWN: 0, UP: 1, 0: 'DOWN', 1: 'UP' });
const KEYS = ['flipDirection', 'enableBlur'];

function makeLoader(fakes) {
  const cache = new Map();
  function load(filename) {
    if (cache.has(filename)) return cache.get(filename).exports;
    const source = swaps.has(filename) ? swaps.get(filename) : filename;
    if (!fs.existsSync(source)) throw new Error('MISSING_SOURCE ' + path.relative(root, filename));
    const result = ts.transpileModule(fs.readFileSync(source, 'utf8'), { fileName: filename.replace(/\.ets$/, '.ts'),
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
    const module = { exports: {} };
    cache.set(filename, module);
    function localRequire(name) {
      if (name in fakes) return fakes[name];
      if (name.startsWith('@kit.') || name.startsWith('@ohos.')) return {};
      if (!name.startsWith('.')) throw new Error('Unsupported dependency: ' + name);
      return load(path.resolve(path.dirname(filename), name.endsWith('.ets') ? name : name + '.ets'));
    }
    new vm.Script('(function(require,module,exports){\n' + result.outputText + '\n})', { filename })
      .runInThisContext()(localRequire, module, module.exports);
    return module.exports;
  }
  return load;
}

class FakeEffect {
  constructor(parts, timing) { this.parts = parts; this.timing = timing; }
  combine(other) { return new FakeEffect([...this.parts, ...other.parts], this.timing); }
  animation(timing) { return new FakeEffect(this.parts, timing); }
}

const constructed = [];
function installArkGlobals() {
  constructed.length = 0;
  globalThis.Curve = { Friction: 'curve-friction', Linear: 'curve-linear', EaseInOut: 'curve-ease', Sharp: 'curve-sharp', Smooth: 'curve-smooth' };
  globalThis.TransitionEffect = class extends FakeEffect {
    static get OPACITY() { return new FakeEffect([{ kind: 'opacity' }]); }
    static get IDENTITY() { return new FakeEffect([]); }
    static opacity(value) { return new FakeEffect([{ kind: 'opacity', value }]); }
    static translate(value) { return new FakeEffect([{ kind: 'translate', value }]); }
    static scale(value) { return new FakeEffect([{ kind: 'scale', value }]); }
    static asymmetric(a, b) { return new FakeEffect([...a.parts, ...b.parts]); }
  };
  globalThis.ContentTransition = class {};
  globalThis.FlipDirection = FLIP;
  // API 20 运行时（jsEnumStyle.js）构造时直接读 options 的字段；options 为 undefined 时抛 TypeError，应用整个退出。
  globalThis.NumericTextTransition = class extends globalThis.ContentTransition {
    constructor(...rest) {
      super();
      const options = rest[0];
      constructed.push({ argc: rest.length, options });
      if (options === undefined || options === null) {
        throw new TypeError('Cannot read property flipDirection of ' + String(options));
      }
      this.flipDirection = options.flipDirection;
      this.enableBlur = options.enableBlur;
    }
  };
  globalThis.TransitionEdge = { TOP: 'top', BOTTOM: 'bottom', START: 'start', END: 'end' };
}

function motionEnv(env) {
  const accessibility = {
    isAnimationReduceEnabledSync: () => env.reduced,
    onAnimationReduceStateChange: () => undefined,
    offAnimationReduceStateChange: () => undefined,
  };
  const curves = { springMotion: () => 'spring', responsiveSpringMotion: () => 'responsive', initCurve: () => 'init' };
  const deviceInfo = { sdkApiVersion: env.sdk };
  const silent = () => undefined;
  const hilog = { info: silent, debug: silent, warn: silent, error: silent, isLoggable: () => false };
  const fakes = { '@kit.ArkUI': { curves }, '@ohos.curves': { default: curves },
    '@kit.AccessibilityKit': { accessibility }, '@ohos.accessibility': { default: accessibility },
    '@kit.BasicServicesKit': { deviceInfo }, '@ohos.deviceInfo': { default: deviceInfo },
    '@kit.PerformanceAnalysisKit': { hilog }, '@ohos.hilog': { default: hilog } };
  installArkGlobals();
  const CouliMotion = makeLoader(fakes)(MOTION).CouliMotion;
  if (typeof CouliMotion !== 'function') throw new Error('CouliMotion 没有导出');
  CouliMotion.attach();
  return CouliMotion;
}

const ENVS = [{ sdk: 20, reduced: false }, { sdk: 20, reduced: true }, { sdk: 24, reduced: false }, { sdk: 24, reduced: true }];
const label = env => 'sdk' + env.sdk + (env.reduced ? '_reduced' : '');

const results = [];
function record(name, error) {
  if (!error) { results.push(true); console.log('PASS ' + name); return; }
  results.push(false);
  const kind = error instanceof assert.AssertionError ? 'ASSERT' : 'THROW';
  console.log('FAIL[' + kind + '] ' + name + ': ' + String(error && error.message).split('\n')[0]);
}
function run(name, fn) {
  try { fn(); record(name); } catch (e) { record(name, e); }
}

for (const env of ENVS) {
  run('numeric_does_not_throw_on_api20_constructor_' + label(env), () => {
    const CouliMotion = motionEnv(env);
    assert.equal(typeof CouliMotion.numeric, 'function', 'CouliMotion.numeric 不存在');
    CouliMotion.numeric();
  });
}
run('numeric_returns_numeric_text_transition_instance', () => {
  const CouliMotion = motionEnv({ sdk: 20, reduced: false });
  const t = CouliMotion.numeric();
  assert.ok(t instanceof globalThis.NumericTextTransition, 'numeric() 返回的不是 NumericTextTransition 实例：' + String(t));
});
run('numeric_passes_options_object_with_api20_fields', () => {
  const CouliMotion = motionEnv({ sdk: 20, reduced: false });
  CouliMotion.numeric();
  assert.equal(constructed.length, 1, 'numeric() 一次调用应恰构造 1 个 NumericTextTransition，实际 ' + constructed.length);
  const { argc, options } = constructed[0];
  assert.equal(argc, 1, '构造实参应恰 1 个（选项对象），实际 ' + argc);
  assert.ok(options !== null && typeof options === 'object' && !Array.isArray(options), '构造实参不是对象：' + String(options));
  assert.equal(Object.getPrototypeOf(options), Object.prototype, '构造实参应是普通对象字面量');
  const keys = Object.keys(options);
  assert.ok(keys.length >= 1, '选项对象是空的 {}（设备只实证过带字段的对象，见交回 §3）');
  for (const k of keys) assert.ok(KEYS.includes(k), '选项对象有 API 20 NumericTextTransitionOptions 之外的键：' + k);
  if ('enableBlur' in options) assert.equal(typeof options.enableBlur, 'boolean', 'enableBlur 不是 boolean');
  if ('flipDirection' in options) {
    assert.ok(options.flipDirection === FLIP.DOWN || options.flipDirection === FLIP.UP, 'flipDirection 不是 FlipDirection 成员');
  }
});
run('numeric_independent_of_reduced_motion', () => {
  for (const env of ENVS.filter(e => e.reduced)) {
    const CouliMotion = motionEnv(env);
    const t = CouliMotion.numeric();
    assert.ok(t instanceof globalThis.NumericTextTransition, label(env) + ' 下 numeric() 没返回过渡对象：' + String(t));
  }
});

const failed = results.filter(r => !r).length;
console.log((failed === 0 ? 'OK' : 'RED') + ' ' + (results.length - failed) + '/' + results.length);
const red = failed > 0;
process.exit(expectRed ? (red ? 0 : 1) : (red ? 1 : 0));
