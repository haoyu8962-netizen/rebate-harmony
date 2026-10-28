// F-X-25 v6（评审 r2 后，独立 Claude 测试作者）：R2-01…R2-04 的对抗用例。
// 与 v3 同一条生产链路：真实 ApiClient → AppBridge → TrustedAuthSync → TrustedWebView 生命周期；测试不调 sync.changed /
// attach / cleanAndReload，不替产品补监听、补清理或补重载。系统端口只多两样模型（均在 fx25-native-auth-test.js 夹具）：
// - documentStart：新文档按 ArkWeb 顺序起步——先跑 Web 最近一次挂载时取到的生产 javaScriptOnDocumentStart 条目，再轮到
//   页面自己的第一段脚本（下面的探针），最后才是原生 onPageBegin（pageStarted）。原生回调与页面脚本没有先后保证，按保守口径。
// - attachModel：Web 重建后控制器先「未挂上」，removeCache / loadUrl / runJavaScript / getUrl 按 SDK 抛 17100001；下一轮事件循环
//   由系统派发生产 build() 里的 onControllerAttached 回调原文，之后 Web 自己的 src（空白文档）开始加载。
// sessionStorage 仍按「页 × 源」保存、Web 重建不重置（没有设备证据证明重建换新命名空间之前，这是保守模型，R2-01 (a)）。
// t1（新方案「先拆后清再建」，D10-279，独立 Claude）：上面两个开关与「页 × 源」模型都作废——夹具现在始终按 attach / mount 模型运行，
// sessionStorage 按 Web 实例保存（前提由设备 E01 取证）。V31 断言保留（attach 变体与缺省相同，并为一条）；V32 故障点改为「拆等不到」与
// Cookie；V33 只留 (iv)；V34 / V35 / V36 改在清理载体（新控制器）上；作废 V32b×2（sessionStorage 清理一直失败：没有这项清理了）。
// 监视改挂在夹具的 scriptHooks 上：每个新控制器的脚本都经过它（v6 只包了第一个控制器，换控制器后会漏看）。
'use strict';
const assert = require('assert');
const vm = require('vm');
const { Ports, DiskJournal, turn, withClock } = require('./fx25-v3-ports');
const ENTRY = 'https://h5.example.test';
const OTHER = 'https://other.example.test';
const isA = value => value === 'user-a' || value === 'old-user-rewritten';
module.exports = function (environment) {
  const { hypium } = environment;
  const { fixture, core } = require('./fx25-native-auth-test')({ ...environment, registerLegacy: false });
  const journals = [];
  const made = [];
  function make(options = {}) {
    const ports = options.ports || new Ports();
    journals.push(ports.journal);
    const f = fixture({ ...options, ports });
    made.push(f);
    return f;
  }
  function ports(options = {}) {
    return new Ports(options.journal, options.profile);
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
  async function bridgeCalls(p, token = p.lifecycle.transport.session.currentToken()) {
    let calls = 0;
    p.config.host.register('app.getEnv', () => { calls++; return core.BridgeResult.ok('{}'); });
    p.lifecycle.transport.nativeObject.post(token, JSON.stringify({ v: 1, id: 'v6-probe-' + p.scripts.length,
      method: 'app.getEnv', params: {} }));
    await turn();
    return calls;
  }
  // t6（D10-396）：HTTP 缓存不再是切号清理项（全应用级接口会波及外部 / 隐私页，I6），不算「脏」；「不调用任何缓存清理」由 test() 的
  // globalCalls 守卫（夹具把 removeCache / removeAllCache 都记为全局清理）与各用例的 cacheVia / signal('cache') 断言守。
  const dirty = load => load.cookie !== '' || load.local.length > 0 || load.indexedDB.length > 0;
  function heldOrigins(p) {
    return [...p.origins].filter(([, values]) => [...values.values()].some(isA)).map(([origin]) => origin);
  }
  function sessionClean(p) {
    assert.deepStrictEqual(heldOrigins(p), [], p.name + ': every origin this tab visited must have lost A sessionStorage');
  }
  // 等结算而不推动生产截止计时器：到期才完成 = 没有在合理时间内完成（R2-02 要求的是能完成，不是靠超时失败兜住）。
  async function settleWithoutDeadline(f, p, limit = 200) {
    let done = false;
    const result = completed(p).then(value => { done = true; return value; });
    for (let i = 0; i < limit && !done; i++) await turn();
    if (!done) {
      const expired = f.ports.clock.expire();
      const late = await result;
      assert.fail('trusted cleanup never completed by itself (production deadline timers=' + expired + ', late result=' + late +
        '); a Web-less / never-attached first container must not stall every trusted page');
    }
    return result;
  }
  /**
   * 切号之后才布防（之前旧文档拿到令牌、读写 A 都是正常的）。四道监视，任何一道命中都记一条：
   * (i)  新文档的第一段页面脚本（生产 document-start 条目之后、onPageBegin 之前）读 sessionStorage 不得读到 A；
   * (ii) 新文档提交（pageStarted 同步返回）时若已解除隔离，它所在源的 sessionStorage 不得仍有 A；
   * (iii)删待清标记那一刻，任何在开页面访问过的任何源都不得仍有 A（标记只在清理确认后删）；
   * (iv) 交令牌脚本执行那一刻，接收文档所在源不得仍有 A（R2-03c：「先交令牌、后清」必须红）。
   */
  function arm(f, pages, watch = { probe: true, release: true, marker: true, token: true }) {
    const violations = [];
    const state = { armed: false, tokenDeliveries: 0 };
    const journal = f.ports.journal;
    const remove = journal.clearPending.bind(journal);
    journal.clearPending = () => {
      if (state.armed && watch.marker) {
        for (const p of f.pages.filter(x => !x.closed)) {
          const held = heldOrigins(p);
          if (held.length > 0) violations.push('(iii) pending marker removed while ' + p.name + ' still holds A in ' + held.join(','));
        }
      }
      return remove();
    };
    for (const p of pages) {
      p.firstReads = [];
      p.onDocumentStart = (context, origin) => {
        if (!state.armed) return;
        let value;
        try { value = vm.runInContext('sessionStorage.getItem("owner")', context); } catch (_error) { value = null; }
        p.firstReads.push({ origin, value, isolated: p.config.isAuthIsolated(), marker: journal.readPending() });
        if (watch.probe && isA(value)) {
          violations.push('(i) ' + p.name + ': first page script of the new document at ' + origin + ' read A sessionStorage');
        }
      };
      p.afterCommit = () => {
        if (!state.armed || !watch.release || p.config.isAuthIsolated()) return;
        const origin = new URL(p.controller.url).origin;
        const values = p.origins.get(origin);
        if (values && [...values.values()].some(isA)) {
          violations.push('(ii) ' + p.name + ': isolation lifted on ' + origin + ' while its sessionStorage still holds A');
        }
      };
      p.scriptHooks.push((script, _controller, realm) => {
        if (state.armed && script.includes('__couliBridgeToken(')) {
          state.tokenDeliveries++;
          if (watch.token && realm && [...realm.storage.values()].some(isA)) {
            violations.push('(iv) ' + p.name + ': bridge token delivered into ' + realm.origin + ' while its sessionStorage still holds A');
          }
        }
      });
    }
    return { violations, state, on() { state.armed = true; } };
  }
  function historyOrigin(f, name) {
    const p = f.open(name);
    p.config.trustedOrigins = () => [ENTRY, OTHER];
    p.controller.url = OTHER + '/page';
    p.createDocument(); p.sessionStorage.set('owner', 'user-a'); p.lifecycle.transport.pageStarted();
    assert.strictEqual(p.origins.get(ENTRY).get('owner'), 'user-a', 'precondition: entry origin still holds A');
    assert.strictEqual(p.origins.get(OTHER).get('owner'), 'user-a', 'precondition: current origin holds A');
    return p;
  }
  async function recovered(f, p) {
    await turns();
    assert.strictEqual(f.ports.journal.readPending(), null, 'marker removed after confirmed cleanup');
    isolated(p, false);
    sessionClean(p);
    assert.strictEqual(await bridgeCalls(p), 1, p.name + ': replacement document is usable');
  }
  function test(name, run) {
    hypium.it(name, 0, async () => {
      const start = journals.length;
      const first = made.length;
      try {
        await withClock(run);
        for (const f of made.slice(first)) assert.deepStrictEqual(f.globalCalls(), [], 'I6: no global / incognito clear, ever');
      } finally { made.splice(first); for (const journal of journals.splice(start)) journal.dispose(); }
    });
  }
  hypium.describe('AuthV6_FX25', () => {
    // ---------- R2-01 ----------
    test('V31_R2_01_history_entry_origin_cleared_before_new_document_scripts', async () => {
      const f = make({ ports: ports() }), p = historyOrigin(f, 'history');
      const guard = arm(f, [p]);
      guard.on(); await f.login();
      const ok = await completed(p); await turns();
      assert.deepStrictEqual(guard.violations, [], 'R2-01 P1: A sessionStorage of the entry origin reached the new B document' + ' :: ' + guard.violations.join(' | '));
      assert.ok(p.firstReads.some(r => r.origin === ENTRY), 'replacement document actually started on the entry origin');
      assert.strictEqual(ok, true, 'cleanup completes');
      await recovered(f, p);
    });
    // t1 改写：第一次失败的故障点改为「拆等不到」（旧 Web 不卸下 → 期限到）与 Cookie 删除失败；修好后 retryAuth() 重跑整个事务，四道监视不变。
    for (const fault of ['teardown_timeout', 'cookie_failure']) {
      test('V32_R2_01_retry_after_' + fault + '_clears_before_new_document_scripts', async () => {
        const f = make({ ports: ports() }), p = f.open('retry-' + fault);
        const guard = arm(f, [p]);
        if (fault === 'teardown_timeout') p.holdUnmount = true; else f.ports.fault('cookie', 'reject');
        guard.on(); await f.login();
        if (fault === 'teardown_timeout') { await turns(); assert.ok(f.ports.clock.expire() > 0, 'teardown deadline scheduled'); }
        assert.strictEqual(await completed(p), false, 'first attempt fails');
        assert.strictEqual(p.reloads.length, 0, 'no reload after failure'); isolated(p);
        assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker kept after failure');
        if (fault === 'teardown_timeout') { p.holdUnmount = false; p.releaseUnmount(); } else f.ports.failures.delete('cookie');
        const ok = await completed(p.config.retryAuth()); await turns();
        assert.deepStrictEqual(guard.violations, [], 'R2-01 P2: retry exposed A to the new document' + ' :: ' + guard.violations.join(' | '));
        assert.ok(p.firstReads.some(r => r.origin === ENTRY), 'replacement document actually started on the entry origin');
        assert.strictEqual(ok, true, 'retry recovers once the fault is gone');
        await recovered(f, p);
      });
    }
    // t1 作废 V32b×2（V32b_R2_01_retry_with_session_still_failing_stays_failed_and_isolated[_attach_model]）：故障点是 sessionStorage 清理
    // 一直失败；新方案没有这项清理。「清理一直失败 → 重试仍失败、隔离、不交令牌」由 N4（Cookie / DOM / 缓存 / 删标记各自持续失败）覆盖。
    // ---------- R2-03 (c)：先交令牌、后清（M8）必须红；本条只看 (iv) 与可用性，当前产品应绿 ----------
    test('V33_R2_03c_token_never_precedes_history_origin_session_clear', async () => {
      const f = make({ ports: ports() }), p = historyOrigin(f, 'token-order');
      const guard = arm(f, [p], { probe: false, release: false, marker: false, token: true });
      guard.on(); await f.login();
      assert.strictEqual(await completed(p), true); await turns();
      assert.deepStrictEqual(guard.violations, [], 'token handed to a document that can still read A' + ' :: ' + guard.violations.join(' | '));
      assert.ok(guard.state.tokenDeliveries > 0, 'non-vacuous: the replacement document did receive a token');
      sessionClean(p);
      assert.strictEqual(await bridgeCalls(p), 1);
    });
    // ---------- R2-03 (b)：控制器未挂上（17100001）——等挂上再用，或失败；绝不当成功（M3 必须红） ----------
    // t6（D10-396）改写 V34：原断言「缓存经已挂上的载体控制器清」的对象（removeCache）已从产品删除。改守同一条 R2-03 (b) 的非缓存部分：
    // 入口只在已挂上的新（载体）控制器上加载、生产 onControllerAttached 确实派发；缓存一项改为「切号全程没有任何缓存清理调用」。
    test('V34_R2_03b_entry_waits_for_carrier_attach_and_no_cache_clear', async () => {
      const f = make({ ports: ports({ attach: true }) }), p = f.open('attach-cache');
      const original = p.controller;
      await f.login();
      assert.strictEqual(await completed(p), true); await turns();
      assert.ok(p.reloadControllers.length > 0 && p.reloadControllers.every(c => c !== original), 'entry loaded on a new (carrier) controller, never the old one');
      assert.ok(p.reloadControllers.every(c => c.attached), 'carrier controller was attached when the entry was loaded');
      assert.ok(p.attaches > 1, 'production onControllerAttached handler was dispatched for the carrier');
      assert.deepStrictEqual([p.cacheVia.length, f.ports.signal('cache').calls], [0, 0], 'D10-396: no cache clear API, on any controller');
      assert.strictEqual(p.cache, 'old-cache', 'D10-396: trusted HTTP cache is left as is (no-store is the server side guarantee)');
      assert.ok(p.reloads.length > 0, 'replacement load issued');
      for (const r of p.reloads) assert.ok(!dirty(r), 'clean at load entry: ' + JSON.stringify(r));
      sessionClean(p);
      isolated(p, false);
      assert.strictEqual(f.ports.journal.readPending(), null);
    });
    for (const mode of ['never_attaches', 'still_unattached_after_attach']) {
      // t1 改写（在清理载体上）：页面可见（没有被压），载体一直挂不上 → 期限到判失败，不判延期。
      // t6（D10-396）改写 still_unattached_after_attach：原故障点「挂上后 removeCache 仍报 17100001」随 removeCache 删除而不存在，改到
      // 现在唯一在载体上调用的接口 loadUrl（loadEntry 的 17100001 分支）：挂上后入口加载仍报 17100001，不得当成「新文档已加载」——
      // 页面保持隔离、不交令牌、桥不通、没有重载。never_attaches 判定不变，只把「缓存没清」换成「没有缓存清理调用」。
      test('V35_R2_03b_controller_' + mode + '_is_failure_not_success', async () => {
        const f = make({ ports: ports({ attach: true }) }), p = f.open('attach-' + mode);
        const oldToken = p.lifecycle.transport.session.currentToken();
        if (mode === 'never_attaches') p.neverAttach = true;
        else p.quirks = { loadUrl: 'notAttached' }; // 之后挂上的新控制器：loadUrl 仍抛 17100001
        await f.login();
        const reached = () => mode === 'never_attaches' ? p.instances.length > 1 : p.notAttached.includes('loadUrl');
        for (let i = 0; i < 100 && !reached(); i++) await turn();
        assert.ok(reached(), mode === 'never_attaches' ? 'a carrier Web was mounted' : 'reached the entry load on the attached carrier');
        await turns();
        assert.deepStrictEqual([p.cacheVia.length, f.ports.signal('cache').calls], [0, 0], 'D10-396: no cache clear API');
        if (mode === 'never_attaches') {
          f.ports.clock.expire(); // 生产截止计时器；绝不能用「没挂上」直接兑现
          const ok = await completed(p); await turns();
          assert.strictEqual(ok, false, 'a carrier that never attaches must not count as cleared');
          assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker kept');
        } else {
          await completed(p); await turns();
          assert.ok(p.notAttached.filter(api => api === 'loadUrl').length >= 1, 'non-vacuous: loadUrl really answered 17100001');
        }
        assert.strictEqual(p.reloads.length, 0, 'no reload'); isolated(p);
        assert.strictEqual(await bridgeCalls(p), 0, '17100001 on the entry load is not a new document: the bridge stays closed');
        assert.strictEqual(await bridgeCalls(p, oldToken), 0, 'old token stays dead');
      });
    }
    // ---------- R2-02：首个登记的容器没有 Web / 永远挂不上，其他可信容器照样清完并恢复 ----------
    for (const first of ['refused_auth_page', 'web_never_attaches']) {
      test('V36_R2_02_first_registered_' + first + '_does_not_stall_other_trusted_pages', async () => {
        const f = make({ ports: ports({ attach: true }) });
        const head = f.open(first === 'refused_auth_page' ? 'under-login' : 'first-unrendered');
        if (first === 'refused_auth_page') assert.strictEqual(head.lifecycle.initialWeb(), null, 'precondition: refused container has no Web');
        else head.neverAttach = true; // 例如 Navigation 下层不渲染：重建后的 Web 一直等不到 onControllerAttached
        const p = f.open('normal');
        await f.login();
        const ok = await settleWithoutDeadline(f, p);
        assert.strictEqual(ok, true, 'cleanup completes through another attached trusted controller');
        await turns();
        // t6（D10-396）：原「缓存经另一个已挂上的可信控制器清掉」改为「没有任何缓存清理调用、入口在载体控制器上加载」。
        assert.deepStrictEqual([p.cacheVia.length, head.cacheVia.length, f.ports.signal('cache').calls], [0, 0, 0], 'D10-396: no cache clear API');
        assert.ok(p.reloadControllers.length > 0 && p.reloadControllers.every(c => c !== p.instances[0].controller), 't1: entry loaded on the carrier controller');
        assert.ok(p.reloads.length > 0, 'normal page recovered');
        for (const r of p.reloads) assert.ok(!dirty(r), 'clean at load entry: ' + JSON.stringify(r));
        isolated(p, false); sessionClean(p);
        assert.strictEqual(f.ports.journal.readPending(), null);
        assert.strictEqual(await bridgeCalls(p), 1);
        if (first === 'refused_auth_page') {
          assert.deepStrictEqual([head.loads.length, head.reloads.length], [0, 0], 'auth page never loads in a trusted container');
          assert.strictEqual(await bridgeCalls(head), 0);
        } else {
          isolated(head);
          assert.strictEqual(await bridgeCalls(head), 0, 'not yet reloaded page stays closed');
          head.neverAttach = false;
          assert.strictEqual(head.attachNow(), true);
          await turns();
          assert.ok(head.reloads.length > 0, 'late-attaching page reloads once its controller is attached');
          for (const r of head.reloads) assert.ok(!dirty(r), 'late page clean at load entry');
          isolated(head, false);
        }
      });
    }
    // ---------- R2-04：标记写不进 → 杀进程 → 冷启动，不得按新身份加载旧数据 ----------
    for (const cause of ['login', 'logout']) {
      // login = 评审 P4 原样（R2-04）；logout = 明确清会话（I5 各入口同类）的同一边角，超出 P4 原复现，结论交主线裁定（见交回 v6）。
      test((cause === 'login' ? 'V37' : 'V37b') + '_R2_04_marker_write_failure_then_kill_' + cause +
        '_never_loads_A_data_for_new_identity', async () => {
        const old = make(), original = old.open('before-kill');
        old.ports.journal.fault = 'mark';
        if (cause === 'login') {
          // 不断言登录成功：「先写标记再存新令牌」时登录可以因此失败，按旧进程实际落盘的会话重启。
          const { envelope, tokenPair } = require(require('path').join(environment.root, 'common/core/src/test/NetworkTestRig.ets'));
          old.network.server.handler = () => Promise.resolve(envelope(0, JSON.stringify({ user_id: 'user-b',
            is_new_user: false, tokens: JSON.parse(tokenPair('test-access-b', 'test-refresh-b', 'full')) })));
          try {
            await old.network.client.request(new core.ApiRequest('loginBySms', {}, '', '{"phone":"13800138000","code":"123456"}'));
          } catch (_error) { /* 登录被拒也是合法设计 */ }
        } else {
          try { old.network.client.clearSessionIfEpoch(old.network.client.loginEpoch()); } catch (_error) { /* 同上 */ }
        }
        await completed(original); await turns();
        const owner = old.network.tokens.account();
        if (owner !== 'user-a') {
          for (const r of original.reloads) assert.ok(!dirty(r), 'in-process: no dirty reload under the new identity');
          if (original.reloads.length === 0) isolated(original);
        }
        // 杀进程：只留磁盘（标记文件 + 令牌存储的实际内容）和 Web profile。
        const persisted = old.network.tokens.current === undefined ? null : old.network.tokens.current;
        const reboot = make({ ports: new Ports(new DiskJournal(old.ports.journal.directory), old.ports.profile), tokens: persisted });
        const p = reboot.open('cold-start');
        await completed(p); await turns();
        const coldOwner = reboot.network.tokens.account();
        assert.strictEqual(coldOwner, owner, 'reboot used the session the first process actually persisted');
        if (coldOwner !== 'user-a') {
          for (const load of [...p.loads, ...p.reloads]) {
            assert.ok(!dirty(load), 'cold start loaded A Web data for identity ' + coldOwner + ': ' + JSON.stringify(load));
          }
        }
      });
    }
  });
};
