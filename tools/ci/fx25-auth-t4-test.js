// F-X-25 t4（评审新 r1 之后；新鲜独立 Claude 测试作者，D10-104）：NR1-01 / NR1-04 的 Node 用例。
// 依据：review-harmony-new-r1.md NR1-01 / NR1-04、D10-385（照 Android D10-310 F 路径：隔离起可信容器拒绝全部子资源、拆后宽限 2 s
// 再清 Cookie 并读回复核、隔离前已在途请求的残余风险写进交回、beacon / keepalive 设备用例作合并门槛）。
// 同一条生产链路：真实 ApiClient → AppBridge → TrustedAuthSync → TrustedWebView 生命周期；测试不调 sync / reload / 清理接口，只经
// 夹具的系统模型：p.intercept（系统把一个资源请求交给生产 onInterceptRequest）、端口的 Cookie 读回与 lateCookie（迟到响应的
// Set-Cookie 落进共用 Cookie 库）、假时钟的宽限模型（holdGrace / releaseGrace，只管生产 TrustedAuthSync.COOKIE_GRACE_MS 那一个
// 计时器）、p.holdDisappear（旧控制器已解绑、onDisAppear 还没到）。
//
// 接口约定（以实现者交回为准；t4 写时实现者还在改，按 impl 进行中的写法定）：
// - TrustedAuthSync.COOKIE_GRACE_MS（≥ 2000）：拆完（两信号到齐）之后、清 Cookie 之前等这么久；计时器在 core 里设（setTimeout）。
// - TrustedAuthStore.cookiesRemain(): boolean：清完读回（TrustedWebProfile 用 WebCookieManager 的读回接口，非无痕）；读不出抛错。
// - TrustedWebView 的 onInterceptRequest：隔离中对子资源（以及非入口的主框架请求）回本地 403；reload 之后入口的主框架加载放行。
'use strict';
const assert = require('assert');
const path = require('path');
const { Ports, turn, withClock } = require('./fx25-v3-ports');
const ENTRY = 'https://h5.example.test';
const KINDS = ['cookie', 'local', 'indexedDB', 'cache'];
const LATE = 'fx25_late=user-a';
module.exports = function (environment) {
  const { hypium, root } = environment;
  const { fixture, core, teardownOrder, resourceRequest } = require('./fx25-native-auth-test')({ ...environment, registerLegacy: false });
  const Sync = require(path.join(root, 'common/core/src/main/ets/bridge/TrustedAuthSync.ets')).TrustedAuthSync;
  const journals = [];
  const made = [];
  function make(options = {}) {
    const ports = options.ports || new Ports();
    journals.push(ports.journal);
    const f = fixture({ ...options, ports });
    made.push(f);
    return f;
  }
  async function completed(promiseOrPage) {
    try {
      return await (typeof promiseOrPage.then === 'function' ? promiseOrPage : promiseOrPage.config.whenAuthSettled());
    } catch (_error) { return false; }
  }
  async function turns(n = 20) { for (let i = 0; i < n; i++) await turn(); }
  async function until(check, n = 200) { for (let i = 0; i < n && !check(); i++) await turn(); return check(); }
  function isolated(p, value = true) {
    assert.strictEqual(typeof p.config.isAuthIsolated, 'function', 'required production observer: TrustedWebConfig.isAuthIsolated()');
    assert.strictEqual(p.config.isAuthIsolated(), value, p.name + ': isolation');
  }
  async function bridgeCalls(p) {
    let calls = 0;
    p.config.host.register('app.getEnv', () => { calls++; return core.BridgeResult.ok('{}'); });
    p.lifecycle.transport.nativeObject.post(p.lifecycle.transport.session.currentToken(),
      JSON.stringify({ v: 1, id: 't4-probe-' + p.scripts.length, method: 'app.getEnv', params: {} }));
    await turn();
    return calls;
  }
  /** 接口约定：宽限常量存在且不短于 D10-385 的 2 s；夹具已接管这个计时器。 */
  function grace() {
    assert.ok(Sync, 'production TrustedAuthSync');
    assert.strictEqual(typeof Sync.COOKIE_GRACE_MS, 'number',
      'required production interface: TrustedAuthSync.COOKIE_GRACE_MS (NR1-01 / D10-385: wait after teardown before clearing cookies)');
    assert.ok(Sync.COOKIE_GRACE_MS >= 2000, 'D10-385: grace is at least 2 s (' + Sync.COOKIE_GRACE_MS + ')');
    return Sync.COOKIE_GRACE_MS;
  }
  const cookieClears = f => f.ports.signal('cookie').calls;
  const cookieDone = f => f.ports.signal('cookie').completed;
  /** 非无痕的读回：在最后一次 Cookie 清理完成之后读过、读到的是空。 */
  function readBackClean(f) {
    const trusted = f.ports.readbacks.filter(r => !r.incognito);
    assert.ok(trusted.length > 0, 'cookies were read back after clearing (NR1-01 re-check)');
    const last = trusted[trusted.length - 1];
    assert.strictEqual(last.clears, cookieDone(f), 'the final read-back happened after the final cookie clear');
    assert.strictEqual(last.value, '', 'the final read-back is empty');
  }
  function reloadsClean(p) {
    assert.ok(p.reloads.length > 0, p.name + ': production reloaded the entry');
    for (const r of p.reloads) assert.strictEqual(r.cookie, '', p.name + ': no cookie at entry load (new account request): ' + JSON.stringify(r));
  }
  function failedClosed(f, p) {
    assert.strictEqual(p.reloads.length, 0, 'no entry load after an unverified cookie clear');
    for (const inst of p.instances) for (const realm of inst.documents) {
      if (realm.alive) assert.strictEqual(realm.origin, 'null', 'only a blank carrier may stay mounted after failure: ' + realm.url);
    }
    assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker kept');
    isolated(p);
    assert.strictEqual(p.lifecycle.errorVisible(), true, 'retryable error page');
  }
  const refused = response => response !== null && response !== undefined && response.code === 403 && response.ready === true;
  /** 旧文档在隔离之后会发的子资源（beacon / keepalive / XHR / 图片 / 脚本 / 样式）与一条非入口的主框架请求。 */
  const isolatedRequests = () => [
    ['beacon', resourceRequest(ENTRY + '/fx25-late?beacon=1', { method: 'POST', dest: 'empty' })],
    ['keepalive', resourceRequest(ENTRY + '/fx25-late?keepalive=1', { method: 'POST', dest: 'empty' })],
    ['xhr', resourceRequest(ENTRY + '/fx25-tick', { dest: 'empty' })],
    ['no-dest', resourceRequest(ENTRY + '/fx25-late?nodest=1', { method: 'POST', dest: null })],
    ['image', resourceRequest(ENTRY + '/pixel.gif', { dest: 'image' })],
    ['script', resourceRequest(ENTRY + '/app.js', { dest: 'script' })],
    ['style', resourceRequest(ENTRY + '/app.css', { dest: 'style' })],
    ['cross-origin', resourceRequest('https://collector.example.test/beacon', { method: 'POST', dest: 'empty' })],
    ['main-frame', resourceRequest(ENTRY + '/elsewhere', { mainFrame: true, dest: 'document' })],
    ['unreadable', resourceRequest(ENTRY + '/x', { unreadable: true })]
  ];
  function test(name, run) {
    hypium.it(name, 0, async () => {
      const start = journals.length;
      const first = made.length;
      try {
        await withClock(run);
        for (const f of made.slice(first)) assert.deepStrictEqual(f.globalCalls(), [], 'I6: no global / incognito clear, ever');
      } finally {
        made.splice(first);
        for (const journal of journals.splice(start)) journal.dispose();
      }
    });
  }
  hypium.describe('AuthT4_FX25', () => {
    // ---------- NR1-01 (1)：隔离起，可信容器的所有子资源都回本地 403；只有 reload 之后入口的主框架加载放行 ----------
    test('T4_I1_isolated_trusted_container_refuses_every_subresource_until_the_new_document', async () => {
      const f = make(), p = f.open('beacon'), q = f.open('second');
      const clock = f.ports.clock;
      // 对照：隔离之前同样的请求放行（不拦）——拦截不是一直开着的。
      for (const page of [p, q]) {
        for (const [kind, request] of isolatedRequests().filter(([k]) => k !== 'unreadable')) {
          assert.strictEqual(page.intercept(request), null, page.name + ': before isolation ' + kind + ' is not intercepted');
        }
      }
      clock.holdGrace();
      let releaseA;
      f.holdEvents(new Promise(resolve => { releaseA = resolve; }));
      const entryProbes = [];
      for (const page of [p, q]) {
        page.loadHooks.push(url => {
          // 系统也会把 reload 之后入口的主框架请求交给 onInterceptRequest：它必须放行，否则新文档永远出不来。
          entryProbes.push({ page: page.name, response: page.intercept(resourceRequest(url, { mainFrame: true, dest: 'document' })) });
        });
      }
      f.logout();
      // 同一同步步骤里已隔离；A 还在旧文档里执行（旧 Web 还挂着），这时旧文档发出的任何请求都要被拒。
      isolated(p); isolated(q);
      assert.strictEqual(p.instances[0].unmounted, false, 'non-vacuous: the old Web is still mounted while A runs');
      for (const page of [p, q]) {
        for (const [kind, request] of isolatedRequests()) {
          assert.ok(refused(page.intercept(request)), page.name + ': isolated ' + kind + ' request refused with a local 403');
        }
      }
      releaseA();
      assert.ok(await until(() => clock.gracePending() > 0), 'teardown done, carrier mounted, grace running');
      // 宽限期里（载体已挂上、旧文档已销毁）：载体上同样一律拒绝。
      assert.ok(p.inst && p.inst.controller.attached && p.inst.src === 'about:blank', 'non-vacuous: carrier attached');
      for (const page of [p, q]) {
        for (const [kind, request] of isolatedRequests()) {
          assert.ok(refused(page.intercept(request)), page.name + ': ' + kind + ' refused during the grace');
        }
      }
      clock.releaseGrace();
      await f.settled();
      assert.ok(entryProbes.length >= 2, 'non-vacuous: the entry was loaded on both pages');
      for (const probe of entryProbes) assert.strictEqual(probe.response, null, probe.page + ': the entry main-frame load is let through');
      isolated(p, false); isolated(q, false);
      // 新文档解除隔离之后照常放行（不把容器永久封死）。
      for (const page of [p, q]) {
        for (const [kind, request] of isolatedRequests().filter(([k]) => k !== 'unreadable')) {
          assert.strictEqual(page.intercept(request), null, page.name + ': after the new document ' + kind + ' is not intercepted');
        }
      }
    });
    // ---------- NR1-01 (2)：拆完之后宽限 COOKIE_GRACE_MS 再清；宽限期内落地的迟到 Set-Cookie 被随后的清理抹掉 ----------
    test('T4_G1_cookie_clear_waits_the_grace_after_teardown_and_a_late_set_cookie_inside_it_is_wiped', async () => {
      grace();
      const f = make(), p = f.open('grace');
      const clock = f.ports.clock;
      clock.holdGrace();
      clock.onGrace = event => f.timeline.push('grace:' + event);
      const old = p.controller;
      f.logout();
      assert.ok(await until(() => clock.gracePending() === 1), 'one grace timer running');
      await turns(40);
      assert.ok(p.instances[0].unmounted && old.dead, 'non-vacuous: old Web torn down (both signals) before the grace');
      assert.ok(p.inst && p.inst.controller !== old && p.inst.controller.attached, 'carrier attached');
      assert.strictEqual(cookieClears(f), 0, 'no cookie clear inside the grace');
      assert.strictEqual(p.reloads.length, 0, 'no entry load inside the grace');
      isolated(p);
      assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker on disk during the grace');
      // 隔离之前已在途的 keepalive / beacon：响应的 Set-Cookie 在宽限期里落地。
      f.ports.lateCookie(LATE);
      assert.strictEqual(clock.releaseGrace(), 1);
      assert.strictEqual(await completed(p), true);
      await turns();
      reloadsClean(p);
      readBackClean(f);
      const at = entry => f.timeline.indexOf(entry);
      const start = at('grace:start'), end = at('grace:end');
      const firstCookie = f.timeline.findIndex(x => x === 'op:cookie:entered');
      assert.ok(at(p.name + ':unbound#' + old.id) < start && at(p.name + ':unmount#' + old.id) < start,
        'grace starts after both teardown signals :: ' + f.timeline.join(' '));
      assert.ok(start < end && end < firstCookie, 'cookies are cleared only after the grace has elapsed');
      isolated(p, false);
      assert.strictEqual(f.ports.journal.readPending(), null);
    });
    test('T4_G2_grace_does_not_start_before_teardown_completes', async () => {
      grace();
      for (const hold of ['holdUnmount', 'holdUnbind', 'holdDisappear']) {
        const f = make(), p = f.open('grace-' + hold);
        const clock = f.ports.clock;
        clock.holdGrace();
        p[hold] = true;
        const before = clock.graces;
        f.logout();
        await turns(60);
        assert.strictEqual(clock.graces - before, 0, hold + ': no grace timer while a teardown signal is missing');
        assert.strictEqual(cookieClears(f), 0, hold + ': no cookie clear');
        p[hold] = false;
        if (hold === 'holdUnmount') p.releaseUnmount();
        if (hold === 'holdUnbind') p.releaseUnbind();
        if (hold === 'holdDisappear') p.releaseDisappear();
        assert.ok(await until(() => clock.gracePending() === 1), hold + ': grace starts once teardown completes');
        clock.releaseGrace();
        assert.strictEqual(await completed(p), true, hold + ': completes');
        reloadsClean(p);
      }
    });
    // ---------- NR1-01 (3)：清完读回；读回非空就再清；最后一次读回为空才放行 ----------
    test('T4_R1_set_cookie_landing_right_after_clear_is_read_back_and_cleared_again', async () => {
      const f = make(), p = f.open('reclear');
      let landed = 0;
      f.ports.afterCookieClear = n => { if (n === 1) { landed++; f.ports.lateCookie(LATE); } };
      f.logout();
      assert.strictEqual(await completed(p), true, 'a late cookie caught by the read-back is cleared again, then the switch completes');
      await turns();
      assert.strictEqual(landed, 1, 'non-vacuous: a late Set-Cookie landed right after the first clear');
      assert.ok(f.ports.readbacks.some(r => !r.incognito && r.clears === 1 && r.value.includes(LATE)),
        'the read-back after the first clear saw the late cookie');
      assert.ok(cookieDone(f) >= 2, 'cookies cleared again after the dirty read-back');
      readBackClean(f);
      reloadsClean(p);
      isolated(p, false);
    });
    test('T4_R2_cookie_that_keeps_coming_back_fails_closed_after_bounded_rounds_then_retry_recovers', async () => {
      const f = make(), p = f.open('persistent');
      f.ports.afterCookieClear = () => f.ports.lateCookie(LATE);
      await f.login();
      assert.strictEqual(await completed(p), false, 'read-back never clean → the switch fails');
      await turns();
      assert.ok(cookieDone(f) >= 2, 'non-vacuous: it did try again');
      assert.ok(cookieClears(f) <= 10, 'bounded number of clear rounds (' + cookieClears(f) + ')');
      failedClosed(f, p);
      assert.strictEqual(await bridgeCalls(p), 0);
      f.ports.afterCookieClear = null;
      assert.strictEqual(await completed(p.config.retryAuth()), true, 'retry recovers once nothing lands any more');
      await turns();
      reloadsClean(p);
      readBackClean(f);
      isolated(p, false);
      assert.strictEqual(f.ports.journal.readPending(), null);
    });
    test('T4_R3_cookie_read_back_failure_fails_closed_then_retry_recovers', async () => {
      const f = make(), p = f.open('unreadable');
      f.ports.readbackFault = 'throw';
      await f.login();
      assert.strictEqual(await completed(p), false, 'read-back cannot confirm → the switch fails (I2)');
      await turns();
      assert.ok(f.ports.readbacks.some(r => r.value === 'THROW'), 'non-vacuous: read-back was attempted and failed');
      failedClosed(f, p);
      assert.strictEqual(await bridgeCalls(p), 0);
      f.ports.readbackFault = '';
      assert.strictEqual(await completed(p.config.retryAuth()), true);
      await turns();
      reloadsClean(p);
      readBackClean(f);
    });
    // ---------- NR1-04：双信号缺一（已解绑、onDisAppear 还没到）：四类清理都不动 ----------
    test('T4_D1_unbound_but_disappear_not_yet_delivered_blocks_every_clear', async () => {
      const f = make(), a = f.open('visible'), b = f.open('second');
      const oldB = b.controller;
      b.holdDisappear = true;
      f.logout();
      await turns(60);
      assert.ok(b.pendingDisappears.length > 0, 'non-vacuous: production removed the old Web of the second page from build');
      assert.strictEqual(oldB.dead, true, 'its old controller is already unbound (17100001)');
      assert.strictEqual(b.disappears, 0, 'but its onDisAppear has not arrived');
      assert.ok(b.instances[0].documents.some(realm => realm.alive), 'and its old document is still alive');
      for (const kind of KINDS) assert.strictEqual(f.ports.signal(kind).calls, 0, kind + ': not cleared while onDisAppear is missing');
      assert.strictEqual(a.reloads.length + b.reloads.length, 0, 'nothing reloaded');
      isolated(a); isolated(b);
      assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker on disk');
      b.holdDisappear = false;
      assert.strictEqual(b.releaseDisappear(), 1);
      await f.settled();
      teardownOrder(f, b, oldB);
      reloadsClean(a); reloadsClean(b);
      isolated(a, false); isolated(b, false);
    });
  });
};
