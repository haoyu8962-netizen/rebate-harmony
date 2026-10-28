// F-X-25 t3（「新方案：设备问题修复」之后的补测；新鲜独立 Claude 测试作者，D10-104）。
// 依据：impl-harmony-handback.md「新方案：设备问题修复」——
//   (a) 入口加载先等清理载体自己的 about:blank 开始（onPageBegin），最多等 CARRIER_SETTLE_MS；
//   (b) 发出后 ENTRY_START_MS 内没看到「真的开始」（onLoadIntercept 放行入口 / 可信新文档 onPageBegin）就在同一个载体控制器上重发，
//       最多 ENTRY_LOAD_ATTEMPTS 次；都没开始 = 加载失败，reload() 拒绝，切号事务失败关门；
//   (c) notAttached 改为 Number(e.code) === 17100001（设备上 code 是字符串 "17100001"）。
// 同一条生产链路：真实 ApiClient → AppBridge → TrustedAuthSync → TrustedWebView 生命周期；测试不调 sync / reload / loadEntry，只经
// 夹具的系统模型（p.loadModel：载体空白页异步开始、入口请求被吞、onLoadIntercept → 请求 → 提交分步派发；fixture stringCode）
// 与假时钟（hold / expireDelay：只推动看门狗或载体期限，不连带切号处理 15 s 的步骤期限）。
'use strict';
const assert = require('assert');
const { Ports, Clock, turn, withClock } = require('./fx25-v3-ports');
const KINDS = ['cookie', 'local', 'indexedDB']; // t6（D10-396）：缓存不再是切号清理项
const isA = value => value === 'user-a' || value === 'old-user-rewritten';
module.exports = function (environment) {
  const { hypium } = environment;
  const { fixture, core, eventOnce, teardownOrder } = require('./fx25-native-auth-test')({ ...environment, registerLegacy: false });
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
  /** 不等结果，只看此刻有没有结论（'pending' / true / false）。 */
  function outcome(p) {
    const box = { value: 'pending' };
    completed(p).then(value => { box.value = value; });
    return box;
  }
  async function turns(n = 20) { for (let i = 0; i < n; i++) await turn(); }
  function isolated(p, value = true) {
    assert.strictEqual(typeof p.config.isAuthIsolated, 'function', 'required production observer: TrustedWebConfig.isAuthIsolated()');
    assert.strictEqual(p.config.isAuthIsolated(), value, p.name + ': isolation');
  }
  async function bridgeCalls(p) {
    let calls = 0;
    p.config.host.register('app.getEnv', () => { calls++; return core.BridgeResult.ok('{}'); });
    p.lifecycle.transport.nativeObject.post(p.lifecycle.transport.session.currentToken(),
      JSON.stringify({ v: 1, id: 't3-probe-' + p.scripts.length, method: 'app.getEnv', params: {} }));
    await turn();
    return calls;
  }
  const dirty = load => load.cookie !== '' || load.local.length > 0 || load.indexedDB.length > 0 || // t6：缓存不算脏（D10-396）
    (load.session || []).some(([, value]) => isA(value));
  function recoveredClean(f, p) {
    assert.ok(p.reloads.length > 0, p.name + ': production reloaded the entry');
    for (const r of p.reloads) assert.ok(!dirty(r), p.name + ': clean at load entry: ' + JSON.stringify(r));
    isolated(p, false);
    assert.strictEqual(f.ports.journal.readPending(), null, 'marker removed');
  }
  /** 产品常量（从生产 BridgeTransport 读，不写死在测试里；只核对模型前提与 plan 定的次数）。 */
  function timing(f) {
    const T = f.BridgeTransport;
    assert.ok(T, 'production BridgeTransport exported');
    assert.ok(T.CARRIER_SETTLE_MS > 0 && T.CARRIER_SETTLE_MS < Clock.SHORT_MS, 'model premise: carrier settle wait is a short timer');
    assert.ok(T.ENTRY_START_MS >= Clock.SHORT_MS && T.ENTRY_START_MS !== 15000, 'model premise: entry watchdog is its own deadline');
    assert.strictEqual(T.ENTRY_LOAD_ATTEMPTS, 3, 'plan: the entry load is issued at most 3 times');
    return T;
  }
  /** reload() 的结论（只观察：包一层记下兑现 / 拒绝，原样返回生产 Promise）。 */
  function spyReload(p) {
    const t = p.lifecycle.transport;
    const original = t.reload.bind(t);
    const outcomes = [];
    t.reload = () => {
      const promise = original();
      const entry = { value: 'pending' };
      outcomes.push(entry);
      promise.then(() => { entry.value = 'resolved'; }, error => { entry.value = 'rejected:' + (error && error.message); });
      return promise;
    };
    return outcomes;
  }
  /**
   * 精简的事务监视（与 t1 watch 同口径的子集）：loadUrl 只在标记已删之后、只在切号后新建的控制器上；令牌只交给标记已删之后的
   * 可信新文档（不是空白载体、不是切号前的文档）。
   */
  function watch(f) {
    const oldControllers = new Set(f.controllers);
    const oldRealms = new Set(f.pages.flatMap(p => p.documents));
    const w = { violations: [], tokens: 0 };
    const v = message => { if (!w.violations.includes(message)) w.violations.push(message); };
    for (const p of f.pages.filter(x => !x.closed)) {
      p.loadHooks.push((url, c) => {
        if (f.ports.journal.readPending() !== null) v('I2: ' + p.name + ' loadUrl(' + url + ') while the pending marker is still on disk');
        if (oldControllers.has(c)) v('new controller: ' + p.name + ' loadUrl on pre-switch controller #' + c.id);
      });
      p.scriptHooks.push((script, _c, realm) => {
        if (!script.includes('__couliBridgeToken(')) return;
        w.tokens++;
        if (f.ports.journal.readPending() !== null) v('I1: token delivered to ' + p.name + ' while the pending marker is on disk');
        if (!realm || realm.origin === 'null' || oldRealms.has(realm)) v('I1: token delivered to a blank / pre-switch document of ' + p.name);
      });
    }
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
        made.splice(first);
        for (const journal of journals.splice(start)) journal.dispose();
      }
    });
  }
  const trustedDocs = p => p.documents.filter(realm => realm.origin !== 'null' && !p.instances[0].documents.includes(realm));
  hypium.describe('AuthT3_FX25', () => {
    // ---------- L1 入口加载等载体自己的 about:blank 开始 ----------
    test('T3_L1_entry_load_waits_for_carrier_blank_page_begin_and_is_not_swallowed', async () => {
      const f = make(), p = f.open('settle');
      const T = timing(f);
      f.ports.clock.hold(T.CARRIER_SETTLE_MS); // 期限这次不到，只看「等信号」这条路
      p.loadModel = { blank: 'held' };
      const w = watch(f);
      f.logout();
      await turns(40);
      assert.strictEqual(p.pendingBlanks.length, 1, 'non-vacuous: a carrier Web is mounted and its own about:blank load is in flight');
      assert.strictEqual(f.ports.journal.readPending(), null, 'non-vacuous: cleanup finished and the marker is removed (reload is waiting)');
      assert.strictEqual(p.entryCalls.length, 0, 'no entry loadUrl while the carrier blank document has not begun (it would be swallowed)');
      assert.strictEqual(f.ports.clock.pending(T.CARRIER_SETTLE_MS), 1, 'the bounded settle wait is armed');
      isolated(p);
      p.releaseBlank();
      await turns(10);
      assert.strictEqual(p.entryCalls.length, 1, 'exactly one entry load, issued after the carrier blank onPageBegin');
      assert.deepStrictEqual(p.swallowed, [], 'the entry request was not swallowed by the carrier blank load');
      assert.strictEqual(p.entryCalls[0].controller, p.controller, 'issued on the carrier controller');
      assert.strictEqual(await completed(p), true);
      await turns();
      assert.strictEqual(f.ports.clock.pending(T.CARRIER_SETTLE_MS), 0, 'settle deadline disarmed once the blank began');
      assert.strictEqual(f.ports.clock.expireDelay(T.ENTRY_START_MS), 0, 'entry watchdog disarmed after the new document began');
      await turns();
      assert.strictEqual(p.entryCalls.length, 1, 'no second entry load');
      assert.strictEqual(p.commits.length, 1);
      assert.deepStrictEqual([p.commits[0].isolatedBefore, p.commits[0].isolatedAfter], [true, false], 'isolation lifted at the new document onPageBegin');
      eventOnce(p, false); recoveredClean(f, p);
      w.check();
    });
    // silent：空白页加载被系统取消；intercept：夹具派发生产 onLoadIntercept(about:blank)，隔离中被产品自己取消。两者都看不到 onPageBegin。
    for (const blank of ['silent', 'intercept']) test('T3_L2_carrier_blank_never_begins_' + blank + '_entry_load_after_bounded_settle_wait', async () => {
      const f = make(), p = f.open('settle-deadline');
      const T = timing(f);
      f.ports.clock.hold(T.CARRIER_SETTLE_MS);
      p.loadModel = { blank };
      const w = watch(f);
      f.logout();
      await turns(40);
      if (blank === 'intercept') assert.strictEqual(p.blankCancelled, 1, 'non-vacuous: production onLoadIntercept cancelled the carrier about:blank');
      assert.strictEqual(f.ports.journal.readPending(), null, 'non-vacuous: reload is waiting');
      assert.strictEqual(p.entryCalls.length, 0, 'still waiting for the carrier signal');
      const before = outcome(p);
      await turns(5);
      assert.strictEqual(before.value, 'pending', 'no conclusion while waiting');
      assert.strictEqual(f.ports.clock.expireDelay(T.CARRIER_SETTLE_MS), 1, 'bounded: the settle deadline exists');
      await turns(10);
      assert.strictEqual(p.entryCalls.length, 1, 'entry load issued once the settle deadline passes');
      assert.strictEqual(await completed(p), true);
      await turns();
      assert.strictEqual(p.entryCalls.length, 1);
      eventOnce(p, false); recoveredClean(f, p);
      w.check();
    });
    // ---------- L3 第一次入口请求被吞：同载体重发，最终加载；解除隔离只在新文档真正开始之后 ----------
    test('T3_L3_swallowed_first_entry_request_is_reissued_on_same_carrier_and_isolation_lifts_only_at_new_document', async () => {
      const f = make(), p = f.open('swallow-once');
      const T = timing(f);
      p.loadModel = { swallow: 1, holdCommit: true };
      const reloads = spyReload(p);
      const w = watch(f);
      f.logout();
      await turns(40);
      assert.strictEqual(p.entryCalls.length, 1, 'non-vacuous: production issued the entry load');
      assert.strictEqual(p.swallowed.length, 1, 'and the system swallowed it (no request, no onLoadIntercept, no onPageBegin)');
      assert.strictEqual(p.reloads.length, 0, 'no entry request reached the network');
      const carrier = p.entryCalls[0].controller;
      const controllers = f.controllers.length;
      isolated(p);
      assert.strictEqual(await bridgeCalls(p), 0, 'bridge closed while nothing has loaded');
      assert.deepStrictEqual(reloads.map(r => r.value), ['pending'], 'a swallowed request is not counted as a success');
      assert.strictEqual(outcome(p).value, 'pending');
      assert.strictEqual(f.ports.clock.expireDelay(T.ENTRY_START_MS), 1, 'entry watchdog armed after the first load');
      await turns(5);
      assert.strictEqual(p.entryCalls.length, 2, 'reissued once after the watchdog');
      assert.strictEqual(p.entryCalls[1].controller, carrier, 'reissued on the same carrier controller');
      assert.strictEqual(f.controllers.length, controllers, 'no new controller / carrier for a reissue');
      assert.strictEqual(p.reloads.length, 1, 'the reissued request was really sent (onLoadIntercept let it through)');
      assert.strictEqual(p.pendingCommits.length, 1, 'its document has not begun yet');
      isolated(p); // onLoadIntercept 放行 ≠ 新文档开始
      assert.strictEqual(w.tokens, 0, 'no token before the new document begins');
      assert.strictEqual(await bridgeCalls(p), 0);
      assert.deepStrictEqual(reloads.map(r => r.value), ['pending']);
      p.releaseCommit();
      await turns(5);
      assert.strictEqual(await completed(p), true, 'cleanup transaction completes once the entry document began');
      assert.deepStrictEqual(reloads.map(r => r.value), ['resolved']);
      assert.strictEqual(p.commits.length, 1);
      assert.deepStrictEqual([p.commits[0].isolatedBefore, p.commits[0].isolatedAfter], [true, false],
        'isolation lifted exactly at the trusted new document onPageBegin');
      assert.strictEqual(p.commits[0].controller, carrier);
      assert.strictEqual(f.ports.clock.expireDelay(T.ENTRY_START_MS), 0, 'watchdog disarmed');
      await turns();
      assert.strictEqual(p.entryCalls.length, 2);
      eventOnce(p, false); recoveredClean(f, p);
      teardownOrder(f, p, f.controllers[0]);
      assert.strictEqual(await bridgeCalls(p), 1, 'the new document bridge works');
      w.check();
    });
    test('T3_L4_carrier_blank_beginning_late_is_not_the_new_document', async () => {
      const f = make(), p = f.open('late-blank');
      const T = timing(f);
      p.loadModel = { blank: 'held' }; // 载体期限照常（短计时器下一轮到）：入口在空白页还在途时发出 → 被顶掉
      const w = watch(f);
      f.logout();
      await turns(40);
      assert.strictEqual(p.entryCalls.length, 1, 'non-vacuous: settle deadline passed and the entry load was issued');
      assert.strictEqual(p.entryCalls[0].swallowed, true, 'swallowed by the in-flight carrier blank load');
      p.releaseBlank(); // 空白页这时才开始（onPageBegin，reload 正在等）
      await turns(10);
      isolated(p); // 载体自己的空白文档不是入口新文档
      assert.strictEqual(w.tokens, 0, 'no token for the carrier blank document');
      assert.strictEqual(await bridgeCalls(p), 0);
      assert.strictEqual(p.entryCalls.length, 1, 'the late blank does not trigger another load by itself');
      assert.strictEqual(outcome(p).value, 'pending');
      assert.strictEqual(f.ports.clock.expireDelay(T.ENTRY_START_MS), 1);
      await turns(10);
      assert.strictEqual(p.entryCalls.length, 2);
      assert.strictEqual(await completed(p), true);
      await turns();
      assert.strictEqual(p.commits.length, 1);
      assert.deepStrictEqual([p.commits[0].isolatedBefore, p.commits[0].isolatedAfter], [true, false]);
      eventOnce(p, false); recoveredClean(f, p);
      w.check();
    });
    // ---------- L5 三次都没开始：失败关门 ----------
    test('T3_L5_entry_never_starts_after_all_attempts_fails_closed_then_retry_recovers', async () => {
      const f = make(), p = f.open('never-starts');
      const T = timing(f);
      p.loadModel = { swallow: Infinity };
      const reloads = spyReload(p);
      const w = watch(f);
      f.logout();
      await turns(40);
      for (let attempt = 1; attempt < T.ENTRY_LOAD_ATTEMPTS; attempt++) {
        assert.strictEqual(p.entryCalls.length, attempt, 'attempt ' + attempt + ' issued');
        assert.strictEqual(f.ports.clock.expireDelay(T.ENTRY_START_MS), 1);
        await turns(5);
      }
      assert.strictEqual(p.entryCalls.length, T.ENTRY_LOAD_ATTEMPTS, 'all attempts issued');
      const carrier = p.entryCalls[0].controller;
      assert.ok(p.entryCalls.every(call => call.controller === carrier && call.swallowed), 'all on the same carrier, all swallowed');
      assert.strictEqual(outcome(p).value, 'pending', 'not concluded before the last watchdog');
      assert.strictEqual(f.ports.clock.expireDelay(T.ENTRY_START_MS), 1, 'the last attempt is watched too');
      await turns(20);
      assert.strictEqual(p.entryCalls.length, T.ENTRY_LOAD_ATTEMPTS, 'bounded: no attempt beyond ENTRY_LOAD_ATTEMPTS');
      const verdict = outcome(p);
      await turns(5);
      assert.strictEqual(verdict.value, false, 'transaction fails: a load that never started is not a success');
      assert.deepStrictEqual(reloads.map(r => r.value), ['rejected:entry load never started'], 'reload() rejects');
      const mounts = p.mounts, controllers = f.controllers.length;
      assert.strictEqual(f.ports.clock.expireDelay(T.ENTRY_START_MS), 0, 'bounded: no further watchdog');
      await turns(20);
      assert.strictEqual(p.entryCalls.length, T.ENTRY_LOAD_ATTEMPTS, 'never a 4th attempt');
      assert.deepStrictEqual([p.reloads.length, p.commits.length], [0, 0], 'nothing was loaded');
      assert.deepStrictEqual([p.mounts, f.controllers.length], [mounts, controllers], 'no new Web / controller after the failure');
      for (const inst of p.instances) for (const realm of inst.documents) {
        if (realm.alive) assert.strictEqual(realm.origin, 'null', 'no trusted document alive after failure: ' + realm.url);
      }
      isolated(p);
      assert.strictEqual(p.lifecycle.errorVisible(), true, 'retryable error page');
      assert.strictEqual(await bridgeCalls(p), 0);
      for (const kind of KINDS) assert.ok(f.ports.signal(kind).completed > 0, kind + ' had been cleared (the failure is the load, not the cleanup)');
      w.check();
      // 重试：系统恢复之后重拆、重清，在另一个新控制器上加载。
      p.loadModel.swallow = 0;
      const before = new Set(f.controllers);
      assert.strictEqual(await completed(p.config.retryAuth()), true, 'retry recovers');
      await turns();
      assert.ok(p.reloadControllers.length > 0 && p.reloadControllers.every(c => !before.has(c)), 'retry loads on yet another new controller');
      recoveredClean(f, p);
      assert.strictEqual(await bridgeCalls(p), 1);
    });
    // ---------- D 看门狗不造成双加载 ----------
    test('T3_D1_started_but_slow_entry_load_is_not_reissued', async () => {
      const f = make(), p = f.open('slow-commit');
      const T = timing(f);
      p.loadModel = { holdCommit: true };
      f.logout();
      await turns(40);
      assert.deepStrictEqual([p.entryCalls.length, p.reloads.length, p.pendingCommits.length], [1, 1, 1],
        'non-vacuous: request sent (onLoadIntercept passed), document still loading');
      isolated(p);
      assert.strictEqual(f.ports.clock.expireDelay(T.ENTRY_START_MS), 1, 'watchdog ran');
      await turns(10);
      assert.strictEqual(p.entryCalls.length, 1, 'a load that already started is never reissued (it would cancel / double-load)');
      assert.strictEqual(f.ports.clock.expireDelay(T.ENTRY_START_MS), 0, 'and not re-armed');
      assert.strictEqual(p.releaseCommit(), 1);
      await turns(5);
      assert.strictEqual(await completed(p), true);
      assert.strictEqual(p.commits.length, 1, 'exactly one entry document');
      assert.strictEqual(trustedDocs(p).length, 1);
      recoveredClean(f, p);
    });
    test('T3_D2_no_reissue_after_isolation_lifted', async () => {
      const f = make(), p = f.open('after-open');
      const T = timing(f);
      p.loadModel = {};
      f.logout();
      assert.strictEqual(await completed(p), true);
      await turns();
      isolated(p, false);
      const calls = p.entryCalls.length, docs = p.documents.length, token = p.lifecycle.transport.session.currentToken();
      assert.strictEqual(calls, 1, 'non-vacuous: one entry load through the async model');
      const fired = f.ports.clock.expireDelay(T.ENTRY_START_MS);
      await turns(10);
      assert.deepStrictEqual([p.entryCalls.length, p.documents.length], [calls, docs], 'no second load into the live document');
      assert.strictEqual(fired, 0, 'watchdog disarmed once the new document began');
      assert.strictEqual(p.lifecycle.transport.session.currentToken(), token, 'live document token untouched');
      assert.strictEqual(await bridgeCalls(p), 1);
    });
    test('T3_D3_superseded_carrier_watchdog_never_loads_into_the_next_round', async () => {
      const f = make(), p = f.open('superseded');
      const T = timing(f);
      p.loadModel = { swallow: 1 };
      f.logout();
      await turns(40);
      assert.strictEqual(p.entryCalls.length, 1, 'non-vacuous: first round issued its entry load');
      assert.strictEqual(p.entryCalls[0].swallowed, true);
      const first = p.entryCalls[0].controller;
      assert.strictEqual(f.ports.clock.pending(T.ENTRY_START_MS), 1, 'its watchdog is armed');
      await f.login(); // 第二次切号：重新隔离、重拆、新载体
      assert.strictEqual(await completed(p), true);
      await turns(40);
      const second = p.controller;
      assert.notStrictEqual(second, first, 'second round on a new carrier');
      const fired = f.ports.clock.expireDelay(T.ENTRY_START_MS);
      await turns(20);
      assert.strictEqual(p.entryCalls.filter(call => call.controller === first).length, 1, 'superseded carrier: no reissue');
      assert.strictEqual(p.entryCalls.filter(call => call.controller === second).length, 1, 'current carrier: exactly one entry load');
      assert.strictEqual(p.commits.length, 1, 'exactly one entry document overall');
      assert.strictEqual(fired, 0, 'every watchdog disarmed (superseded round and finished load)');
      isolated(p, false);
      assert.strictEqual(await bridgeCalls(p), 1);
      recoveredClean(f, p);
    });
    // ---------- C 17100001 判定 ----------
    test('T3_C1_not_attached_accepts_string_and_number_code_rejects_empty', async () => {
      const f = make();
      const notAttached = f.BridgeTransport.notAttached;
      assert.strictEqual(typeof notAttached, 'function', 'production BridgeTransport.notAttached');
      const cases = [
        [{ code: '17100001' }, true], [{ code: 17100001 }, true],
        [null, false], [undefined, false], [{ code: null }, false], [{ code: undefined }, false], [{}, false],
        [{ code: '' }, false], [{ code: 0 }, false], [{ code: '17100002' }, false], [{ code: 17100002 }, false], [new Error('x'), false]
      ];
      for (const [error, expected] of cases) {
        let actual;
        try { actual = notAttached.call(f.BridgeTransport, error); } catch (e) { actual = 'threw ' + e.message; }
        assert.strictEqual(actual, expected, 'notAttached(' + JSON.stringify(error === undefined ? 'undefined' : error) + ')');
      }
      // 解绑探测走同一个判断：控制器调用报字符串 / 数值 17100001 都算已解绑，别的错误不算。
      const unbound = f.BridgeTransport.unbound;
      assert.strictEqual(typeof unbound, 'function', 'production BridgeTransport.unbound');
      const throwing = code => ({ getWebId() { const e = new Error('x'); e.code = code; throw e; } });
      assert.deepStrictEqual(['17100001', 17100001, '17100002', null].map(code => unbound.call(f.BridgeTransport, throwing(code))),
        [true, true, false, false]);
      assert.strictEqual(unbound.call(f.BridgeTransport, { getWebId: () => 1 }), false);
    });
    test('T3_C2_device_string_code_teardown_cache_wait_and_covered_load_complete', async () => {
      const f = make({ stringCode: true }), visible = f.open('visible'), covered = f.open('covered');
      try { new f.FakeController().getWebId(); assert.fail('unattached controller must throw'); }
      catch (e) { assert.strictEqual(e.code, '17100001', 'precondition: fixture throws the device string code'); }
      const old = visible.controller;
      f.cover(covered);
      await f.login();
      assert.strictEqual(await completed(visible), true, 'teardown sees the string 17100001 as unbound; transaction completes');
      await turns();
      recoveredClean(f, visible);
      teardownOrder(f, visible, old);
      assert.ok(covered.notAttached.length > 0, 'non-vacuous: production hit string 17100001 on the covered carrier');
      // t6（D10-396）：用例名里的「cache wait」一步已随产品删除（不再经载体清缓存）；被压页载体上撞到 17100001 的现在是入口加载
      // （loadEntry 登记到挂上再加载），且全程没有任何缓存清理调用。
      assert.ok(covered.notAttached.includes('loadUrl'), 'the string 17100001 is met by the entry load on the covered carrier: ' +
        JSON.stringify(covered.notAttached));
      assert.deepStrictEqual([visible.cacheVia.length, covered.cacheVia.length], [0, 0], 'D10-396: no cache clear API');
      isolated(covered);
      assert.strictEqual(covered.lifecycle.errorVisible(), false, 'waiting for attach, not a failure');
      f.uncover(covered);
      await turns(40);
      recoveredClean(f, covered);
      assert.strictEqual(await bridgeCalls(covered), 1);
    });
  });
};
