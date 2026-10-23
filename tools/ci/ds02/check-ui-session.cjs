// 只验证真实会话设施的异步顺序；延迟的原生调用是替身，不代表设备已通过。
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const tick = () => new Promise(resolve => setImmediate(resolve));

module.exports = async ({ load, testRoot, beforeEachHooks, afterEachHooks, driver, driverProxy, ON }) => {
  const session = load(path.join(testRoot, 'Ds02UiSession.ets'));
  // 使用本机 Hypium 的实际超时包裹函数：它 reject 框架等待，但不会取消原 async 函数。
  const sdk = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
  const service = fs.readFileSync(path.join(sdk,
    'default/openharmony/ets/build-tools/ets-loader/node_modules/@ohos/hypium/src/service.js'), 'utf8');
  const timeoutSource = service.split('function getFuncWithArgsZero(', 2)[1].split('\nfunction getFuncWithArgsOne(', 1)[0];
  assert.ok(timeoutSource && timeoutSource.includes('execute timeout'));
  const hypiumTimeout = vm.runInThisContext('(function getFuncWithArgsZero(' + timeoutSource + ')');
  for (const ending of ['success', 'transport-error']) {
    const search = deferred();
    const entered = deferred();
    const cleanup = deferred();
    let busy = false;
    let idleCalls = 0;
    let continued = false;
    let cleanupEntered = false;
    let nextStarted = false;
    const events = [];
    driver({ waitForIdle: async () => {
      assert.equal(busy, false, 'waitForIdle must not race a pending swipe');
      idleCalls++; events.push('idle'); return true;
    } });
    const searchDriver = {
      findComponent: async selector => selector.idValue === 'container' ? { getBounds: async () => ({ left: 0, right: 500, top: 0, bottom: 1000 }) } : undefined,
      swipe: async () => {
      busy = true; entered.resolve(); events.push('search');
      try { return await search.promise; }
      finally { busy = false; events.push('native-ended'); }
    }, waitForIdle: async () => assert.fail('stopped search must not issue idle') };
    let observed;
    const timed = hypiumTimeout(async () => {
      const running = session.runUiTask(driverProxy, async () => {
        try {
          await session.searchUiComponent(searchDriver, ON.id('container'), ON.id('old'));
          continued = true;
        } finally {
          cleanupEntered = true;
          await cleanup.promise;
          events.push('finally-ended');
        }
      });
      observed = running.then(() => 'resolved', error => error.message);
      await running;
    }, 5, false);
    await entered.promise;
    await assert.rejects(timed, /execute timeout 5ms/);
    const endingHook = afterEachHooks[0]();
    await tick();
    assert.equal(idleCalls, 1);
    const next = session.runUiTask(driverProxy, async () => {
      nextStarted = true; events.push('next');
    });
    await tick();
    assert.equal(nextStarted, false);
    if (ending === 'success') search.resolve({}); else search.reject(new Error('SWIPE_TRANSPORT_ERROR'));
    await tick();
    assert.equal(cleanupEntered, true);
    assert.equal(nextStarted, false, 'must wait the whole body including asynchronous finally');
    assert.equal(idleCalls, 1, 'native completion alone is not full task completion');
    cleanup.resolve();
    await endingHook;
    await next;
    assert.equal(continued, false);
    assert.match(await observed, ending === 'success' ? /DS02_UI_TASK_STOPPED/ : /SWIPE_TRANSPORT_ERROR/);
    assert.ok(events.indexOf('finally-ended') < events.indexOf('next'));
    await beforeEachHooks[0]();
    await beforeEachHooks[1]();
    await afterEachHooks[1]();
    console.log('REFERENCE_ONLY v7d timeout + ' + ending + ': no concurrent idle/next call; await native + finally; old body stops; next case recovers');
  }

  // 即使钩子也被框架超时、不等待它就进入下一条，队列仍不向忙碌的 SDK 发调用。
  const blocked = deferred();
  const entered = deferred();
  let busy = false;
  let secondRan = false;
  let idleCalls = 0;
  driver({ waitForIdle: async () => { assert.equal(busy, false); idleCalls++; return true; } });
  const old = session.runUiTask(driverProxy, async () => {
    await session.searchUiComponent({
      findComponent: async selector => selector.idValue === 'container' ? { getBounds: async () => ({ left: 0, right: 500, top: 0, bottom: 1000 }) } : undefined,
      swipe: async () => {
      busy = true; entered.resolve(); await blocked.promise; busy = false; return {};
    }, waitForIdle: async () => assert.fail('stopped search must not issue idle') }, ON.id('container'), ON.id('blocked'));
  });
  const oldOutcome = old.catch(error => error.message);
  await entered.promise;
  const firstDrain = afterEachHooks[0]();
  const firstOutcome = firstDrain.catch(error => error.message);
  const queued = session.runUiTask(driverProxy, async () => { secondRan = true; });
  const queuedOutcome = queued.catch(error => error.message);
  const secondDrain = afterEachHooks[0]();
  await tick();
  assert.equal(idleCalls, 1);
  assert.equal(secondRan, false);
  blocked.resolve();
  await secondDrain;
  for (const result of [await oldOutcome, await firstOutcome, await queuedOutcome]) assert.match(result, /DS02_UI_TASK_STOPPED/);
  assert.equal(secondRan, false, 'already-ended queued case must never start later');
  assert.equal(idleCalls, 2);
  console.log('REFERENCE_ONLY v7d nested timeout: pending native call blocks all SDK probes; expired queued body never starts');

  let bodyRan = false;
  driver({ waitForIdle: async () => false });
  await assert.rejects(session.runUiTask(driverProxy, async () => { bodyRan = true; }), assert.AssertionError);
  assert.equal(bodyRan, false);
  await assert.rejects(beforeEachHooks[0](), assert.AssertionError);
  await assert.rejects(afterEachHooks[0](), assert.AssertionError);
  driver({ waitForIdle: async () => { throw new Error('IDLE_TRANSPORT_ERROR'); } });
  await assert.rejects(session.runUiTask(driverProxy, async () => { bodyRan = true; }), /IDLE_TRANSPORT_ERROR/);
  assert.equal(bodyRan, false);
  driver({ waitForIdle: async () => true });
  await assert.rejects(session.runUiTask(driverProxy, async () => { throw new Error('ASSERTION_FAILURE'); }), /ASSERTION_FAILURE/);
  await afterEachHooks[0]();
  await session.runUiTask(driverProxy, async () => { bodyRan = true; });
  assert.equal(bodyRan, true);
  console.log('REFERENCE_ONLY v7c idle false/throw and body failure remain red; later task recovers after drain');
};
