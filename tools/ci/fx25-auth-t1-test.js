// F-X-25 t1（新方案「先拆后清再建」，D10-277 / D10-279；新鲜独立 Claude 测试作者）：plan-teardown.md 附表 C 的 N1–N7。
// 与 v3 / v6 / v7 同一条生产链路：真实 ApiClient → AppBridge → TrustedAuthSync → TrustedWebView 生命周期；测试不调 sync.changed /
// attach / cleanAndReload，不替产品补监听、补清理或补重载。夹具（fx25-native-auth-test.js）按 Web 实例建模：卸下 = onDisAppear +
// 旧控制器解绑（之后抛 17100001），新实例 = 新 sessionStorage 命名空间，控制器只看生产 build() 里 Web 实际绑定的那个。
//
// 「事务监视」watch(f)：切号之前布防，之后每一项清理（Cookie / DOM / IndexedDB / 缓存）进入系统接口的那一刻、每一次 loadUrl、每一段
// 脚本、删待清标记的那一刻都核对（任一不符记一条违规，用例最后要求为空）：
//   I1-a 切号前的每一份文档都已销毁；I1-b 切号前的每一个控制器都已解绑（不能再被挂到新 Web 上）；
//   I1-c 切号后旧文档里除了 auth.changed 不执行任何脚本（旧文档上不做任何清理）；I1-d 所有在开页面都在隔离中；
//   载体：至少一页挂着「新控制器 + about:blank + 已 attach」的 Web；删标记之前不加载任何可信地址；
//   I2：loadUrl 之前四类存储在本事务里都已真实完成；loadUrl 只在新控制器上、盘上没有待清标记；令牌只交给标记已删后的可信新文档。
'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Ports, DiskJournal, DiskOwnerRecord, turn, withClock, enableSandbox, disableSandbox } = require('./fx25-v3-ports');
const ENTRY = 'https://h5.example.test';
// t6（D10-396）：HTTP 缓存不再是切号清理项（ArkWeb 只有全应用级缓存清理，会波及外部 / 隐私页，I6）；watch() 改为「缓存清理一旦进入即违规」。
const KINDS = ['cookie', 'local', 'indexedDB'];
const isA = value => value === 'user-a' || value === 'old-user-rewritten';
module.exports = function (environment) {
  const { hypium, root } = environment;
  const { fixture, core, eventOnce, teardownOrder } = require('./fx25-native-auth-test')({ ...environment, registerLegacy: false });
  const journals = [];
  const made = [];
  const sandboxes = [];
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
  function isolated(p, value = true) {
    assert.strictEqual(typeof p.config.isAuthIsolated, 'function', 'required production observer: TrustedWebConfig.isAuthIsolated()');
    assert.strictEqual(p.config.isAuthIsolated(), value, p.name + ': isolation');
  }
  async function bridgeCalls(p, token = p.lifecycle.transport.session.currentToken(), native = p.lifecycle.transport.nativeObject) {
    let calls = 0;
    p.config.host.register('app.getEnv', () => { calls++; return core.BridgeResult.ok('{}'); });
    native.post(token, JSON.stringify({ v: 1, id: 't1-probe-' + p.scripts.length, method: 'app.getEnv', params: {} }));
    await turn();
    return calls;
  }
  const dirty = load => load.cookie !== '' || load.local.length > 0 || load.indexedDB.length > 0 || // t6：缓存不算脏（D10-396）
    (load.session || []).some(([, value]) => isA(value));
  function recoveredClean(f, p) {
    assert.ok(p.reloads.length > 0, p.name + ': production reloaded the entry');
    for (const r of p.reloads) assert.ok(!dirty(r), p.name + ': clean at load entry: ' + JSON.stringify(r));
    for (const [origin, values] of p.origins) assert.ok(![...values.values()].some(isA), p.name + ': ' + origin + ' sessionStorage');
    isolated(p, false);
    assert.strictEqual(f.ports.journal.readPending(), null, 'marker removed');
  }
  /** 事务监视（见文件头）。在切号之前调用；check() 断言没有违规。 */
  function watch(f) {
    const pages = f.pages.filter(p => !p.closed);
    const oldControllers = new Set(f.controllers);
    const oldRealms = new Set(pages.flatMap(p => p.documents));
    const start = Object.fromEntries(KINDS.map(kind => [kind, f.ports.signal(kind).completed]));
    const w = { violations: [], clears: 0, loads: 0, tokens: 0 };
    const v = message => { if (!w.violations.includes(message)) w.violations.push(message); };
    const carrier = () => f.pages.some(p => !p.closed && p.inst && !oldControllers.has(p.inst.controller) && p.inst.controller.attached &&
      p.inst.src === 'about:blank' && (!p.inst.current || p.inst.current.origin === 'null'));
    const trustedNewDocument = () => f.pages.some(p => !p.closed && p.inst && !oldControllers.has(p.inst.controller) &&
      p.inst.current && p.inst.current.alive && p.inst.current.origin !== 'null');
    f.ports.enteredHooks.push(kind => {
      // t6（D10-396）：任何时候进入缓存清理（removeCache / removeAllCache）都是违规，不论标记在不在。
      if (kind === 'cache') { v('D10-396 / I6: an HTTP cache clear API was entered (app-wide, reaches the external / incognito Web)'); return; }
      // 标记删掉之后的清理不属于这个事务（例如另一页晚挂上的载体把留下的缓存任务做完）：不会泄露，只是多清一次，这里不核对。
      if (f.ports.journal.readPending() === null) return;
      w.clears++;
      for (const realm of oldRealms) if (realm.alive) v('I1-a: ' + kind + ' clear entered while a pre-switch document is alive (' + realm.url + ')');
      for (const c of oldControllers) {
        if (c.inst && c.attached && !c.dead) v('I1-b: ' + kind + ' clear entered while pre-switch controller #' + c.id + ' still answers (no 17100001)');
      }
      for (const p of f.pages.filter(x => !x.closed)) if (!p.config.isAuthIsolated()) v('I1-d: ' + p.name + ' not isolated during ' + kind + ' clear');
      if (!carrier()) v('carrier: ' + kind + ' clear entered without an attached carrier (new controller + about:blank)');
      if (trustedNewDocument()) v('carrier: a trusted document was loaded before ' + kind + ' was cleared');
    });
    for (const p of pages) {
      p.loadHooks.push((url, c) => {
        w.loads++;
        if (f.ports.journal.readPending() !== null) v('I2: ' + p.name + ' loadUrl(' + url + ') while the pending marker is still on disk');
        if (oldControllers.has(c)) v('new controller: ' + p.name + ' loadUrl on pre-switch controller #' + c.id);
        for (const kind of KINDS) if (f.ports.signal(kind).completed <= start[kind]) v('I2: ' + p.name + ' loadUrl before ' + kind + ' completed in this transaction');
      });
      p.scriptHooks.push((script, c, realm) => {
        if (realm && oldRealms.has(realm) && !script.includes('auth.changed')) v('I1-c: script executed in a pre-switch document: ' + script.slice(0, 60));
        if (script.includes('__couliBridgeToken(')) {
          w.tokens++;
          if (f.ports.journal.readPending() !== null) v('I1: token delivered to ' + p.name + ' while the pending marker is on disk');
          if (!realm || realm.origin === 'null' || oldRealms.has(realm)) v('I1: token delivered to a blank / pre-switch document of ' + p.name);
        }
      });
    }
    const remove = f.ports.journal.clearPending.bind(f.ports.journal);
    f.ports.journal.clearPending = () => {
      if (trustedNewDocument()) v('carrier: a trusted address was loaded before the pending marker was removed');
      if (f.ports.mark) f.ports.mark('marker:removed');
      return remove();
    };
    w.check = () => assert.deepStrictEqual(w.violations, [], 'transaction watch :: ' + w.violations.join(' | '));
    return w;
  }
  function test(name, run) {
    hypium.it(name, 0, async () => {
      const start = journals.length;
      const first = made.length;
      try {
        await withClock(run);
        for (const f of made.slice(first)) assert.deepStrictEqual(f.globalCalls(), [], 'I6: no global / incognito clear, ever');
      } finally {
        disableSandbox();
        made.splice(first);
        for (const journal of journals.splice(start)) journal.dispose();
        for (const dir of sandboxes.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
      }
    });
  }
  const tokenB = () => new core.SessionTokenSet('access-b', 'refresh-b', 'full', 'user-b', 'epoch-b');
  hypium.describe('AuthT1_FX25', () => {
    // ---------- N1 拆在清之前：任一页两信号缺一，四类清理都不动 ----------
    for (const hold of ['unmount', 'unbind']) {
      test('N1_teardown_before_clear_' + hold + '_signal_held_blocks_every_clear', async () => {
        const f = make(), a = f.open('visible'), b = f.open('second');
        const old = [a.controller, b.controller];
        const w = watch(f);
        if (hold === 'unmount') b.holdUnmount = true; else b.holdUnbind = true;
        f.logout();
        await turns(40);
        if (hold === 'unmount') {
          assert.ok(b.pendingUnmounts.length > 0, 'non-vacuous: production removed the old Web of the second page from build');
          assert.strictEqual(b.disappears, 0, 'its onDisAppear has not arrived');
        } else {
          assert.ok(b.disappears > 0, 'non-vacuous: onDisAppear arrived');
          assert.ok(b.pendingUnbinds.length > 0, 'but the old controller still answers (no 17100001 yet)');
        }
        assert.strictEqual(f.ports.clearCalls(), 0, 'I1: no Cookie / DOM / IndexedDB / cache clear while any trusted page lacks a teardown signal');
        for (const p of [a, b]) { assert.strictEqual(p.reloads.length, 0, p.name + ': no reload'); isolated(p); }
        assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker on disk');
        if (hold === 'unmount') { b.holdUnmount = false; assert.ok(b.releaseUnmount() > 0); }
        else { b.holdUnbind = false; assert.ok(b.releaseUnbind() > 0); }
        assert.strictEqual(await completed(a), true, 'cleanup proceeds once both signals have arrived');
        await turns();
        for (const p of [a, b]) recoveredClean(f, p);
        [a, b].forEach((p, i) => teardownOrder(f, p, old[i]));
        w.check();
      });
    }
    // ---------- N2 拆完之前旧文档没有执行机会；旧代理对象作废 ----------
    test('N2_old_documents_get_no_execution_and_old_proxy_is_dead_after_teardown', async () => {
      const f = make(), p = f.open('visible'), q = f.open('covered');
      const oldNatives = [p, q].map(x => x.lifecycle.transport.nativeObject);
      const oldTokens = [p, q].map(x => x.lifecycle.transport.session.currentToken());
      assert.ok(oldTokens.every(t => t.length > 0), 'precondition: both old documents had a token');
      const w = watch(f);
      await f.login();
      assert.strictEqual(await completed(p), true); await turns();
      assert.ok(w.clears >= KINDS.length, 'non-vacuous: every store was cleared (' + w.clears + ')');
      for (const x of [p, q]) eventOnce(x, true);
      w.check();
      for (const [i, x] of [p, q].entries()) {
        assert.notStrictEqual(x.lifecycle.transport.nativeObject, oldNatives[i], x.name + ': new bridge binding (new BridgeNativeObject)');
        const before = x.scripts.length;
        // 旧文档早已销毁；这里直接调旧代理对象，模拟原生侧还在途的回调——不论带旧令牌还是现在的令牌，都不得进宿主、不得交令牌。
        let calls = await bridgeCalls(x, oldTokens[i], oldNatives[i]);
        calls += await bridgeCalls(x, x.lifecycle.transport.session.currentToken(), oldNatives[i]);
        oldNatives[i].hello(); await turn();
        assert.strictEqual(calls, 0, x.name + ': late post through the old javaScriptProxy object reached the host');
        assert.ok(!x.scripts.slice(before).some(s => s.includes('__couliBridgeToken(')), x.name + ': old proxy hello() delivered a token');
        assert.strictEqual(await bridgeCalls(x), 1, x.name + ': the new document bridge works');
      }
    });
    // ---------- N3 被登录页压着的页：同样下树、换新控制器；只有它一个时载体等不到 attach = 延期 ----------
    test('N3_covered_page_is_torn_down_rebuilt_and_recovers_when_uncovered', async () => {
      const f = make(), visible = f.open('visible'), covered = f.open('covered');
      const oldCovered = covered.controller, oldVisible = visible.controller;
      f.cover(covered);
      const w = watch(f);
      await f.login();
      assert.strictEqual(await completed(visible), true, 'visible page completes; the covered page does not hold it up'); await turns();
      eventOnce(covered, true);
      assert.strictEqual(covered.instances[0].unmounted, true, 'covered page: old Web torn down (onDisAppear) while covered');
      const firstClear = f.timeline.findIndex(x => /^op:(cookie|local|indexedDB|cache):entered/.test(x));
      assert.ok(f.timeline.indexOf('covered:unmount#' + oldCovered.id) < firstClear &&
        f.timeline.indexOf('covered:unbound#' + oldCovered.id) < firstClear, 'covered page torn down before the first clear');
      assert.ok(covered.instances.length > 1 && covered.inst && covered.inst.controller !== oldCovered, 'covered page got a new Web with a new controller');
      assert.strictEqual(covered.reloads.length, 0, 'covered page: entry not loaded while its new Web is not attached');
      isolated(covered);
      recoveredClean(f, visible);
      teardownOrder(f, visible, oldVisible);
      f.uncover(covered);
      await turns();
      recoveredClean(f, covered);
      assert.ok(covered.reloadControllers.every(c => c !== oldCovered), 'covered page entry on a new controller');
      assert.strictEqual(await bridgeCalls(covered), 1);
      w.check();
    });
    test('N3_only_covered_page_carrier_never_attaches_defers_not_fails', async () => {
      const f = make(), p = f.open('covered-only');
      const initialLoads = p.loads.length;
      f.cover(p);
      const w = watch(f);
      f.logout();
      await turns(40);
      assert.strictEqual(p.instances[0].unmounted, true, 'covered page torn down while covered');
      f.ports.clock.expire(); // 生产的期限：被压页的载体等不到 attach 不算失败
      await turns(40);
      let outcome = 'pending';
      completed(p).then(value => { outcome = value; });
      await turns(5);
      assert.notStrictEqual(outcome, false, 'deferral is not a failure (D10-279 b)');
      assert.strictEqual(p.lifecycle.errorVisible(), false, 'no retryable error page while merely covered');
      assert.strictEqual(f.ports.clearCalls(), 0, 'nothing is cleared without an attached carrier');
      assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker kept');
      assert.deepStrictEqual([p.loads.length - initialLoads, p.reloads.length], [0, 0], 'nothing loaded while deferred');
      isolated(p);
      f.uncover(p);
      await turns(40);
      assert.strictEqual(await completed(p), true, 'resumes by itself once the page is shown again');
      await turns();
      recoveredClean(f, p);
      w.check();
    });
    // ---------- N4 清理失败 fail-closed；重试重拆载体、换另一个新控制器 ----------
    // t6（D10-396）作废 N4_cache：切号不再清 HTTP 缓存，这个故障注入点已不存在。
    for (const kind of ['cookie', 'local', 'marker']) {
      test('N4_' + kind + '_failure_fails_closed_then_retry_uses_another_new_controller', async () => {
        const f = make(), p = f.open('fail-' + kind);
        const original = p.controller;
        if (kind === 'marker') f.ports.journal.fault = 'remove';
        else f.ports.fault(kind, kind === 'cookie' ? 'reject' : 'throw');
        const first = watch(f);
        await f.login();
        assert.strictEqual(await completed(p), false, kind + ': failure surfaced');
        await turns();
        assert.ok(kind === 'marker' ? f.ports.journal.trace.includes('remove') : f.ports.signal(kind).calls > 0, 'non-vacuous: fault injected at ' + kind);
        assert.strictEqual(p.reloads.length, 0, 'no entry load after a failed clear (no new trusted page)');
        for (const inst of p.instances) for (const realm of inst.documents) {
          if (realm.alive) assert.strictEqual(realm.origin, 'null', 'only a blank carrier may stay mounted after failure: ' + realm.url);
        }
        assert.ok(p.instances[0].unmounted, 'old Web stays torn down');
        if (kind === 'marker') f.ports.journal.fault = '';
        assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker kept');
        isolated(p);
        assert.strictEqual(p.lifecycle.errorVisible(), true, 'retryable error page');
        assert.strictEqual(await bridgeCalls(p), 0);
        first.check();
        if (kind !== 'marker') f.ports.failures.delete(kind);
        const beforeRetry = new Set(f.controllers);
        const retry = watch(f);
        assert.strictEqual(await completed(p.config.retryAuth()), true, 'retry recovers once the fault is gone');
        await turns();
        assert.ok(p.reloadControllers.length > 0 && p.reloadControllers.every(c => !beforeRetry.has(c) && c !== original),
          'retry tears the failed carrier down and loads the entry on yet another new controller');
        for (const inst of p.instances.slice(0, -1)) assert.strictEqual(inst.unmounted, true, 'every earlier Web instance unmounted');
        recoveredClean(f, p);
        retry.check();
      });
    }
    // ---------- N5 新控制器 / 新令牌 / 新桥；BridgePageSession 世代号继续递增 ----------
    test('N5_new_controller_new_token_new_bridge_generation_keeps_rising', async () => {
      const f = make(), p = f.open('fresh', true, { factory: true });
      for (let i = 0; i < 3; i++) { p.controller.url = ENTRY + '/n5-' + i; p.createDocument(); f.pageBegin(p); }
      const transport = p.lifecycle.transport;
      const g0 = transport.session.generation;
      assert.ok(g0 >= 4, 'precondition: generation well above 0 (' + g0 + ')');
      const oldControllers = new Set(f.controllers);
      const seenTokens = new Set(p.scripts.map(s => (/__couliBridgeToken\("([^"]+)"\)/.exec(s) || [])[1]).filter(Boolean));
      seenTokens.add(transport.session.currentToken());
      // 在途的旧调用：切号后迟到的回复不得送到任何文档（旧回复通道跟着旧控制器作废）。
      let release, entered;
      const started = new Promise(resolve => { entered = resolve; });
      const late = new Promise(resolve => { release = resolve; });
      p.config.host.register('app.getEnv', () => { entered(true); return late; });
      let dispatchDone;
      const dispatch = p.config.host.dispatch.bind(p.config.host);
      p.config.host.dispatch = (...args) => { dispatchDone = dispatch(...args); return dispatchDone; };
      transport.nativeObject.post(transport.session.currentToken(), JSON.stringify({ v: 1, id: 'n5-old-call', method: 'app.getEnv', params: {} }));
      assert.strictEqual(await started, true);
      p.config.host.dispatch = dispatch;
      const generationsBefore = p.generations.length;
      const w = watch(f);
      await f.login();
      assert.strictEqual(await completed(p), true); await turns();
      // controllerFactory / onController 的约定
      assert.ok(p.factoryMade.length > 0, 'production used config.controllerFactory');
      for (const inst of p.instances) assert.ok(p.factoryMade.includes(inst.controller), 'every Web instance bound a factory-made controller');
      assert.strictEqual(new Set(p.instances.map(i => i.controller)).size, p.instances.length, 'a controller is never reused across Web instances');
      assert.strictEqual(p.reusedControllers, 0);
      const reported = p.onControllerCalls.map(call => call.controller);
      for (const inst of p.instances) {
        if (inst.controller.attached) assert.ok(reported.includes(inst.controller), 'onController reported controller #' + inst.controller.id);
      }
      for (const call of p.onControllerCalls) {
        assert.ok(call.attached && call.loads === 0, 'onController(c) is called once c is attached and before any loadUrl on it');
      }
      // loadUrl 只在新控制器上；新文档令牌没出现过；世代号单调
      assert.strictEqual(p.reloadControllers.length, 1);
      assert.ok(!oldControllers.has(p.reloadControllers[0]) && p.reloadControllers[0] === p.inst.controller, 'entry loaded on the current, new controller');
      const token = transport.session.currentToken();
      assert.ok(token.length > 0 && !seenTokens.has(token), 'new document has a token no old document ever had');
      const generations = p.generations.slice(generationsBefore);
      assert.ok(generations.length > 0, 'non-vacuous: onPageBegin dispatched after the switch');
      generations.reduce((previous, g) => { assert.ok(g >= previous, 'generation never goes back: ' + generations.join(',')); return g; }, g0);
      assert.ok(transport.session.generation > g0, 'generation keeps rising (same BridgePageSession, no restart from 0)');
      assert.strictEqual(p.config.host.pageGeneration(), transport.session.generation, 'host sees the same page generation');
      release(core.BridgeResult.ok('{"owner":"user-a"}'));
      assert.ok(dispatchDone, 'real BridgeHost.dispatch was entered');
      await dispatchDone; await turns(3);
      assert.ok(!p.executions.some(x => x.script.includes('n5-old-call')), 'late old-account reply never executed in any document');
      assert.strictEqual(await bridgeCalls(p), 1);
      w.check();
    });
    // ---------- N6 没有 Web 实例：不调任何清理接口，标记保留（全局接口任何时候都是 0，见 test()） ----------
    test('N6_no_trusted_page_calls_no_clear_interface_and_keeps_marker', async () => {
      const f = make();
      const sync = f.boot();
      f.logout();
      assert.strictEqual(await completed(sync.settled()), true, 'deferral, not failure');
      await turns();
      assert.strictEqual(f.ports.clearCalls(), 0, 'no static (Cookie / DOM) nor instance (cache) clear without any Web');
      assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker kept for the next trusted Web');
    });
    test('N6_only_refused_page_calls_no_clear_interface_and_keeps_marker', async () => {
      const f = make(), head = f.open('under-login');
      assert.strictEqual(head.lifecycle.initialWeb(), null, 'precondition: refused container has no Web');
      f.logout();
      await turns(40);
      assert.strictEqual(await completed(head), true, 'deferral, not failure');
      assert.strictEqual(f.ports.clearCalls(), 0, 'no static (Cookie / DOM) nor instance (cache) clear while only a Web-less container is open');
      assert.strictEqual(head.instances.length, 0, 'a refused container never mounts a Web, not even a blank carrier');
      assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker kept');
      assert.strictEqual(await bridgeCalls(head), 0);
    });
    // ---------- N7 冷启动补清与 Web 数据归属记录 ----------
    test('N7_cold_start_marker_first_container_mounts_no_trusted_web_before_cleanup', async () => {
      const ports = new Ports(); ports.journal.markPending('user-a');
      const remove = ports.journal.clearPending.bind(ports.journal);
      ports.journal.clearPending = () => { if (ports.mark) ports.mark('marker:removed'); return remove(); };
      const f = make({ ports, tokens: tokenB() }), p = f.open('cold');
      assert.strictEqual(p.loads.length, 0, 'cold start with a marker: no trusted load before cleanup');
      isolated(p);
      assert.strictEqual(await completed(p), true); await turns();
      const removed = f.timeline.indexOf('marker:removed');
      assert.ok(removed >= 0, 'marker removed after cleanup');
      f.timeline.forEach((entry, i) => {
        if (/^cold:mount#\d+:https:/.test(entry)) assert.ok(i > removed, 'a Web with a trusted src was mounted before the cleanup finished: ' + entry);
      });
      assert.ok(p.instances.length > 0 && p.instances[0].src === 'about:blank', 'the first Web of the first container is the blank carrier');
      assert.strictEqual(p.events.length, 0, 'cold storage recovery is not an auth event');
      for (const load of [...p.loads, ...p.reloads]) assert.ok(!dirty(load), 'clean at every load: ' + JSON.stringify(load));
      recoveredClean(f, p);
    });
    for (const record of ['account:user-a', 'account:user-b']) {
      test('N7_R3_03_identity_unknown_at_open_cleans_as_mismatch_' + (record === 'account:user-a' ? 'other_owner' : 'same_owner_unconfirmed'), async () => {
        const journal = new DiskJournal();
        const owner = new DiskOwnerRecord(journal.directory);
        owner.writeOwner(record); owner.trace = [];
        const f = make({ ports: new Ports(journal), owner, tokens: tokenB(), unreadable: true });
        assert.strictEqual(f.network.client.sessionIdentity(f.network.tokens).known, false, 'precondition: identity unknown');
        const p = f.open('unknown-identity');
        assert.strictEqual(p.loads.length, 0, 'R3-03: unknown identity = mismatch; no trusted load with possibly foreign Web data');
        isolated(p);
        assert.strictEqual(await completed(p), true); await turns();
        assert.ok(f.ports.signal('cookie').completed > 0 && f.ports.signal('local').completed > 0, 'cleaned before the first load');
        for (const load of [...p.loads, ...p.reloads]) assert.ok(!dirty(load), 'clean at every load: ' + JSON.stringify(load));
        isolated(p, false);
        const cleans = KINDS.map(kind => f.ports.signal(kind).calls), reloads = p.reloads.length;
        f.network.context.readable = true;
        f.network.client.onSessionChanged();
        await turns();
        assert.strictEqual(await completed(p), true);
        assert.deepStrictEqual(KINDS.map(kind => f.ports.signal(kind).calls), cleans, 'identity confirmed later: no second clean');
        assert.strictEqual(p.reloads.length, reloads, 'and no second reload');
        assert.strictEqual(owner.readOwner(), 'account:user-b', 'owner record written once the identity is known');
        assert.strictEqual(p.events.length, 0, 'cold start unknown → known is not an auth event');
        assert.strictEqual(journal.readPending(), null);
        isolated(p, false);
        assert.strictEqual(await bridgeCalls(p), 1);
      });
    }
    // R3-04：生产组合——AppBridge.attach(context) → 沙盒里的 FileTrustedAuthJournal + FileTrustedWebOwnerRecord（FileSlot + fileIo）。
    const appSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/web/AppBridge.ets'), 'utf8');
    const fileName = key => { const m = new RegExp(key + ": string = '([^']+)'").exec(appSource); return m ? m[1] : null; };
    for (const c of [{ name: 'mismatch', formal: 'account:user-a', clean: true }, { name: 'temp_residue', temp: 'account:user-a', clean: true },
      { name: 'missing', clean: true }, { name: 'match', formal: 'account:user-b', clean: false }]) {
      test('N7_R3_04_production_sandbox_owner_record_' + c.name + (c.clean ? '_cleans_before_first_load' : '_loads_directly'), async () => {
        const ownerName = fileName('WEB_OWNER_FILE'), pendingName = fileName('WEB_PENDING_FILE');
        assert.ok(ownerName && pendingName, 'production sandbox file names found in AppBridge');
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fx25-sandbox-'));
        sandboxes.push(dir);
        enableSandbox(dir);
        const record = new core.FileTrustedWebOwnerRecord(core.FileSlot.at(dir, ownerName));
        if (c.formal) record.writeOwner(c.formal);
        if (c.temp) fs.writeFileSync(path.join(dir, ownerName + '.tmp'), c.temp); // 上次写到一半被杀
        disableSandbox();
        const f = make({ production: { filesDir: dir }, tokens: tokenB() });
        const p = f.open('production-owner');
        if (c.clean) {
          assert.strictEqual(p.loads.length, 0, 'production owner record ' + c.name + ': no trusted load before cleanup');
          isolated(p);
        }
        assert.strictEqual(await completed(p), true); await turns();
        if (c.clean) {
          assert.ok(f.ports.signal('cookie').completed > 0 && f.ports.signal('local').completed > 0, 'really cleaned');
          assert.ok(p.reloads.length > 0, 'loaded after cleanup');
          for (const load of [...p.loads, ...p.reloads]) assert.ok(!dirty(load), 'clean at every load: ' + JSON.stringify(load));
        } else {
          assert.strictEqual(p.loads.length, 1, 'matching owner: direct initial load');
          assert.deepStrictEqual([f.ports.clearCalls(), p.reloads.length], [0, 0], 'matching owner: no extra wipe');
        }
        assert.strictEqual(record.readOwner(), 'account:user-b', 'production owner record names the identity the Web data now belongs to');
        assert.ok(!fs.existsSync(path.join(dir, pendingName)) && !fs.existsSync(path.join(dir, pendingName + '.tmp')),
          'production pending marker (and its temp file) removed');
        isolated(p, false);
        assert.strictEqual(await bridgeCalls(p), 1);
      });
    }
  });
};
