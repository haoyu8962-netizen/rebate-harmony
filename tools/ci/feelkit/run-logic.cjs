#!/usr/bin/env node
// FU-HM-FEEL-KIT-harmony 测试作者 v1：没有 hvigor 时用 node 执行真实 .ets（SDK TypeScript 转译）。两段：
//   ① common/designsystem/src/test/FeelKit.test.ets（hvigor 在 designsystem 本机单测里真跑同一份）对真实 HapticMoments / MotionPolicy；
//   ② 真实 components/CouliHaptics.ets、CouliMotion.ets 接假 @kit（振动器、无障碍、deviceInfo、ArkUI 全局）的行为用例。
//      这两个文件依赖系统能力，本机单测（Hypium）里替换不了 @kit，所以驱动层的判据只在这里。每条用例重新加载模块（静态字段不串）。
// 用法：
//   node tools/ci/feelkit/run-logic.cjs                           真实产品（任一用例失败退出 1）
//   node tools/ci/feelkit/run-logic.cjs --root <树>               换一棵树（先红副本、参考实现副本）
//   node tools/ci/feelkit/run-logic.cjs --swap <相对路径> <文件>   把某个源码换成 <文件>（变异体用，可多次）
//   node tools/ci/feelkit/run-logic.cjs --expect-red              退出码取反（变异体必须至少一条失败）
// 不冒充 hvigor 编译、ArkTS 严格检查（见 check-arkts.cjs）、真机振动手感或设备执行。
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
const SUITE = path.join(root, 'common/designsystem/src/test/FeelKit.test.ets');
const HAPTICS = path.join(root, 'common/designsystem/src/main/ets/components/CouliHaptics.ets');
const MOTION = path.join(root, 'common/designsystem/src/main/ets/components/CouliMotion.ets');

// 书 §2.1 的时刻 → effectId 表（独立判据，抄自任务书与 SDK api/@ohos.vibrator.d.ts:539-654；D10-1153：SELECTION 先 clock.timer）。
const EFFECTS = { selection: 'haptic.clock.timer', success: 'haptic.notice.success', warning: 'haptic.notice.warning',
  failure: 'haptic.notice.fail', threshold: 'haptic.effect.sharp' };

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

const results = [];
function record(name, error) {
  if (!error) { results.push(true); console.log('PASS ' + name); return; }
  results.push(false);
  const kind = error instanceof assert.AssertionError ? 'ASSERT' : 'THROW';
  const detail = error instanceof assert.AssertionError
    ? (error.generatedMessage ? JSON.stringify(error.actual) + ' != ' + JSON.stringify(error.expected) : error.message)
    : String(error && error.message);
  console.log('FAIL[' + kind + '] ' + name + ': ' + detail);
}

// ---------- ① Hypium 套件 ----------
function runSuite() {
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
    makeLoader({ '@ohos/hypium': hypium })(SUITE).default();
  } catch (e) {
    console.log('LOAD_FAIL suite ' + (e && e.message));
    results.push(false);
    return;
  }
  if (tests.length === 0) { console.log('LOAD_FAIL no tests registered'); results.push(false); return; }
  for (const test of tests) {
    try { test.fn(); record(test.name); } catch (e) { record(test.name, e); }
  }
}

// ---------- ② 驱动层 ----------
function hapticsEnv(options = {}) {
  const log = { supported: [], started: [] };
  const vibrator = {
    isSupportEffectSync: id => {
      log.supported.push(id);
      if (options.supportThrows) { const e = new Error('device'); e.code = options.supportThrows; throw e; }
      return options.unsupported ? false : true;
    },
    startVibration: (effect, attribute) => {
      log.started.push({ effect, attribute });
      if (options.startThrows) throw new Error('sync start failure');
      return options.startRejects ? Promise.reject(new Error('rejected')) : Promise.resolve();
    },
  };
  const silent = () => undefined;
  const fakes = { '@kit.SensorServiceKit': { vibrator }, '@ohos.vibrator': { default: vibrator },
    '@kit.PerformanceAnalysisKit': { hilog: { info: silent, debug: silent, warn: silent, error: silent, isLoggable: () => false } } };
  const module = makeLoader(fakes)(HAPTICS);
  return { CouliHaptics: module.CouliHaptics, log };
}

class FakeEffect {
  constructor(parts, timing) { this.parts = parts; this.timing = timing; }
  combine(other) { return new FakeEffect([...this.parts, ...other.parts], this.timing || other.timing); }
  animation(timing) { return new FakeEffect(this.parts, timing); }
}

function installArkGlobals() {
  globalThis.Curve = { Friction: 'curve-friction', Linear: 'curve-linear', EaseInOut: 'curve-ease', Sharp: 'curve-sharp', Smooth: 'curve-smooth' };
  globalThis.TransitionEffect = class extends FakeEffect {
    static get OPACITY() { return new FakeEffect([{ kind: 'opacity' }]); }
    static get IDENTITY() { return new FakeEffect([]); }
    static get SLIDE() { return new FakeEffect([{ kind: 'translate', value: { x: 1 } }]); }
    static opacity(value) { return new FakeEffect([{ kind: 'opacity', value }]); }
    static translate(value) { return new FakeEffect([{ kind: 'translate', value }]); }
    static rotate(value) { return new FakeEffect([{ kind: 'rotate', value }]); }
    static scale(value) { return new FakeEffect([{ kind: 'scale', value }]); }
    static move(value) { return new FakeEffect([{ kind: 'move', value }]); }
    static asymmetric(a, b) { return new FakeEffect([...a.parts, ...b.parts]); }
  };
  globalThis.NumericTextTransition = class { constructor(options) { this.options = options; } };
  // ArkUI 全局枚举：CouliMotion 里若引用 TransitionEdge 等，给一个可读的占位。
  globalThis.TransitionEdge = { TOP: 'top', BOTTOM: 'bottom', START: 'start', END: 'end' };
}

function motionEnv(options = {}) {
  const log = { reads: 0, subscribes: [], curves: [] };
  const state = { enabled: !!options.enabled };
  const accessibility = {
    isAnimationReduceEnabledSync: () => {
      log.reads++;
      if (options.readThrows) throw new Error('read failed');
      return state.enabled;
    },
    onAnimationReduceStateChange: callback => {
      log.subscribes.push(callback);
      if (options.subscribeThrows) throw new Error('subscribe failed');
    },
    offAnimationReduceStateChange: () => undefined,
  };
  const curves = {
    springMotion: (...a) => { log.curves.push(['springMotion', a]); return 'spring'; },
    responsiveSpringMotion: (...a) => { log.curves.push(['responsiveSpringMotion', a]); return 'responsive'; },
    initCurve: () => 'init',
  };
  const deviceInfo = { sdkApiVersion: options.sdk === undefined ? 24 : options.sdk };
  const silent = () => undefined;
  const fakes = { '@kit.ArkUI': { curves }, '@ohos.curves': { default: curves },
    '@kit.AccessibilityKit': { accessibility }, '@ohos.accessibility': { default: accessibility },
    '@kit.BasicServicesKit': { deviceInfo }, '@ohos.deviceInfo': { default: deviceInfo },
    '@kit.PerformanceAnalysisKit': { hilog: { info: silent, debug: silent, warn: silent, error: silent, isLoggable: () => false } } };
  installArkGlobals();
  const module = makeLoader(fakes)(MOTION);
  return { CouliMotion: module.CouliMotion, log, state };
}

function uiContext() {
  const calls = [];
  return { calls, animateTo: (config, fn) => { calls.push(config); fn(); } };
}

function hasMovement(effect) {
  return effect.parts.some(p => p.kind !== 'opacity');
}

const drivers = [];
const driver = (name, fn) => drivers.push({ name, fn });

for (const [method, id] of Object.entries(EFFECTS)) {
  driver('haptics_' + method + '_starts_preset_' + id + '_with_touch_usage', () => {
    const { CouliHaptics, log } = hapticsEnv();
    CouliHaptics[method]();
    assert.deepEqual(log.started, [{ effect: { type: 'preset', effectId: id, count: 1 }, attribute: { usage: 'touch' } }]);
    assert.deepEqual(log.supported, [id]);
  });
}
driver('haptics_unsupported_is_silent', () => {
  const { CouliHaptics, log } = hapticsEnv({ unsupported: true });
  for (const method of Object.keys(EFFECTS)) CouliHaptics[method]();
  assert.equal(log.started.length, 0);
});
for (const code of [401, 14600101]) {
  driver('haptics_support_query_throw_' + code + '_counts_as_unsupported', () => {
    const { CouliHaptics, log } = hapticsEnv({ supportThrows: code });
    CouliHaptics.success();
    assert.equal(log.started.length, 0);
  });
}
driver('haptics_support_result_is_cached_per_id', () => {
  const { CouliHaptics, log } = hapticsEnv();
  CouliHaptics.selection(); CouliHaptics.selection(); CouliHaptics.selection(); CouliHaptics.success();
  assert.deepEqual(log.supported, [EFFECTS.selection, EFFECTS.success]);
  assert.equal(log.started.length, 4);
});
driver('haptics_sync_start_failure_does_not_escape', () => {
  const { CouliHaptics } = hapticsEnv({ startThrows: true });
  CouliHaptics.failure();
});
driver('haptics_rejected_start_is_handled', async () => {
  const unhandled = [];
  const onUnhandled = reason => unhandled.push(reason);
  process.on('unhandledRejection', onUnhandled);
  try {
    const { CouliHaptics, log } = hapticsEnv({ startRejects: true });
    CouliHaptics.failure();
    assert.equal(log.started.length, 1);
    await new Promise(resolve => setImmediate(resolve));
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(unhandled.length, 0, 'startVibration 的 reject 没人接');
  } finally { process.removeListener('unhandledRejection', onUnhandled); }
});

driver('motion_durations_are_150_and_250', () => {
  const { CouliMotion } = motionEnv();
  assert.equal(CouliMotion.durationMicro, 150);
  assert.equal(CouliMotion.durationEnter, 250);
});
driver('motion_curve_is_system_friction', () => {
  assert.equal(motionEnv().CouliMotion.curve, 'curve-friction');
});
driver('motion_spring_and_responsive_use_system_curves', () => {
  const { CouliMotion, log } = motionEnv();
  assert.equal(CouliMotion.spring(), 'spring');
  assert.equal(CouliMotion.responsive(), 'responsive');
  assert.deepEqual(log.curves.map(c => c[0]), ['springMotion', 'responsiveSpringMotion']);
});
driver('motion_numeric_is_numeric_text_transition', () => {
  assert.ok(motionEnv().CouliMotion.numeric() instanceof globalThis.NumericTextTransition);
});
driver('motion_appear_fades_and_moves_when_not_reduced', () => {
  const { CouliMotion } = motionEnv({ enabled: false });
  CouliMotion.attach();
  const parts = CouliMotion.appear().parts;
  assert.ok(parts.some(p => p.kind === 'opacity'), '要有淡入');
  const moves = parts.filter(p => p.kind === 'translate');
  assert.equal(moves.length, 1, '要有位移');
  assert.ok(Object.values(moves[0].value).some(v => typeof v === 'number' && v !== 0), '位移不能是 0');
});
driver('motion_appear_is_opacity_only_when_reduced', () => {
  const { CouliMotion } = motionEnv({ enabled: true });
  CouliMotion.attach();
  const effect = CouliMotion.appear();
  assert.ok(effect.parts.some(p => p.kind === 'opacity'), '减弱动态仍要淡入');
  assert.equal(hasMovement(effect), false, '减弱动态不得位移 / 缩放');
});
// v2（D10-1163 ①，README §3.3）：减弱动态只取消位移 / 缩放，淡入带自己的短时长；不带时长的 OPACITY 会跟随外层 run 的 0 时长变成硬切。
driver('motion_appear_keeps_a_short_fade_when_reduced', () => {
  const { CouliMotion } = motionEnv({ enabled: true });
  CouliMotion.attach();
  const timing = CouliMotion.appear().timing;
  assert.ok(timing !== undefined, '减弱动态的淡入要有自己的 animation 时长');
  assert.ok(timing.duration >= 100 && timing.duration <= 200, '淡入时长应在 100–200，实际 ' + timing.duration);
});
driver('motion_appear_inside_reduced_run_keeps_its_own_fade', () => {
  const { CouliMotion } = motionEnv({ enabled: true });
  CouliMotion.attach();
  const ui = uiContext();
  let effect;
  CouliMotion.run(ui, 250, () => { effect = CouliMotion.appear(); });
  assert.ok(effect !== undefined, 'run 要执行闭包');
  assert.equal(hasMovement(effect), false);
  assert.ok(effect.timing !== undefined && effect.timing.duration > 0, '淡入不能跟着 run 变成 0 时长');
});
driver('motion_run_animates_with_duration_and_system_curve', () => {
  const { CouliMotion } = motionEnv({ enabled: false });
  CouliMotion.attach();
  const ui = uiContext();
  let changed = 0;
  CouliMotion.run(ui, 250, () => { changed++; });
  assert.equal(changed, 1);
  assert.deepEqual(ui.calls, [{ duration: 250, curve: 'curve-friction' }]);
});
driver('motion_run_applies_directly_when_reduced', () => {
  const { CouliMotion } = motionEnv({ enabled: true });
  CouliMotion.attach();
  const ui = uiContext();
  let changed = 0;
  CouliMotion.run(ui, 250, () => { changed++; });
  assert.equal(changed, 1, '状态必须改且只改一次');
  for (const call of ui.calls) assert.equal(call.duration, 0, '减弱动态时不得带时长做动画');
});
for (const [sdk, expected] of [[23, true], [24, true]]) {
  driver('reduced_reads_system_on_api_' + sdk, () => {
    const { CouliMotion } = motionEnv({ sdk, enabled: true });
    CouliMotion.attach();
    assert.equal(CouliMotion.reduced(), expected);
  });
}
driver('reduced_false_when_system_off', () => {
  const { CouliMotion } = motionEnv({ sdk: 24, enabled: false });
  CouliMotion.attach();
  assert.equal(CouliMotion.reduced(), false);
});
for (const sdk of [20, 22]) {
  driver('below_api_23_never_touches_the_api_' + sdk, () => {
    const { CouliMotion, log } = motionEnv({ sdk, enabled: true });
    CouliMotion.attach();
    assert.equal(CouliMotion.reduced(), false);
    assert.equal(log.reads, 0);
    assert.equal(log.subscribes.length, 0);
  });
}
driver('reduced_read_throw_means_false', () => {
  const { CouliMotion } = motionEnv({ sdk: 24, enabled: true, readThrows: true });
  CouliMotion.attach();
  assert.equal(CouliMotion.reduced(), false);
});
driver('attach_subscribes_once', () => {
  const { CouliMotion, log } = motionEnv({ sdk: 24 });
  CouliMotion.attach(); CouliMotion.attach(); CouliMotion.attach();
  assert.equal(log.subscribes.length, 1);
});
driver('system_toggle_is_written_back', () => {
  const { CouliMotion, log, state } = motionEnv({ sdk: 24, enabled: false });
  CouliMotion.attach();
  assert.equal(CouliMotion.reduced(), false);
  assert.equal(log.subscribes.length, 1, '要订阅系统开关');
  state.enabled = true;
  log.subscribes[0](true);
  assert.equal(CouliMotion.reduced(), true);
  state.enabled = false;
  log.subscribes[0](false);
  assert.equal(CouliMotion.reduced(), false);
});
driver('toggle_changes_appear_and_run_after_attach', () => {
  const { CouliMotion, log } = motionEnv({ sdk: 24, enabled: false });
  CouliMotion.attach();
  assert.equal(hasMovement(CouliMotion.appear()), true);
  assert.equal(log.subscribes.length, 1, '要订阅系统开关');
  log.subscribes[0](true);
  assert.equal(hasMovement(CouliMotion.appear()), false);
});
driver('attach_subscribe_throw_does_not_escape', () => {
  const { CouliMotion } = motionEnv({ sdk: 24, subscribeThrows: true });
  CouliMotion.attach();
});

async function runDrivers() {
  for (const test of drivers) {
    try { await test.fn(); record(test.name); } catch (e) { record(test.name, e); }
  }
}

(async () => {
  runSuite();
  await runDrivers();
  const failed = results.filter(r => !r).length;
  console.log('FEELKIT logic: ' + (results.length - failed) + '/' + results.length + ' passed; root=' + root +
    (swaps.size ? '; swaps=' + swaps.size : ''));
  process.exitCode = expectRed ? (failed ? 0 : 1) : (failed ? 1 : 0);
})();
