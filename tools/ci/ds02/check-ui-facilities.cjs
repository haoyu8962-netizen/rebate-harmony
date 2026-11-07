#!/usr/bin/env node
// 执行真实测试代码的设施自证；假 UI 仅检验遍历、启动及注册，绝不冒充设备通过。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const { execFileSync } = require('child_process');
const root = path.resolve(__dirname, '../../..');
const testRoot = path.join(root, 'entry/src/ohosTest/ets/test');
const ts = require(process.env.COULI_HM_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
class Selector {
  id(value) { this.idValue = value; return this; }
  text(value) { this.textValue = value; return this; }
  type(value) { this.typeValue = value; return this; }
  within(value) { this.parent = value; return this; }
}
const ON = Object.fromEntries(['id', 'text', 'type'].map(key => [key, value => new Selector()[key](value)]));
const cases = [];
const beforeHooks = [];
const beforeEachHooks = [];
const afterEachHooks = [];
const expect = value => ({
  assertTrue: () => assert.equal(value, true),
  assertFalse: () => assert.equal(value, false),
  assertEqual: expected => assert.equal(value, expected),
});
let launchCount = 0;
let catalog = false;
let debugPanel = false;
let neverReady = false;
// APP-12w-c-harmony 测试 v6：首页列表变长时「Debug panel」在首屏以下，要滑过才出现（longHome）；swipes 记有界滚动次数。
let longHome = false;
let swipes = 0;
// FU-HM-DEVICE-FLAKE v4：vanishOn = 第几次拉起时翻页后 home_list 消失（首页整页重建，verify5 的 :58 容器断言）；swipeError = 翻页抛非查找类异常。
let vanishOn = 0;
let swipeError = null;
let activeDriver;
let activeDelegator;
const clicked = [];
const clickable = label => ({ click: async () => {
  clicked.push(label);
  if (label === 'Debug panel') debugPanel = true;
  if (label === 'Component catalog') catalog = true;
}});
const startupDriver = {
  delayMs: async () => {}, waitForIdle: async () => true,
  swipe: async () => { if (swipeError) throw swipeError; swipes++; },
  findComponent: async selector => {
    if (selector.idValue === 'home_list' && launchCount === vanishOn && swipes > 0) return undefined;
    if (selector.idValue === 'home_list') return launchCount >= (longHome ? 1 : 3) ? { getBounds: async () => ({left:0, right:500, top:0, bottom:1000}) } : undefined;
    if (selector.textValue === 'Debug panel') return (longHome ? swipes > 0 : launchCount >= 3) && !neverReady
      ? { ...clickable('Debug panel'), getBounds: async () => ({left:10, right:400, top:500, bottom:560}) } : undefined;
    if (['不同意', '仍不同意'].includes(selector.textValue)) return clickable(selector.textValue);
    if (selector.typeValue === 'Scroll') {
      assert.equal(debugPanel, true);
      return { getBounds: async () => ({left:0, right:500, top:0, bottom:1000}) };
    }
    if (selector.textValue === 'Component catalog' && debugPanel) return { ...clickable('Component catalog'), getBounds: async () => ({left:10, right:400, top:10, bottom:100}) };
    return undefined;
  },
  waitForComponent: async selector => {
    if (selector.idValue === 'catalog-index') { assert.equal(catalog, true); return {}; }
    const node = await startupDriver.findComponent(selector);
    assert.ok(node); return node;
  },
};
const delegator = { startAbility: async want => {
  assert.deepEqual(want, { bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility' });
  launchCount++;
}};
activeDriver = startupDriver;
activeDelegator = delegator;
// 同一个测试 Driver 的方法转发到当前情景；设施专用，不修改设备测试导出。
const driverProxy = new Proxy({}, { get: (_target, key) => (...args) => activeDriver[key](...args) });
const cache = new Map();
// 同一 entry_test 里其他任务登记的套件（F-X-25 等）：名单写死；只核对注册名，不在 DS-02 设施里执行其用例体。
// 其依赖（产品包 core / web、任务专用 rig 等）一律给惰性桩、不加载；DS-02 文件仍走下方严格加载器，
// 未登记的套件文件同样走严格加载器，其额外用例会进入 DS-02 名单比对而失败。
const FOREIGN_SUITES = new Map([
  [path.join(testRoot, 'AuthChangeDevice.test.ets'), { task: 'F-X-25', names: [
    'E01_real_trusted_storage_is_gone_after_account_switch_and_old_document_received_event',
    'E02_I6_only_external_real_arkweb_http_cache_survives_auth_cleanup',
    // F-X-25 t1（D10-279）：新方案「先拆后清再建」的设备用例。
    'E04_I6_no_arg_cookie_clear_keeps_incognito_external_cookie',
    'E05_R3_04_production_sandbox_owner_mismatch_cleans_before_first_trusted_load',
    'E06_covered_host_tears_down_while_covered_and_shows_clean_new_document_after_pop',
    // F-X-25 t4（评审新 r1 NR1-01，合并门槛）：旧文档 beacon / keepalive 的迟到 Set-Cookie。
    'E07_NR1_01_old_document_beacon_and_keepalive_late_set_cookie_never_reaches_new_account',
  ] }],
]);
const foreignCases = [];
const foreignHooks = [];
const inert = new Proxy(function inert() {}, { get: () => inert, apply: () => inert, construct: () => inert });
function foreignRequire(filename, name) {
  const task = FOREIGN_SUITES.get(filename).task;
  if (name !== '@ohos/hypium') return inert;
  const hook = kind => fn => foreignHooks.push({ task, kind, fn });
  return { expect: () => inert, describe: (_name, fn) => fn(),
    it: (name, _flags, fn) => foreignCases.push({ task, file: filename, name, fn }),
    beforeAll: hook('beforeAll'), afterAll: hook('afterAll'), beforeEach: hook('beforeEach'), afterEach: hook('afterEach') };
}
function load(filename, transform) {
  if (!transform && cache.has(filename)) return cache.get(filename);
  const original = fs.readFileSync(filename, 'utf8');
  const source = transform ? transform(original) : original;
  const result = ts.transpileModule(source, { fileName: filename.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
  const module = { exports: {} };
  function localRequire(name) {
    if (FOREIGN_SUITES.has(filename)) return foreignRequire(filename, name);
    if (name === '@ohos/hypium') return { expect, describe: (_name, fn) => fn(),
      it: (name, _flags, fn) => cases.push({ name, fn }), beforeAll: fn => beforeHooks.push(fn), afterAll: () => {},
      beforeEach: fn => beforeEachHooks.push(fn), afterEach: fn => afterEachHooks.push(fn) };
    if (name === '@kit.TestKit') return { ON, MatchPattern: { STARTS_WITH: 1, CONTAINS: 2 }, Driver: { create: () => driverProxy },
      abilityDelegatorRegistry: { getAbilityDelegator: () => activeDelegator } };
    if (name === '@kit.InputKit') return { KeyCode: require('./check-r1-ui-facilities.cjs').platform.KeyCode };
    if (name === '@kit.BasicServicesKit') return { pasteboard: require('./check-r1-ui-facilities.cjs').platform.pasteboard };
    if (name === '@kit.ArkUI') return {
      display: { getDefaultDisplaySync: () => ({ width: 1316, height: 2832, densityPixels: 1 }) },
      MeasureText: { measureText: ({ textContent }) => textContent.length * 12 },
    };
    if (name === '@kit.CoreVisionKit') assert.fail('UI tests must not depend on optional OCR capability');
    if (name.startsWith('@kit.') || name === 'designsystem') return {};
    assert.ok(name.startsWith('.'), name);
    return load(path.resolve(path.dirname(filename), name + '.ets'));
  }
  const helpers = filename.endsWith('/Ds02Ui.test.ets')
    ? '\nexports.facilities = { index, open, sample, absent, clickSpan, windowTitleBounds, setFont };'
    : filename.endsWith('/Ds02ResourcesDevice.test.ets') ? '\nexports.facilities = { resolve };' : '';
  new vm.Script('(function(require,module,exports){' + result.outputText + helpers + '\n})', { filename })
    .runInThisContext()(localRequire, module, module.exports);
  if (!transform) cache.set(filename, module.exports);
  return module.exports;
}

// DS-02 名单：严格加载器注册的用例必须与 158 条完全相等（一条不少、各一次、无清单外用例）——与原规则同一断言。
// 其他任务：只允许 FOREIGN_SUITES 中登记的套件文件，且每个存在的登记套件必须被 List.test 注册、名单完全相等，
// 不得与 DS-02 名字重名。与 check_device_result.py「158 条必跑、允许增补」一致，但增补受白名单约束。
function checkRegistration(ds02Names, foreign, expected) {
  assert.deepEqual([...ds02Names].sort(), expected, 'DS-02 strict-loader registrations must equal the 158 required cases');
  const required = new Set(expected);
  for (const test of foreign) {
    assert.ok(!required.has(test.name), 'foreign suite must not register a DS-02 case name: ' + test.name);
  }
  for (const [file, suite] of FOREIGN_SUITES) {
    if (!fs.existsSync(file)) continue;
    const names = foreign.filter(test => test.file === file).map(test => test.name).sort();
    assert.deepEqual(names, [...suite.names].sort(), suite.task + ' suite registrations must equal its fixed list');
  }
  assert.ok(foreign.every(test => FOREIGN_SUITES.has(test.file)), 'foreign case from unregistered file');
}

// 注册规则的反例：缺一条 / 重复一条 / 未登记额外用例 / 登记套件多一条或少一条 / 重名 / 登记套件未注册，全部必须失败。
async function registrationMutants(expected) {
  const ds02 = cases.map(test => test.name);
  const file = path.join(testRoot, 'AuthChangeDevice.test.ets');
  const foreign = foreignCases.filter(test => test.file === file);
  const extra = { task: 'F-X-25', file, name: 'E99_unlisted', fn: () => {} };
  const mutants = {
    'ds02-missing': [ds02.slice(1), foreign],
    'ds02-duplicate': [[...ds02, ds02[0]], foreign],
    'unregistered-extra-case': [[...ds02, 'E99_unlisted'], foreign],
    'foreign-extra-case': [ds02, [...foreign, extra]],
    'foreign-missing-case': [ds02, foreign.slice(1)],
    'foreign-duplicate-case': [ds02, [...foreign, foreign[0]]],
    'foreign-reuses-ds02-name': [ds02, [...foreign, { ...extra, name: ds02[0] }]],
    'foreign-suite-not-registered': [ds02, []],
    'foreign-from-unregistered-file': [ds02, [...foreign, { ...extra, file: path.join(testRoot, 'Other.test.ets') }]],
  };
  for (const [label, [names, foreignList]] of Object.entries(mutants)) {
    assert.throws(() => checkRegistration(names, foreignList, expected), assert.AssertionError, label);
  }
  // 真实加载器：DS-02 文件引入非 DS-02 包仍被拒；未登记套件（复制 F-X-25 套件为别名文件）走严格加载器同样被拒。
  assert.throws(() => load(path.join(testRoot, 'Ds02Expected.ets'), source => "import { ApiResult } from 'core';\n" + source +
    '\nexport const touch = ApiResult;'), /core/);
  const suite = FOREIGN_SUITES.get(file);
  const before = cases.length;
  FOREIGN_SUITES.delete(file);
  try {
    assert.throws(() => load(file, source => source), error => error instanceof assert.AssertionError && error.message === 'core');
  } finally { FOREIGN_SUITES.set(file, suite); }
  assert.equal(cases.length, before);
  console.log('REFERENCE_ONLY registration mutants killed: ' + Object.keys(mutants).length +
    ' list mutants + DS-02 foreign import + unregistered suite path');
}

function pageDriver(rows, mutation = '', tallIndex = 2, tallHeight = 2800) {
  let offset = 0;
  let swipes = 0;
  let totalHeight = 0;
  let finds = 0;
  let idReads = 0;
  let batchFinds = 0;
  let boundsReads = 0;
  let searches = 0;
  let epoch = 0;
  let staleReads = 0;
  let noCandidates = 0;
  let clippedReads = 0;
  let fullViewportMovingSwipes = 0;
  const observed = new Set();
  const repeatedPerPage = new Map();
  const gone = () => { noCandidates++; throw new Error('does not exist on current UI! (NoCandidates)'); };
  const checkEpoch = born => { if (born !== epoch) { staleReads++; gone(); } };
  const component = rows[0].component;
  const items = rows.map((row, index) => {
    // 包含占三屏的大组件，中途没有新 id 也不能提前停止。
    const top = totalHeight;
    const height = index === tallIndex ? tallHeight : 450;
    totalHeight += height;
    return { id: 'catalog-sample/' + component + '/' + row.variant + '/' + row.state, top, height };
  });
  const maxOffset = Math.max(0, totalHeight - 1000);
  const node = (item, born = epoch) => ({
    getId: async () => { idReads++; return mutation === 'wrong-id' && item === items.at(-1) ? item.id + '-wrong' : item.id; },
    getBounds: async () => {
      checkEpoch(born);
      boundsReads++;
      if (observed.has(item.id)) repeatedPerPage.set(epoch, (repeatedPerPage.get(epoch) || 0) + 1);
      if (mutation === 'bounds-nocandidates' && (item.top >= offset + 1000 || item.top + item.height <= offset)) gone();
      if (mutation === 'bounds-other-error') throw new Error('BOUNDS_TRANSPORT_ERROR');
      if (['search-offscreen', 'search-zero', 'search-horizontal'].includes(mutation) && swipes > 0) {
        if (mutation === 'search-zero') return { left: 0, right: 0, top: 0, bottom: 0 };
        if (mutation === 'search-horizontal') return { left: 500, right: 600, top: 10, bottom: 100 };
        return { left: 10, right: 490, top: 1000, bottom: 1100 };
      }
      if (mutation === 'offscreen' && item === items.at(-1)) return { left: 10, right: 490, top: 2000, bottom: 2100 };
      // 设备离屏节点会返回零矩形，不能误判为锚点未移动。
      if (item.top >= offset + 1000 || item.top + item.height <= offset) return { left: 0, right: 0, top: 0, bottom: 0 };
      observed.add(item.id);
      if (item.top < offset || item.top + item.height > offset + 1000) clippedReads++;
      // 与设备 getBounds 一致：可见部分按视口裁剪，原始坐标不暴露给测试。
      return { left: 10, right: 490, top: Math.max(0, item.top - offset), bottom: Math.min(1000, item.top + item.height - offset) };
    },
  });
  const container = (born = epoch) => ({
    scrollToTop: async () => { checkEpoch(born); offset = 0; epoch++; },
    scrollToBottom: async () => { checkEpoch(born); offset = maxOffset; epoch++; },
    getBounds: async () => { checkEpoch(born); return { left: 0, right: 500, top: 0, bottom: 1000 }; },
    scrollSearch: async () => { searches++; assert.fail('native scrollSearch is forbidden'); },
  });
  return {
    stats: () => ({ swipes, maxOffset, finds, batchFinds, idReads, boundsReads, searches, staleReads, noCandidates, clippedReads, fullViewportMovingSwipes, maxRepeatedPerPage: Math.max(0, ...repeatedPerPage.values()) }),
    waitForComponent: async selector => { assert.equal(selector.idValue, 'catalog-cases/' + component); return container(); },
    findComponent: async selector => {
      finds++;
      if (selector.idValue === 'catalog-cases/' + component) return container();
      if (mutation === 'lookup-other-error') throw new Error('LOOKUP_TRANSPORT_ERROR');
      assert.equal(selector.parent?.idValue, 'catalog-cases/' + component, 'sample query stays within current list');
      const item = items.find(item => item.id === selector.idValue);
      if (!item || (['missing', 'wrong-id', 'missing-nocandidates'].includes(mutation) && item === items.at(-1))) {
        if (mutation === 'missing-nocandidates') gone();
        return undefined;
      }
      if (['visible-only', 'lookup-nocandidates'].includes(mutation) &&
        (item.top >= offset + 1000 || item.top + item.height <= offset)) {
        if (mutation === 'lookup-nocandidates') gone();
        return undefined;
      }
      return node(item);
    },
    findComponents: async selector => {
      finds++; batchFinds++;
      assert.equal(selector.parent.idValue, 'catalog-cases/' + component);
      // 故意连离屏节点一起返回：必须按 bounds 排除，不能一屏假装扫完。
      if (mutation === 'lookup-other-error') throw new Error('LOOKUP_TRANSPORT_ERROR');
      if (mutation === 'lookup-nocandidates' && noCandidates === 0) gone();
      let visibleItems = items.filter((_item, index) => !['missing', 'missing-nocandidates'].includes(mutation) || index !== items.length - 1);
      if (mutation === 'visible-only') visibleItems = visibleItems.filter(item => item.top < offset + 1000 && item.top + item.height > offset);
      if (mutation === 'shuffled') visibleItems = [...visibleItems].reverse();
      return visibleItems.map(item => node(item));
    },
    swipe: async (_x1, y1, _x2, y2, speed) => {
      assert.ok([600, 200].includes(speed)); swipes++; epoch++;
      const delta = mutation === 'overshoot' && speed === 600 ? Math.sign(y1 - y2) * 2300 : y1 - y2;
      const before = offset;
      offset = Math.min(maxOffset, Math.max(0, offset + delta));
      if (offset !== before && items.some(item => item.top <= Math.min(before, offset) &&
        item.top + item.height >= Math.max(before, offset) + 1000)) fullViewportMovingSwipes++;
    },
    waitForIdle: async () => true,
  };
}

(async () => {
  load(path.join(testRoot, 'List.test.ets')).default();
  // HM-07v-a 测试 v2：check_device_result 的合集把 F-X-25 6 条也列为设备必跑（FX25_DEVICE_CASES）；这里比的是严格加载器注册名，
  // F-X-25 走上方 FOREIGN_SUITES 固定名单（与 FX25_DEVICE_CASES 一致由 test_test_facilities.py 守），所以从合集里减掉再比。
  const expected = JSON.parse(execFileSync('python3', ['-c',
    'import json,sys; sys.path.insert(0,sys.argv[1]); from check_device_result import expected_names, FX25_DEVICE_CASES; print(json.dumps(sorted(expected_names() - set(FX25_DEVICE_CASES))))', __dirname], { encoding: 'utf8' }));
  checkRegistration(cases.map(test => test.name), foreignCases, expected);
  console.log('REFERENCE_ONLY registration: all ' + expected.length + ' required cases registered exactly once');
  console.log('REFERENCE_ONLY registration: other registered suites ' + [...FOREIGN_SUITES.values()]
    .map(suite => suite.task + '=' + suite.names.length).join(',') + ' match their fixed lists; not executed here');
  await registrationMutants(expected);
  assert.equal(beforeEachHooks.length, 2);
  assert.equal(afterEachHooks.length, 2);
  await require('./check-ui-session.cjs')({ load, testRoot, beforeEachHooks, afterEachHooks,
    driver: value => { activeDriver = value; }, driverProxy, ON });
  activeDriver = startupDriver;
  assert.equal(beforeHooks.length, 1);
  await beforeHooks[0]();
  assert.equal(launchCount, 3);
  assert.ok(catalog && clicked.includes('不同意') && clicked.includes('仍不同意'));
  console.log('REFERENCE_ONLY startup: survives two Hello World launches, waits for real catalog');
  neverReady = true; launchCount = 0;
  await assert.rejects(beforeHooks[0]);
  assert.equal(launchCount, 8);
  console.log('REFERENCE_ONLY startup: never-ready app fails after bounded retries');
  // APP-12w-c-harmony 测试 v6：真实首页卡片加载后「Debug panel」落到首屏以下——须在首页列表里滚动找到，第一次拉起即就绪。
  neverReady = false; longHome = true; launchCount = 0; swipes = 0; catalog = false; debugPanel = false;
  await beforeHooks[0]();
  assert.equal(launchCount, 1);
  assert.ok(swipes > 0 && catalog);
  console.log('REFERENCE_ONLY startup: Debug panel below the fold is reached by bounded scrolling in home_list');
  // FU-HM-DEVICE-FLAKE v4：翻页途中 home_list 消失 → 本轮没找到（DS02_UI_CONTAINER_GONE），重拉后照常进目录。
  vanishOn = 1; launchCount = 0; swipes = 0; catalog = false; debugPanel = false;
  await beforeHooks[0]();
  assert.equal(launchCount, 2);
  assert.ok(catalog);
  vanishOn = 0;
  // 其它异常（如翻页传输错误）不被吸收，beforeAll 照旧红、不重拉。
  swipeError = new Error('SWIPE_TRANSPORT_ERROR'); launchCount = 0; swipes = 0; catalog = false; debugPanel = false;
  await assert.rejects(beforeHooks[0], /SWIPE_TRANSPORT_ERROR/);
  assert.equal(launchCount, 1);
  swipeError = null;
  longHome = false;
  // 其它调用方：容器找不到 / 零面积仍是失败（抛 DS02_UI_CONTAINER_GONE），不返回节点、不放宽。
  const sessionMod = load(path.join(testRoot, 'Ds02UiSession.ets'));
  const noSwipe = async () => assert.fail('must not swipe without a container');
  await assert.rejects(sessionMod.searchUiComponent({ findComponent: async () => undefined, swipe: noSwipe },
    ON.id('catalog-index'), ON.id('x')), /DS02_UI_CONTAINER_GONE/);
  await assert.rejects(sessionMod.searchUiComponent({ findComponent: async sel => sel.idValue === 'catalog-index'
    ? { getBounds: async () => ({ left: 0, right: 0, top: 0, bottom: 0 }) } : undefined, swipe: noSwipe },
    ON.id('catalog-index'), ON.id('x')), /DS02_UI_CONTAINER_GONE/);
  console.log('REFERENCE_ONLY startup: home_list vanishing mid-scroll counts as a miss and relaunches; other errors stay red; other callers still fail on missing container');
  const rows = load(path.join(testRoot, 'Ds02Expected.ets')).EXPECTED_CASES;
  const collect = load(path.join(testRoot, 'Ds02Traversal.ets')).collectRenderedCases;
  let checked = 0;
  for (const component of new Set(rows.map(row => row.component))) {
    const required = rows.filter(row => row.component === component);
    for (const reverse of [false, true]) {
      const driver = pageDriver(required);
      await collect(driver, component, required, reverse);
      assert.ok(driver.stats().swipes <= Math.ceil(driver.stats().maxOffset / 700) + 1);
      assert.equal(driver.stats().staleReads, 0);
      assert.ok(driver.stats().maxRepeatedPerPage <= 1);
      assert.equal(driver.stats().searches, 0);
      checked += required.length;
    }
  }
  assert.equal(checked, 800);
  console.log('REFERENCE_ONLY traversal: 61 components x 2 modes, 800 cases, linear swipe bound, tall rows pass');
  const required = rows.filter(row => row.component === 'ProductCard');
  // S1：完整 36 行目录，测 search 六状态；不是裁小后的假列表。
  const searchRows = required.filter(row => row.variant === 'search');
  assert.equal(searchRows.length, 6);
  for (const height of [2800, 6000]) {
    for (const reverse of [false, true]) {
      const clipped = pageDriver(required, '', 2, height);
      await collect(clipped, 'ProductCard', searchRows, reverse, true);
      const metrics = clipped.stats();
      assert.ok(metrics.clippedReads > 0, 'positive must actually read clipped bounds');
      assert.ok(metrics.fullViewportMovingSwipes >= (height === 2800 ? 1 : 2),
        'high card must keep moving while its clipped rectangle stays exactly equal');
      assert.equal(metrics.staleReads, 0);
      assert.equal(metrics.searches, 0);
      assert.ok(metrics.maxRepeatedPerPage <= 1);
      assert.ok(metrics.swipes < 25, 'must not pass only through page-budget fallback');
      console.log('REFERENCE_ONLY S1 clipped high-card PASS: ProductCard/search ' +
        (reverse ? 'dark' : 'light') + ', card=' + height + 'px, viewport=1000px, full-viewport-moving-swipes=' + metrics.fullViewportMovingSwipes);
    }
  }
  // 在内存中复原旧判据，必须被同一裁剪正例的最终逐 id 断言拦截。
  const oldTop = load(path.join(testRoot, 'Ds02Traversal.ets'), source => {
    const predicate = /const reference: boolean = anchor !== undefined &&[\s\S]*?if \(unchangedSwipes >= 2\) \{ break; \}/;
    assert.ok(predicate.test(source), 'old-top mutation must hit actual endpoint predicate');
    return source.replace(predicate, `if (anchor !== undefined && Math.abs(after.top - anchor.top) <= 2 &&
      afterViewport.top === viewport.top && afterViewport.bottom === viewport.bottom) { break; }`);
  }).collectRenderedCases;
  const noReference = load(path.join(testRoot, 'Ds02Traversal.ets'), source => {
    const original = 'const stable: boolean = reference && anchor !== undefined';
    assert.ok(source.includes(original));
    return source.replace(original, 'const stable: boolean = anchor !== undefined');
  }).collectRenderedCases;
  for (const reverse of [false, true]) {
    await assert.rejects(oldTop(pageDriver(required), 'ProductCard', searchRows, reverse, true),
      /MISSING:catalog-sample\/ProductCard\/search\/long-price/);
    await assert.rejects(noReference(pageDriver(required, '', 2, 6000), 'ProductCard', searchRows, reverse, true),
      /MISSING:catalog-sample\/ProductCard\/search\/long-price/);
  }
  console.log('REFERENCE_ONLY S1 KILLED: old top-only predicate (2800px) and unchanged-bounds-only predicate (6000px), both directions; long-price assertion fails');
  // 显式首尾也可超过视口：不能把“内部高卡保护”变成无法识别首尾的死循环。
  for (const index of [0, required.length - 1]) {
    for (const reverse of [false, true]) {
      const clipped = pageDriver(required, '', index, 2800);
      await collect(clipped, 'ProductCard', searchRows, reverse, true);
      assert.ok(clipped.stats().swipes <= Math.ceil(clipped.stats().maxOffset / 700) + 4);
      assert.equal(clipped.stats().staleReads, 0);
    }
  }
  console.log('REFERENCE_ONLY S1 explicit first/last tall samples: both directions pass without unbounded fallback');
  const splitCoverage = [];
  for (const variant of new Set(required.map(row => row.variant))) {
    const subset = required.filter(row => row.variant === variant);
    assert.equal(subset.length, 6);
    for (const reverse of [false, true]) {
      // 底层始终是完整 36 行列表，不能用删减后的假产品列表证明拆分正确。
      const driver = pageDriver(required);
      await collect(driver, 'ProductCard', subset, reverse, true);
      assert.equal(driver.stats().staleReads, 0);
      assert.ok(driver.stats().swipes <= Math.ceil(driver.stats().maxOffset / 700) + 4, 'isolated variant must stop at initial boundary: ' + variant + '/' + reverse);
      splitCoverage.push(...subset.map(row => row.variant + '/' + row.state + '/' + reverse));
      for (const mutation of ['missing', 'wrong-id', 'offscreen', 'bounds-other-error']) {
        if (variant === 'large' || mutation === 'bounds-other-error') {
          await assert.rejects(collect(pageDriver(required, mutation), 'ProductCard', subset, reverse, true));
        }
      }
    }
  }
  assert.equal(splitCoverage.length, 72);
  assert.equal(new Set(splitCoverage).size, 72);
  assert.deepEqual(new Set(splitCoverage), new Set(required.flatMap(row =>
    [false, true].map(reverse => row.variant + '/' + row.state + '/' + reverse))));
  console.log('REFERENCE_ONLY v7c split: 12 groups cover original 72 ProductCard samples exactly; full list + missing/wrong/offscreen/transport mutants checked');
  const traversal = load(path.join(testRoot, 'Ds02Traversal.ets'));
  const formalCoverage = [];
  let currentTheme;
  traversal.collectRenderedCases = async (driver, component, subset, reverse, seek) => {
    assert.equal(component, 'ProductCard');
    assert.equal(subset.length, 6);
    assert.equal(new Set(subset.map(row => row.variant)).size, 1);
    assert.equal(reverse, currentTheme === 'dark');
    assert.equal(seek, true);
    formalCoverage.push(...subset.map(row => row.variant + '/' + row.state + '/' + reverse));
    await collect(driver, component, subset, reverse, seek);
  };
  try {
    for (const test of cases.filter(test => test.name.startsWith('render_all_declared_states_ProductCard_'))) {
      const driver = pageDriver(required);
      const wait = driver.waitForComponent;
      driver.waitForComponent = async selector => {
        if (selector.idValue.startsWith('catalog-theme-')) return { click: async () => {
          currentTheme = selector.idValue.slice('catalog-theme-'.length);
        } };
        if (selector.idValue === 'catalog-kind/ProductCard') return { getText: async () => '自绘' };
        return wait(selector);
      };
      activeDriver = driver;
      await test.fn();
    }
  } finally { traversal.collectRenderedCases = collect; }
  assert.equal(formalCoverage.length, 72);
  assert.deepEqual(new Set(formalCoverage), new Set(splitCoverage));
  console.log('REFERENCE_ONLY v7c actual registered bodies: 12 cases execute 6 states each, 72 unique variant/state/theme assertions');

  for (const variant of ['visible-only', 'shuffled']) {
    for (const reverse of [false, true]) await collect(pageDriver(required, variant), 'ProductCard', required, reverse);
    console.log('REFERENCE_ONLY traversal: ' + variant + ' passes in both directions');
  }
  const measured = pageDriver(required);
  await collect(measured, 'ProductCard', required, false);
  const stats = measured.stats();
  assert.equal(stats.batchFinds, 0, 'no broad sample query');
  assert.equal(stats.idReads, 0, 'exact missing-id lookup does not read every id');
  assert.ok(stats.maxRepeatedPerPage <= 1, 'only one boundary anchor may be remeasured per screen');
  assert.ok(stats.boundsReads < 36 * (stats.swipes + 1), 'missing-only reads improve on all-row measurement');
  assert.equal(stats.staleReads, 0);
  console.log('REFERENCE_ONLY IPC counts (not device timing): ProductCard fresh lookups=' + stats.finds + ', batches=' + stats.batchFinds + ', ids=' + stats.idReads + ', bounds=' + stats.boundsReads);
  for (const mutation of ['missing', 'wrong-id', 'offscreen', 'missing-nocandidates']) {
    for (const reverse of [false, true]) {
      const driver = pageDriver(required, mutation);
      await assert.rejects(collect(driver, 'ProductCard', required, reverse), /MISSING:/);
      assert.ok(driver.stats().swipes <= 2 * (Math.ceil(driver.stats().maxOffset / 700) + 2), mutation + '/' + reverse + ': ' + JSON.stringify(driver.stats()));
      assert.equal(driver.stats().searches, 0);
      assert.equal(driver.stats().staleReads, 0);
    }
    console.log('REFERENCE_ONLY traversal mutant killed in both directions: ' + mutation);
  }
  for (const reverse of [false, true]) {
    const driver = pageDriver(required, 'overshoot');
    await collect(driver, 'ProductCard', required, reverse);
    assert.equal(driver.stats().searches, 0);
    assert.ok(driver.stats().swipes <= 320 + Math.ceil(driver.stats().maxOffset / 700) + 1);
    assert.equal(driver.stats().staleReads, 0);
    for (const mutation of ['search-offscreen', 'search-zero', 'search-horizontal']) {
      const invalid = pageDriver(required, mutation);
      await assert.rejects(collect(invalid, 'ProductCard', required, reverse), /MISSING:/);
      assert.equal(invalid.stats().staleReads, 0);
    }
    for (const mutation of ['lookup-nocandidates', 'bounds-nocandidates']) {
      const transient = pageDriver(required, mutation);
      await collect(transient, 'ProductCard', required, reverse);
      assert.ok(transient.stats().noCandidates > 0);
      assert.equal(transient.stats().staleReads, 0);
    }
    for (const mutation of ['lookup-other-error', 'bounds-other-error']) {
      await assert.rejects(collect(pageDriver(required, mutation), 'ProductCard', required, reverse), /TRANSPORT_ERROR/);
    }
  }
  console.log('REFERENCE_ONLY v7d traversal: overshoot recovered with reverse sweep; each direction stops at its visible boundary; offscreen/zero/horizontal results still fail');
  console.log('REFERENCE_ONLY v7d: every scroll invalidates handles; no native scrollSearch; lookup/bounds NoCandidates continue; other errors propagate; persistent absence fails');

  // 真正执行遍历截止路径：超出预算后不能再滑动/补查，缺项仍逐 id 报错。
  const realClock = Date.now;
  try {
    let now = 0, moves = 0;
    Date.now = () => now;
    const slow = pageDriver(required);
    const swipe = slow.swipe;
    slow.swipe = async (...args) => { await swipe(...args); moves++; now = 120001; };
    await assert.rejects(collect(slow, 'ProductCard', required, false), /MISSING:/);
    assert.equal(moves, 1);
    assert.equal(slow.stats().searches, 0);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(moves, 1, 'nothing may keep scrolling after traversal exits');
  } finally { Date.now = realClock; }
  console.log('REFERENCE_ONLY v7d traversal budget: fails missing id after one overdue swipe; no later search/swipe');

  const helpers = load(path.join(testRoot, 'Ds02Ui.test.ets')).facilities;
  for (const scale of ['100', '200']) {
    let clicked = false;
    activeDriver = {
      waitForComponent: async (selector, timeout) => {
        if (selector.idValue === 'catalog-font-' + scale) return { click: async () => { clicked = true; } };
        assert.equal(clicked, true);
        assert.equal(selector.textValue, scale === '200' ? '字号 ×2.00' : '字号 ×1.00');
        assert.equal(timeout, 5000);
        return undefined;
      },
      waitForIdle: async () => true,
    };
    await assert.rejects(helpers.setFont(scale), assert.AssertionError);
  }
  console.log('REFERENCE_ONLY font: missing target toolbar label fails for 100/200; window cases defer layout until label wait');

  // 执行真实 OAuth 用例；虚拟时钟仅模拟刷新延迟，不提供设备耗时证据。
  const realNow = Date.now;
  try {
    for (const provider of ['huawei', 'wechat']) {
      for (const mutation of ['', 'busy-late', 'ready-missing', 'ready-double']) {
        let now = 0;
        let count = 1;
        let busyAt;
        let readyAt;
        Date.now = () => now;
        const bounds = { left: 10, right: 100, top: 10, bottom: 100 };
        const counter = { getText: async () => {
          if (busyAt !== undefined && readyAt === undefined) assert.ok(now - busyAt >= 500);
          if (mutation === 'busy-late' && busyAt !== undefined && now - busyAt >= 250) count = 2;
          if (readyAt !== undefined && now - readyAt >= 250 && mutation !== 'ready-missing') {
            count = mutation === 'ready-double' ? 3 : 2;
          }
          return String(count);
        } };
        const lookup = selector => {
          if (selector.idValue === 'catalog-cases/OAuthButton') return {
            getBounds: async () => ({ left: 0, right: 500, top: 0, bottom: 1000 }),
          };
          if (selector.idValue === 'catalog-events/OAuthButton') return counter;
          const busy = selector.idValue === 'catalog-control/OAuthButton/' + provider + '/authorizing';
          assert.ok(busy || selector.idValue === 'catalog-control/OAuthButton/' + provider + '/default');
          return { getBounds: async () => bounds, isEnabled: async () => !busy,
            click: async () => { if (busy) busyAt = now; else readyAt = now; } };
        };
        activeDriver = {
          findComponent: async selector => lookup(selector), waitForComponent: async selector => lookup(selector),
          waitForIdle: async () => true, delayMs: async ms => { now += ms; },
        };
        const run = cases.find(test => test.name === 'standalone_oauth_busy_is_disabled_' + provider).fn;
        if (mutation) await assert.rejects(run, assert.AssertionError); else await run();
        if (mutation === 'busy-late') { assert.equal(readyAt, undefined); assert.equal(now, 500); }
        else if (mutation) assert.equal(now - readyAt, 3000);
        else assert.equal(now - readyAt, 300);
      }
    }
  } finally { Date.now = realNow; }
  console.log('REFERENCE_ONLY OAuth: both providers wait for delayed +1; busy late increment, missing callback and +2 fail; polling bounded to 3s');

  let backs = 0;
  let indexReady = false;
  activeDriver = {
    findComponent: async () => indexReady ? {} : undefined,
    pressBack: async () => { backs++; }, waitForIdle: async () => true,
    waitForComponent: async selector => {
      assert.equal(selector.idValue, 'catalog-index'); assert.equal(backs, 1);
      indexReady = true; return {};
    },
  };
  await helpers.index(); assert.equal(backs, 1);
  console.log('REFERENCE_ONLY return: waits for index after one Back, no second Back during transition');

  let directLaunches = 0;
  let detail = '';
  activeDelegator = { startAbility: async want => {
    assert.deepEqual(want, { bundleName: 'com.couli.hm', moduleName: 'entry', abilityName: 'EntryAbility',
      parameters: { 'couli.ds02.component': 'Toast' } });
    directLaunches++; detail = 'Toast';
  } };
  activeDriver = {
    findComponent: async selector => selector.idValue === 'catalog-cases/' + detail ? {} : undefined,
    waitForComponent: async selector => { assert.equal(selector.idValue, 'catalog-cases/Toast'); return {}; },
    waitForIdle: async () => true,
  };
  await helpers.open('Toast'); await helpers.open('Toast');
  assert.equal(directLaunches, 1);
  console.log('REFERENCE_ONLY direct launch: correct Want, adjacent theme cases reuse same detail');

  let searches = 0;
  let nearRect = { left: 5, right: 80, top: 20, bottom: 60 };
  const nearby = { getBounds: async () => nearRect };
  activeDriver = {
    waitForComponent: async () => ({ getBounds: async () => ({ left: 0, right: 100, top: 0, bottom: 100 }) }),
    findComponent: async selector => selector.idValue === 'catalog-cases/Toast' ? { getBounds: async () => ({ left: 0, right: 100, top: 0, bottom: 100 }) } : nearby,
    swipe: async () => { searches++; nearRect = { left: 5, right: 80, top: 20, bottom: 60 }; },
    waitForIdle: async () => true,
  };
  await helpers.sample('Toast', 'text', 'default'); assert.equal(searches, 0);
  nearRect = { left: 105, right: 180, top: 20, bottom: 60 };
  await helpers.sample('Toast', 'text', 'default'); assert.equal(searches, 1);
  console.log('REFERENCE_ONLY sample: visible center reused; horizontally offscreen node must scroll');

  let polls = 0;
  activeDriver = { findComponent: async () => ++polls < 3 ? {} : undefined, delayMs: async () => {} };
  assert.equal(await helpers.absent(ON.id('window'), 5000), true); assert.equal(polls, 3);
  activeDriver = { findComponent: async () => ({}), delayMs: async () => {} };
  assert.equal(await helpers.absent(ON.id('window'), 0), false);
  console.log('REFERENCE_ONLY close: delayed disappearance waits, retained window fails absence');

  let spanClicks = 0;
  activeDriver = {
    waitForComponent: async selector => {
      assert.equal(selector.parent.idValue, 'catalog-sample/AgreementCheckRow/three/unchecked');
      assert.equal(selector.typeValue, 'Text'); assert.equal(selector.textValue, '《隐私政策》');
      return { getText: async () => '我已阅读并同意《用户协议》《隐私政策》和《华为账号用户认证协议》',
        getBounds: async () => ({ left: 10, right: 210, top: 30, bottom: 90 }) };
    },
    click: async (x, y) => { assert.ok(x > 10 && x < 210 && y > 30 && y < 90); spanClicks++; },
    waitForIdle: async () => true,
  };
  await helpers.clickSpan('catalog-sample/AgreementCheckRow/three/unchecked', '《隐私政策》');
  assert.equal(spanClicks, 1);
  console.log('REFERENCE_ONLY Span: scoped real Text coordinates; device callback assertions remain in case');

  for (const mutation of ['', 'wrong-link', 'link-toggles', 'confirmation-unsynced']) {
    let checked = false;
    let lastLink = '无';
    let confirmation = false;
    const bounds = { left: 10, right: 210, top: 30, bottom: 90 };
    const control = { isChecked: async () => checked, getBounds: async () => bounds };
    const lookup = selector => {
      if (selector.textValue === '字号 ×1.00') return {};
      if (selector.typeValue === 'Text') return {
        getText: async () => '我已阅读并同意《用户协议》《隐私政策》和《华为账号用户认证协议》', getBounds: async () => bounds,
      };
      if (selector.idValue === 'catalog-cases/AgreementCheckRow') return {
        getBounds: async () => ({ left: 0, right: 500, top: 0, bottom: 1000 }),
      };
      if (selector.idValue === 'catalog-control/AgreementCheckRow/three/unchecked') return control;
      if (selector.idValue === 'catalog-agreement-last-link') return { getText: async () => lastLink };
      if (selector.idValue === 'catalog-agreement-accept') return confirmation ? { click: async () => {
        checked = mutation !== 'confirmation-unsynced'; confirmation = false;
      } } : undefined;
      return { click: async () => { if (selector.idValue === 'catalog-agreement-confirm') confirmation = true; } };
    };
    activeDriver = {
      findComponent: async selector => lookup(selector), waitForComponent: async selector => lookup(selector),
      click: async () => { lastLink = mutation === 'wrong-link' ? 'agreement' : 'privacy'; checked = mutation === 'link-toggles'; },
      waitForIdle: async () => true, delayMs: async () => {},
    };
    const run = cases.find(test => test.name === 'agreement_links_do_not_toggle_and_confirmation_updates_same_checkbox').fn;
    if (mutation) await assert.rejects(run); else await run();
  }
  console.log('REFERENCE_ONLY agreement: wrong callback, link toggles, confirmation not synced all fail actual case');

  // 执行真实系统窗口用例；截图只模拟保存成功，不伪造 OCR 或像素级验收。
  activeDelegator = { getAppContext: () => ({ cacheDir: '/reference-only' }) };
  // 1.34× 标题可过；完整文本、落屏范围、标题增长、正文严格 >1.5× 和还原均有反例。
  for (const kind of ['AlertDialog', 'ActionMenu']) {
    for (const mutation of ['', 'title-unscaled', 'body-unscaled', 'body-at-threshold',
      'title-missing', 'title-wrong-type', 'title-ellipsis', 'title-incomplete',
      'title-zero-width', 'title-zero-height', 'title-off-left', 'title-off-top',
      'title-off-right', 'title-off-bottom', 'title-restore-broken', 'restore-broken']) {
      let opened = false;
      let scale = 1;
      let pendingScale;
      let enlarged = false;
      const title = kind === 'AlertDialog' ? '清除缓存' : '用户协议与隐私政策';
      const body = kind === 'AlertDialog' ? '将清除本机缓存的图片与搜索记录，不影响账号与订单。' : '选择要查看的文件';
      const titleNode = () => ({
        getType: async () => scale === 2 && mutation === 'title-wrong-type' ? 'Button' : 'Text',
        getText: async () => scale === 2 && mutation === 'title-ellipsis' ? title.slice(0, -2) + '…' :
          scale === 2 && mutation === 'title-incomplete' ? title.slice(0, -1) : title,
        getBounds: async () => {
          const bounds = { left: 20, right: 1200, top: 50,
            bottom: 50 + (scale === 2 ? (mutation === 'title-unscaled' ? 100 : 134) :
              enlarged && mutation === 'title-restore-broken' ? 120 : 100) };
          if (scale === 2) {
            if (mutation === 'title-zero-width') bounds.right = bounds.left;
            if (mutation === 'title-zero-height') bounds.bottom = bounds.top;
            if (mutation === 'title-off-left') bounds.left = -1;
            if (mutation === 'title-off-top') bounds.top = -1;
            if (mutation === 'title-off-right') bounds.right = 1317;
            if (mutation === 'title-off-bottom') bounds.bottom = 2833;
          }
          return bounds;
        },
      });
      const bodyNode = () => ({ getType: async () => 'Text', getBounds: async () => ({ left: 20, right: 1200, top: 200,
        bottom: 200 + (scale === 2 ? (mutation === 'body-unscaled' ? 149 : mutation === 'body-at-threshold' ? 150 : 200) :
          enlarged && mutation === 'restore-broken' ? 120 : 100) }) });
      const lookup = selector => {
        if (selector.textValue === '字号 ×1.00' || selector.textValue === '字号 ×2.00') {
          assert.equal(selector.textValue, pendingScale === 2 ? '字号 ×2.00' : '字号 ×1.00');
          scale = pendingScale; pendingScale = undefined;
          return {};
        }
        if (selector.textValue === body) return opened ? bodyNode() : undefined;
        if (selector.textValue === title) return opened && !(scale === 2 && mutation === 'title-missing') ? titleNode() : undefined;
        if (selector.idValue === 'catalog-cases/' + kind) return {};
        return { click: async () => {
          if (selector.idValue === 'catalog-font-100') pendingScale = 1;
          else if (selector.idValue === 'catalog-font-200') { pendingScale = 2; enlarged = true; }
          else if (selector.idValue === 'catalog-open-' + kind) { assert.equal(pendingScale, undefined); opened = true; }
          else assert.fail(selector.idValue);
        } };
      };
      activeDriver = { findComponent: async selector => lookup(selector), waitForComponent: async selector => lookup(selector),
        waitForIdle: async () => true, pressBack: async () => { opened = false; },
        delayMs: async () => {}, screenCapture: async path => {
          assert.equal(path, '/reference-only/ds02-v7-title-' + kind + '-200.png'); return true;
        } };
      const run = cases.find(test => test.name === 'large_font_reaches_real_window_' + kind).fn;
      if (mutation) await assert.rejects(run); else await run();
    }
    console.log('REFERENCE_ONLY system window ' + kind + ': 1.34x title + complete visible node pass without OCR; 15 text/bounds/scale/restore mutants fail');
  }

  await require('./check-r1-ui-facilities.cjs').verify({ cases, driver: value => { activeDriver = value; },
    delegator: value => { activeDelegator = value; } });

  await require('./check-r2-tabbar-ui.cjs')({ cases, driver: value => { activeDriver = value; },
    delegator: value => { activeDelegator = value; } });

  const resolve = load(path.join(testRoot, 'Ds02ResourcesDevice.test.ets')).facilities.resolve;
  const resolvedNames = [];
  activeDelegator = { getAppContext: () => ({ resourceManager: {
    getColorByNameSync: name => { resolvedNames.push(name); return 0xffc44820; },
    getColorSync: resource => { assert.notEqual(resource.id, -1); return 0xff171513; },
  } }) };
  assert.equal(resolve({ id: -1, params: ['app.color.color_brand_primary'] }), 0xffc44820);
  assert.deepEqual(resolvedNames, ['color_brand_primary']);
  assert.equal(resolve({ id: 123 }), 0xff171513);
  assert.throws(() => resolve({ id: -1, params: ['app.string.bad'] }));
  console.log('REFERENCE_ONLY resources: name-only uses getColorByNameSync, real id uses getColorSync, malformed name fails');
})().catch(error => { console.error(error); process.exitCode = 1; });
