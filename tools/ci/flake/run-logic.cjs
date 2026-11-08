#!/usr/bin/env node
// FU-HM-DEVICE-FLAKE：FlakeKit.ets（设备用例共用的有界等待 / 截屏校验重拍 / 现场诊断）的纯逻辑自测。
// 用 SDK typescript 把 entry/src/ohosTest/ets/test/FlakeKit.ets 转写后在 node 里执行；UiTest Driver、ImageKit 用替身（只证明逻辑，
// 不冒充设备截屏）。另核：用到 captureChecked 的设施不再自己调 screenCapture、重拍只吸收「截图不是真截图」不吸收颜色。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '../../..');
const ts = require(process.env.COULI_HM_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const testDir = path.join(root, 'entry/src/ohosTest/ets/test');

// 替身：截图文件名 → 预设像素。
const images = new Map();
let decodeFails = 0;
const decodedFrom = new WeakMap(); // 解码出的像素缓冲 → 来源文件（核「交的是哪一张」）
const imageKit = {
  image: {
    PixelMapFormat: { RGBA_8888: 3 },
    createImageSource: p => ({
      createPixelMap: async () => {
        if (decodeFails > 0) { decodeFails--; throw new Error('decode failed'); }
        const img = images.get(p);
        assert.ok(img, 'decode of unknown file ' + p);
        return { getImageInfo: async () => ({ size: { width: img.w, height: img.h } }),
          readPixelsToBuffer: async buf => { new Uint8Array(buf).set(img.bytes); decodedFrom.set(buf, p); }, release: async () => {} };
      },
      release: async () => {}
    })
  }
};
function load(file) {
  const result = ts.transpileModule(fs.readFileSync(file, 'utf8'), { fileName: file.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
  const module = { exports: {} };
  const req = name => {
    if (name === '@kit.ImageKit') return imageKit;
    if (name === '@kit.TestKit') return { abilityDelegatorRegistry: { getAbilityDelegator: () => ({ getAppContext: () => ({ cacheDir: '/c' }) }) } };
    throw new Error('FlakeKit must not import ' + name);
  };
  new vm.Script('(function(require,module,exports){' + result.outputText + '\n})', { filename: file }).runInThisContext()(req, module, module.exports);
  return module.exports;
}
const kit = load(path.join(testDir, 'FlakeKit.ets'));

function img(w, h, rgba) {
  const bytes = new Uint8Array(w * h * 4);
  for (let i = 0; i < w * h; i++) bytes.set(rgba, i * 4);
  return { w, h, bytes };
}

(async () => {
  const rect = { left: 10, top: 10, right: 19, bottom: 19 };
  // shotProblem：真截图（不透明）通过；全零（RGBA 全 0）、部分透明、尺寸不符、空图都判不合格。
  const ok = new kit.Shot(9, 9, img(9, 9, [255, 255, 255, 255]).bytes);
  assert.equal(kit.shotProblem(ok, rect), '');
  assert.equal(kit.shotProblem(new kit.Shot(9, 9, img(9, 9, [0, 0, 0, 255]).bytes), rect), '', '真黑色（不透明）是合法截图，由颜色断言判');
  assert.match(kit.shotProblem(new kit.Shot(9, 9, img(9, 9, [0, 0, 0, 0]).bytes), rect), /^alpha<255 81\/81/);
  const half = img(9, 9, [255, 255, 255, 255]); half.bytes.fill(0, 40 * 4);
  assert.match(kit.shotProblem(new kit.Shot(9, 9, half.bytes), rect), /^alpha<255 41\/81/);
  assert.match(kit.shotProblem(new kit.Shot(4, 9, img(4, 9, [255, 255, 255, 255]).bytes), rect), /^size /);
  assert.match(kit.shotProblem(new kit.Shot(0, 0, new Uint8Array(0)), rect), /^empty/);
  console.log('REFERENCE_ONLY shotProblem: opaque (incl. true black) accepted; all-zero / partial-transparent / wrong size / empty rejected');

  // captureChecked：首张合格直接返回、不重拍；不合格重拍（新文件名）；3 次都不合格抛 FLAKE_CAPTURE_INVALID。
  const calls = [];
  const plan = [];
  const driver = {
    screenCapture: async (p, r) => { calls.push(p); const next = plan.shift(); if (next === false) return false; images.set(p, next); return true; },
    waitForIdle: async () => true, delayMs: async () => {}
  };
  plan.push(img(9, 9, [10, 20, 30, 255]));
  let s = await kit.captureChecked(driver, rect, 't');
  assert.equal(calls.length, 1);
  assert.deepEqual([...s.bytes.slice(0, 4)], [10, 20, 30, 255]);
  calls.length = 0;
  plan.push(img(9, 9, [0, 0, 0, 0]), false, img(9, 9, [200, 200, 200, 255]));
  s = await kit.captureChecked(driver, rect, 't');
  assert.equal(calls.length, 3);
  assert.equal(new Set(calls).size, 3, '每次重拍换文件名');
  assert.equal(s.bytes[0], 200);
  assert.match(kit.CAPTURE_RETAKES[kit.CAPTURE_RETAKES.length - 1], /ok@3 after alpha<255 81\/81; screenCapture=false/);
  calls.length = 0;
  plan.push(img(9, 9, [0, 0, 0, 0]), img(9, 9, [0, 0, 0, 0]), img(9, 9, [0, 0, 0, 0]), img(9, 9, [255, 255, 255, 255]));
  await assert.rejects(kit.captureChecked(driver, rect, 't'), /FLAKE_CAPTURE_INVALID t \[10,10,19,19\] alpha<255/);
  assert.equal(calls.length, 3, '有上限：最多 3 次');
  plan.length = 0;
  calls.length = 0;
  decodeFails = 1;
  plan.push(img(9, 9, [1, 2, 3, 255]), img(9, 9, [4, 5, 6, 255]));
  s = await kit.captureChecked(driver, rect, 't');
  assert.equal(s.bytes[0], 4);
  plan.length = 0;
  // 颜色不对（不透明、尺寸对）不重拍：判定留给调用方断言。
  calls.length = 0;
  plan.push(img(9, 9, [255, 0, 0, 255]), img(9, 9, [255, 255, 255, 255]));
  s = await kit.captureChecked(driver, rect, 't');
  assert.equal(calls.length, 1);
  assert.equal(s.bytes[1], 0);
  plan.length = 0;
  console.log('REFERENCE_ONLY captureChecked: valid first shot no retake; invalid/false/decode-error retaken with fresh file; bounded 3; wrong colour NOT retaken');

  // FU-HM-CAPTURE-REGION-BLACK（D10-1021，me12wc_16 胶囊底色 got 0/0/0）：整图合格但取色框（= 截的 rect）整块不透明纯黑 → 同 3 次内重拍；
  // 框里颜色不对（非全黑，含近黑 / 局部黑）不重拍；用尽仍黑把最后一张全黑图交给原断言（不抛、不吞）；整图无效照旧。
  assert.equal(kit.regionBlack(new kit.Shot(9, 9, img(9, 9, [0, 0, 0, 255]).bytes)), true);
  assert.equal(kit.regionBlack(new kit.Shot(9, 9, img(9, 9, [0, 0, 0, 0]).bytes)), false, '全 alpha 0 归 shotProblem 判整图无效');
  const oneLit = img(9, 9, [0, 0, 0, 255]); oneLit.bytes[40 * 4 + 2] = 1;
  assert.equal(kit.regionBlack(new kit.Shot(9, 9, oneLit.bytes)), false, '框里有一个像素不是纯黑就不算');
  assert.equal(kit.regionBlack(new kit.Shot(0, 0, new Uint8Array(0))), false);
  const hilog = [];
  const info = console.info;
  console.info = line => { hilog.push(String(line)); };
  try {
    const BLACK = [0, 0, 0, 255];
    const CHIP = [234, 244, 238, 255]; // status.success.background 浅
    // 框内全黑 → 重拍、第 2 次正常 → 用第 2 次。
    calls.length = 0; hilog.length = 0;
    plan.push(img(9, 9, BLACK), img(9, 9, CHIP), img(9, 9, [255, 255, 255, 255]));
    s = await kit.captureChecked(driver, rect, 'rb');
    assert.equal(calls.length, 2, '全黑重拍一次、第 2 张合格即停');
    assert.equal(new Set(calls).size, 2, '重拍换文件名');
    assert.deepEqual([...s.bytes.slice(0, 4)], CHIP, '用第 2 张');
    assert.deepEqual(hilog, ['FLKRIG capture retake rb #1 region-black 9x9'], 'hilog 现有 capture retake 轨迹、区分 region-black');
    assert.match(kit.CAPTURE_RETAKES[kit.CAPTURE_RETAKES.length - 1], /^rb ok@2 after region-black 9x9$/);
    plan.length = 0;
    // 框内全黑 3 次 → 有上限 3 次，最后一张全黑图交给原断言（不抛 FLAKE_CAPTURE_INVALID；断言照判 got 0/0/0 照红）。
    calls.length = 0; hilog.length = 0;
    const last = img(9, 9, BLACK);
    plan.push(img(9, 9, BLACK), img(9, 9, BLACK), last, img(9, 9, CHIP));
    s = await kit.captureChecked(driver, rect, 'rb');
    assert.equal(calls.length, 3, '全黑也有上限：最多 3 次');
    assert.equal(images.get(calls[2]), last);
    assert.equal(decodedFrom.get(s.bytes.buffer), calls[2], '交的是最后一张');
    assert.deepEqual([...s.bytes.slice(0, 4)], BLACK);
    assert.equal(hilog.filter(l => /^FLKRIG capture retake rb #[123] region-black 9x9$/.test(l)).length, 3);
    assert.match(kit.CAPTURE_RETAKES[kit.CAPTURE_RETAKES.length - 1], /^rb region-black handed@3 after region-black 9x9; region-black 9x9; region-black 9x9$/);
    plan.length = 0;
    // 混合：整图无效与全黑共用同一计数；用尽时有过全黑合格图 → 交最近那张；没有 → 照旧抛（下面「整图无效不回退」）。
    calls.length = 0;
    const mid = img(9, 9, BLACK);
    plan.push(img(9, 9, [0, 0, 0, 0]), mid, false, img(9, 9, CHIP));
    s = await kit.captureChecked(driver, rect, 'rb');
    assert.equal(calls.length, 3, '整图无效 + 全黑共 3 次');
    assert.equal(images.get(calls[1]), mid);
    assert.equal(decodedFrom.get(s.bytes.buffer), calls[1], '交最近一张全黑的合格图');
    plan.length = 0;
    calls.length = 0;
    plan.push(img(9, 9, [0, 0, 0, 0]), img(9, 9, BLACK), img(9, 9, CHIP));
    s = await kit.captureChecked(driver, rect, 'rb');
    assert.equal(calls.length, 3);
    assert.deepEqual([...s.bytes.slice(0, 4)], CHIP, '整图无效 → 全黑 → 正常：用第 3 张');
    plan.length = 0;
    // 框内是错色（非黑）→ 不重拍：错色、近黑 (1,1,1)、局部黑（一半纯黑一半错色）都交给断言。
    for (const wrong of [img(9, 9, [255, 0, 0, 255]), img(9, 9, [1, 1, 1, 255]), img(9, 9, [0, 0, 1, 255]), (() => {
      const half = img(9, 9, [200, 0, 0, 255]); half.bytes.fill(0, 0, 40 * 4); for (let i = 0; i < 40; i++) half.bytes[i * 4 + 3] = 255; return half;
    })()]) {
      calls.length = 0; hilog.length = 0;
      plan.push(wrong, img(9, 9, CHIP));
      s = await kit.captureChecked(driver, rect, 'rb');
      assert.equal(calls.length, 1, '框里颜色不对（非全黑）不重拍');
      assert.deepEqual([...s.bytes], [...wrong.bytes]);
      assert.deepEqual(hilog, []);
      plan.length = 0;
    }
    // 框外黑、框内正常 → 不重拍：替身屏幕整屏纯黑、只有请求的框里是胶囊底色，screenCapture 按 rect 裁。
    const W = 40, H = 40;
    const screen = img(W, H, BLACK);
    for (let y = rect.top; y < rect.bottom; y++) for (let x = rect.left; x < rect.right; x++) screen.bytes.set(CHIP, (y * W + x) * 4);
    const crops = [];
    const screenDriver = {
      screenCapture: async (p, r) => {
        crops.push(r);
        const w = r.right - r.left, h = r.bottom - r.top, out = new Uint8Array(w * h * 4);
        for (let y = 0; y < h; y++) out.set(screen.bytes.subarray(((r.top + y) * W + r.left) * 4, ((r.top + y) * W + r.right) * 4), y * w * 4);
        images.set(p, { w, h, bytes: out });
        return true;
      },
      waitForIdle: async () => true, delayMs: async () => {}
    };
    hilog.length = 0;
    s = await kit.captureChecked(screenDriver, rect, 'rb');
    assert.equal(crops.length, 1, '框外黑、框内正常不重拍');
    assert.deepEqual(hilog, []);
    assert.equal(s.width, 9);
    assert.deepEqual([...s.bytes.slice(0, 4)], CHIP);
    // 同一张屏、框挪到全黑处 → 框内全黑 → 有界 3 次后交给断言。
    crops.length = 0;
    s = await kit.captureChecked(screenDriver, { left: 25, top: 25, right: 34, bottom: 34 }, 'rb');
    assert.equal(crops.length, 3);
    assert.deepEqual([...s.bytes.slice(0, 4)], BLACK);
    // 整图无效不回退：全零 ×3 仍抛 FLAKE_CAPTURE_INVALID（不因新判据改交断言）；返回 false ×3 亦然。
    calls.length = 0;
    plan.push(img(9, 9, [0, 0, 0, 0]), img(9, 9, [0, 0, 0, 0]), img(9, 9, [0, 0, 0, 0]));
    await assert.rejects(kit.captureChecked(driver, rect, 'rb'), /FLAKE_CAPTURE_INVALID rb \[10,10,19,19\] alpha<255 81\/81; alpha<255/);
    assert.equal(calls.length, 3);
    plan.length = 0;
    calls.length = 0;
    plan.push(false, false, false);
    await assert.rejects(kit.captureChecked(driver, rect, 'rb'), /FLAKE_CAPTURE_INVALID rb .*screenCapture=false; screenCapture=false; screenCapture=false$/);
    plan.length = 0;
  } finally {
    console.info = info;
  }
  console.log('REFERENCE_ONLY region-black: all-black box retaken within same 3 (2nd ok used; 3x black handed to assertion, not thrown); wrong / near-black / partial-black colour NOT retaken; black outside box NOT retaken; whole-shot invalid still throws');

  // waitUntil：有上限；条件抛的异常照抛。
  let n = 0;
  const clock = { delayMs: async () => {} };
  assert.equal(await kit.waitUntil(clock, async () => ++n >= 3, 5000, 1), true);
  assert.equal(n, 3);
  const t0 = Date.now();
  assert.equal(await kit.waitUntil({ delayMs: ms => new Promise(r => setTimeout(r, ms)) }, async () => false, 60, 10), false);
  assert.ok(Date.now() - t0 < 1000);
  await assert.rejects(kit.waitUntil(clock, async () => { throw new Error('ASSERT_INSIDE'); }, 1000, 1), /ASSERT_INSIDE/);
  assert.equal(kit.isNoCandidates(new Error('Widget ... dose not exist on current UI! ...(NoCandidates)')), true);
  assert.equal(kit.isNoCandidates(new Error('DS02_UI_TASK_STOPPED')), false);
  assert.equal(kit.isNoCandidates(new Error('expect true, actualValue is false')), false);
  console.log('REFERENCE_ONLY waitUntil bounded, rethrows; isNoCandidates only matches UiTest NoCandidates');

  // 接线：Hm07vHomeRig.capture 经 captureChecked；FlakeKit 不 import 产品。
  const rig = fs.readFileSync(path.join(testDir, 'Hm07vHomeRig.ets'), 'utf8');
  const cap = rig.split('export async function capture(', 2)[1].split('\n}\n', 1)[0];
  assert.ok(cap.includes('captureChecked(driver, r,') && !cap.includes('screenCapture'), 'Hm07vHomeRig.capture 必须经 captureChecked');
  const kitSrc = fs.readFileSync(path.join(testDir, 'FlakeKit.ets'), 'utf8');
  assert.ok(!/from '(core|designsystem|generated)'/.test(kitSrc));
  // 诊断设施不得有让用例崩的可能：不挂 UiTest 原生回调（dev3 me12v_03 App died 后去掉）。
  // 评审 r1 S2-2：递归扫全仓所有 src/ohosTest 下的 .ets（含 pages / testability / testrunner、common/* 的 ohosTest），宽匹配。
  const banned = /\bUIEventObserver\b|createUIEventObserver\s*\(/;
  const ohosTestFiles = [];
  const walk = (dir, inTest) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (['node_modules', 'oh_modules', 'build', '.git', '.hvigor'].includes(e.name)) continue;
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full, inTest || (e.name === 'ohosTest' && path.basename(dir) === 'src'));
      else if (inTest && e.name.endsWith('.ets')) ohosTestFiles.push(full);
    }
  };
  walk(root, false);
  assert.ok(ohosTestFiles.some(f => f.endsWith('/testrunner/OpenHarmonyTestRunner.ets')) && ohosTestFiles.length > 40, '扫描范围须覆盖全部 ohosTest');
  for (const f of ohosTestFiles) {
    const code = fs.readFileSync(f, 'utf8').split('\n').filter(l => !/^\s*(\/\/|\*|\/\*)/.test(l)).join('\n');
    assert.ok(!banned.test(code), path.relative(root, f) + ' 不得用 UIEventObserver');
  }
  assert.ok(banned.test('const o: UIEventObserver = d.createUIEventObserver ();'), '匹配式自测');
  for (const f of ['Ds02Ui.test.ets', 'Ds02R1Ui.test.ets', 'Fx05aUi.test.ets']) {
    const src = fs.readFileSync(path.join(testDir, f), 'utf8');
    // 取像素的截屏都经 captureChecked；只存证据图（不取像素）的整屏截屏除外。
    const raw = src.split('\n').filter(l => l.includes('driver.screenCapture(') && !l.includes('screenCapture(evidence)'));
    assert.deepEqual(raw, [], f + ' 仍有直接取像素的 screenCapture');
  }
  // FU-HM-CAPTURE-REGION-BLACK：全仓 ohosTest 里调 screenCapture 的只有 FlakeKit.captureChecked 与 Ds02Ui 的整屏证据图（不取像素）——
  // 取色路径（meanRgb / colorIn / edgeRun / topLine / copyInk / inkLeft / patchShare / Fx05a / Ds02 / Ds02R1）都吃得到取色框全黑判据。
  const rawCaptures = [];
  for (const f of ohosTestFiles) {
    fs.readFileSync(f, 'utf8').split('\n').forEach((l, i) => {
      if (/screenCapture\s*\(/.test(l) && !/^\s*(\/\/|\*|\/\*)/.test(l)) rawCaptures.push(path.relative(root, f) + ':' + l.trim());
    });
  }
  assert.deepEqual(rawCaptures.sort(), ['entry/src/ohosTest/ets/test/Ds02Ui.test.ets:expect(await driver.screenCapture(evidence)).assertTrue();',
    'entry/src/ohosTest/ets/test/FlakeKit.ets:if (await driver.screenCapture(path, rect)) {'], '取像素的截屏只经 captureChecked');
  console.log('REFERENCE_ONLY wiring: pixel captures in Hm07vHomeRig / Ds02Ui / Ds02R1Ui / Fx05aUi go through captureChecked');

  // 接线（静态，只核「只改查找 / 等待、判据原样」）：
  const login = rig.split('export async function loginOnLoginPage(', 2)[1].split('\n}\n', 1)[0];
  assert.ok(login.includes("=== MEMBER_PHONE") && login.includes("settledEnabled(ON.id('login_get_code'), 3000)"), '点【获取验证码】前等输入落框、按钮稳定');
  assert.ok(login.includes('Date.now() + 13000') && login.includes('end = Date.now() + 10000'), '半屏 / 验证码同一轮等待，上限 3+10');
  assert.ok(login.includes("'HM07VA_MISSING 验证码输入 '") && login.includes(".assertEqual('验证码输入')"), '验证码输入框判据原样');
  assert.ok(login.includes("gone(ON.id('login_code'), 10000)") && login.includes("'HM07VA_LOGIN_NOT_FINISHED'"), '登录完成判据原样');
  assert.equal((login.match(/tap\(ON\.id\('login_get_code'\)/g) || []).length, 1, '【获取验证码】只点一次（不靠重试掩盖）');
  const me = fs.readFileSync(path.join(testDir, 'Me12vRig.ets'), 'utf8');
  const once = me.split('export async function opensExactlyOnce(', 2)[1].split('\n}\n', 1)[0];
  assert.equal((once.match(/pressBack\(\)/g) || []).length, 1, '「恰好打开一页」仍只按一次返回');
  assert.ok(once.includes("'ME12V_PUSHED_TWICE ' + what + ' 一次返回没回到「我的」页（打开了不止一页）'") && once.includes('navDepth()'));
  assert.ok(!once.split('pressBack()')[0].includes('navDepth('), '评审 r1 S2-5：按返回前不取组件树（成功路径不插延时）');
  const heal = rig.split('export async function ensureMemberHome(', 2)[1].split('\n}\n', 1)[0];
  assert.ok(heal.indexOf('await scrollTop();') >= 0 && heal.indexOf('await scrollTop();') < heal.indexOf("home_guest_value_login"), '补登录前先回顶部');
  assert.ok(heal.includes("console.info('HM07VA_SELF_HEAL"), '补登录留痕');
  assert.ok(heal.includes("maybe(ON.id('login_close'))") && heal.includes('throw e as Error'), '补登录失败关登录页再照样报红');
  const ds = fs.readFileSync(path.join(testDir, 'Ds02Ui.test.ets'), 'utf8');
  const before = ds.split('beforeAll(async', 2)[1].split('afterAll(', 1)[0];
  assert.ok(before.includes('attempt < 8') && before.includes('poll < 16') && before.includes('tries < 3'), 'beforeAll 有界：8 轮 × 16 次等首页、点入口 3 次');
  assert.ok(before.includes("isNoCandidates(e as Object)") && before.includes("await node('catalog-index')"), 'NoCandidates 计入本轮未找到；终点仍是真实目录');
  // v4（verify5）：容器消失计入本轮未找到；吸收只经 searchMiss（容器消失 / NoCandidates / 仅首页的 exhausted），其余照抛。
  assert.ok(before.includes('searchMiss(e as Object, true)') && before.includes("trail.push(attempt + ':' + miss)"), '首页查找：容器消失计本轮未找到并记 trail');
  assert.equal((before.match(/if \(miss === ''\) \{ throw /g) || []).length, 3, '三处吸收点其余异常照抛');
  const miss = ds.split('function searchMiss(', 2)[1].split('\n}\n', 1)[0];
  assert.ok(miss.includes("'DS02_UI_CONTAINER_GONE'") && miss.includes("return '';"), 'searchMiss 只认三类码');
  // v5（评审 r4 S2-1）：绿跑留痕只打印，在目录点击判定之后、终点之前。
  const log = before.indexOf("trace('DS02_BEFOREALL_TRAIL container_gone=");
  assert.ok(log > before.indexOf("'DS02_CATALOG_NOT_CLICKED '") && log < before.indexOf("await node('catalog-index')"), 'beforeAll 绿跑留痕');
  const sess = fs.readFileSync(path.join(testDir, 'Ds02UiSession.ets'), 'utf8');
  assert.equal((sess.match(/throw new Error\('DS02_UI_CONTAINER_GONE: /g) || []).length, 2, '容器找不到 / 零面积仍抛错（对其它调用方不放宽）');
  const trav = fs.readFileSync(path.join(testDir, 'Ds02Traversal.ets'), 'utf8');
  assert.ok(trav.includes("expect(seen.has(id) ? id : 'MISSING:' + id + how).assertEqual(id)"), 'MISSING 判据原样，只多带轨迹');
  assert.ok(trav.includes('Date.now() + 120000'), '遍历预算不变');
  console.log('REFERENCE_ONLY wiring: login waits only (single tap, same verdicts); one back press; DS beforeAll bounded; traversal verdict unchanged');
  console.log('FLAKE logic: all passed');
})().catch(e => { console.error(e); process.exit(1); });
