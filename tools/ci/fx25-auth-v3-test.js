// I1–I7：运行生产 ApiClient -> AppBridge -> TrustedAuthSync -> TrustedWebView。
// 测试绝不调用 sync.changed/attach/cleanAndReload，不替产品补监听或补重载。
// t1（新方案「先拆后清再建」，D10-279，独立 Claude）：作废 V04×4（sessionStorage 清理脚本的四种故障：新方案不在旧文档上执行任何清理，
// 不再有这条脚本）与 V09（session 清理被导航打断：同上）；改写 V02（write 攻击只在拆之前的 HOLD 阶段有意义）、V06 / V07（只留 Cookie
// 闸门与期限）、V08（前提改成 sessionStorage 按 Web 实例保存）、V24（四类存储 + 新实例 sessionStorage 为空）、V25（第一项清理之前旧
// realm 必须已销毁）；V21 加「A 执行完之前不下树」。每个用例结束都要求全局清理调用为 0（I6）。
'use strict';
const assert = require('assert');
const { Ports, DiskJournal, turn, withClock } = require('./fx25-v3-ports');
module.exports = function (environment) {
  const { hypium } = environment;
  const { fixture, core, eventOnce } = require('./fx25-native-auth-test')({ ...environment, registerLegacy: false });
  const journals = [];
  const made = [];
  function make(options = {}) {
    const ports = options.ports || new Ports();
    journals.push(ports.journal);
    const f = fixture({ ...options, ports });
    made.push(f);
    return f;
  }
  async function completed(p) {
    try { return await p.config.whenAuthSettled(); } catch (_error) { return false; }
  }
  // t1：每个新 Web 在自己的下一轮事件循环里才挂上（attach），别的页的重载可能晚于结算屏障几轮；按轮次等，不按墙钟。
  async function turns(n = 20) { for (let i = 0; i < n; i++) await turn(); }
  function isolated(p, value = true) {
    assert.strictEqual(typeof p.config.isAuthIsolated, 'function', 'required production observer: TrustedWebConfig.isAuthIsolated()');
    assert.strictEqual(p.config.isAuthIsolated(), value, p.name + ': isolation');
  }
  async function bridgeCalls(p, token = p.lifecycle.transport.session.currentToken()) {
    let calls = 0;
    p.config.host.register('app.getEnv', () => { calls++; return core.BridgeResult.ok('{}'); });
    p.lifecycle.transport.nativeObject.post(token, JSON.stringify({ v: 1, id: 'v3-probe-' + p.scripts.length,
      method: 'app.getEnv', params: {} }));
    await turn();
    return calls;
  }
  function noHello(p) {
    const before = p.scripts.length;
    p.lifecycle.transport.nativeObject.hello();
    p.lifecycle.transport.sameDocumentCommitted();
    assert.ok(!p.scripts.slice(before).some(s => s.includes('__couliBridgeToken')),
      'hello / same-document callback must not issue a token to quarantined old document');
  }
  function noNavigation(p) {
    const before = p.reloads.length;
    assert.strictEqual(p.lifecycle.intercept('https://h5.example.test/next', true), true,
      'actual onLoadIntercept must cancel trusted navigation while isolated');
    assert.strictEqual(p.reloads.length, before);
  }
  function allClean(p) {
    assert.ok(p.reloads.length > 0, p.name + ': production initiated reload');
    // t6（D10-396）：HTTP 缓存不是切号清理项（ArkWeb 只有全应用级的缓存清理，会波及外部 / 隐私页，I6）：可信那一份原样保留；
    // 任何缓存清理调用都记进 globalCalls，由 test() 的 I6 守卫判红。
    for (const r of p.reloads) assert.deepStrictEqual([r.cookie, r.local, r.session, r.indexedDB, r.cache],
      ['', [], [], [], 'old-cache'], p.name + ': clean at load entry (HTTP cache not cleared, D10-396)');
  }
  function failure(p, before = 0) {
    assert.strictEqual(p.reloads.length, before, 'no reload on failed/unconfirmed cleanup');
    isolated(p);
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
  hypium.describe('AuthV3_FX25', () => {
    test('V01_I1_synchronous_isolation_before_first_await', async () => {
      const f = make(), a = f.open('visible'), b = f.open('covered');
      const gate = f.ports.hold('cookie');
      f.logout();
      try { isolated(a); isolated(b); noNavigation(a); noHello(b); }
      finally { gate.gate.resolve(); }
      await completed(a);
    });
    // t1 改写：pending / failed 两个阶段都已经拆完，旧 realm 不存在，write 攻击必须写不成（比 v3「写不进存储」更严：文档已销毁）。
    // 只有拆之前的 HOLD 阶段（A 还在执行）旧文档还活着：此时写回必须写得成（前提非空跑），并且之后被清掉、进不了新文档（V02_I1_hold_write）。
    for (const phase of ['pending', 'failed']) {
      for (const attack of ['bridge', 'hello', 'navigation', 'write']) {
        test('V02_I1_' + phase + '_' + attack, async () => {
          const f = make(), p = f.open('old-document');
          const oldToken = p.lifecycle.transport.session.currentToken();
          const gate = phase === 'pending' ? f.ports.hold('cookie') : null;
          if (!gate) f.ports.fault('cookie', 'reject');
          await f.login();
          await f.ports.signal('cookie').entered.promise;
          if (!gate) assert.strictEqual(await completed(p), false);
          try {
            if (attack === 'bridge') assert.strictEqual(await bridgeCalls(p, oldToken), 0, 'old page handler must never execute');
            if (attack === 'hello') { noHello(p); assert.strictEqual(await bridgeCalls(p), 0); }
            if (attack === 'navigation') noNavigation(p);
            if (attack === 'write') assert.strictEqual(f.ports.oldWrite(p), false, 'old realm already destroyed once any clear has started');
          } finally { if (gate) gate.gate.resolve(); }
          await completed(p);
        });
      }
    }
    test('V02_I1_hold_write_before_teardown_is_wiped', async () => {
      const f = make(), p = f.open('old-document');
      const event = require('./fx25-v3-ports').deferred(); f.holdEvents(event.promise);
      await f.login(); await f.eventStarted;
      let wrote;
      try {
        isolated(p);
        wrote = f.ports.oldWrite(p);
        assert.strictEqual(wrote, true, 'non-vacuous: before teardown (A still running) the isolated old document is alive and writes back');
        assert.strictEqual(f.ports.clearCalls(), 0, 'nothing is cleared while the old document is alive');
      } finally { event.resolve(); }
      assert.strictEqual(await completed(p), true);
      allClean(p);
      assert.deepStrictEqual([p.cookie, [...p.local], [...p.indexedDB], p.sessionStorage.get('owner') || null], ['', [], [], null],
        'what the old document wrote during HOLD is gone; the new Web instance has its own empty sessionStorage');
    });
    test('V03_I1_only_committed_new_document_may_leave_isolation', async () => {
      const f = make(), p = f.open('new-document');
      const oldToken = p.lifecycle.transport.session.currentToken();
      f.ports.deferDocument = true;
      await f.login();
      for (let i = 0; i < 200 && p.reloads.length === 0; i++) await turn(); // t1：拆 → 建载体 → 清，要多走几轮
      assert.strictEqual(p.reloads.length, 1, 'cleanup schedules exactly one replacement load');
      isolated(p); noHello(p);
      assert.strictEqual(await bridgeCalls(p, oldToken), 0);
      assert.strictEqual(typeof p.commit, 'function');
      p.commit(); await completed(p);
      isolated(p, false);
      assert.strictEqual(await bridgeCalls(p), 1, 'new document can call after commit');
      assert.strictEqual(await bridgeCalls(p, oldToken), 0);
      allClean(p);
    });
    // t1 作废 V04×4（V04_I2_session_{script,throw,reject,unconfirmed}）：它们给「在旧文档上执行 sessionStorage 清理脚本」注入四种故障。
    // 新方案（D10-279 I1 / I2）旧文档上不做任何清理，sessionStorage 随旧 Web 实例销毁，不再有这条脚本，也就没有这四个故障点；
    // 「新实例不继承旧 sessionStorage」改由 V08 / V24 / N2 与设备 E01 证明。
    // t6（D10-396）作废 V05_I2_cache_*×2：切号不再清 HTTP 缓存，这个故障注入点已不存在。
    for (const kind of ['cookie', 'local', 'indexedDB']) {
      for (const nth of [1, 2]) {
        test('V05_I2_' + kind + '_independent_failure_round_' + nth, async () => {
          const f = make(), p = f.open('separate-' + kind);
          if (nth === 2) { await f.login('user-first'); assert.strictEqual(await completed(p), true); allClean(p); }
          f.ports.fault(kind, kind === 'cookie' ? 'reject' : 'throw');
          const before = p.reloads.length;
          await f.login('user-failed');
          assert.strictEqual(await completed(p), false, kind + ': failure surfaced');
          failure(p, before);
          f.ports.failures.delete(kind);
          assert.strictEqual(await p.config.retryAuth(), true);
          allClean(p); isolated(p, false);
        });
      }
    }
    // t1：只留 Cookie 的闸门与期限（session 变体作废：不再有 sessionStorage 清理信号）。
    for (const kind of ['cookie']) {
      test('V06_I2_' + kind + '_own_completion_is_awaited', async () => {
        const f = make(), p = f.open('completion-' + kind), gate = f.ports.hold(kind);
        await f.login(); await gate.entered.promise; await turn();
        try {
          assert.strictEqual(gate.completed, 0);
          assert.strictEqual(p.reloads.length, 0);
          isolated(p);
          assert.notStrictEqual(f.ports.journal.readPending(), null);
        } finally { gate.gate.resolve(); }
        assert.strictEqual(await completed(p), true); allClean(p);
      });
      test('V07_I2_' + kind + '_timeout_and_late_success_cannot_reopen', async () => {
        const f = make(), p = f.open('timeout-' + kind), gate = f.ports.hold(kind);
        await f.login(); await gate.entered.promise; await turn();
        try {
          assert.ok(f.ports.clock.expire() > 0, 'cleanup deadline is scheduled on production clock');
          await turn();
          assert.strictEqual(await completed(p), false);
          failure(p);
          gate.gate.resolve(); await turn();
          failure(p);
          assert.notStrictEqual(f.ports.journal.readPending(), null);
        } finally { gate.gate.resolve(); }
      });
    }
    test('V08_I2_session_history_origin_is_not_missed', async () => {
      // v6（R2-03a）：新文档按 ArkWeb 顺序起步（生产 document-start 条目 → 页面第一段脚本 → onPageBegin），见 fx25-native-auth-test.js。
      // t1：断言不变，前提改为 sessionStorage 按 Web 实例保存——两个可信源的 A 值都在旧实例里，新实例的入口文档在页面脚本处读不到。
      const ports = new Ports();
      const f = make({ ports }), p = f.open('origin-one');
      p.controller.url = 'https://h5.example.test:443/origin-two';
      // 不同可信源：由真实状态端口提供第二个源，文档沿真实导航生命周期切换。
      p.config.trustedOrigins = () => ['https://h5.example.test', 'https://other.example.test'];
      p.controller.url = 'https://other.example.test/page';
      p.createDocument(); p.sessionStorage.set('owner', 'user-a'); p.lifecycle.transport.pageStarted();
      // R2-03a：原先 loadUrl 入口记下的 session 是切到入口源之前的 other 源（已清），量错了源。改为在新文档已切到入口源之后、
      // 用入口源的 sessionStorage、在页面自己的第一段脚本处读；旧的入口记录与最终状态断言照旧保留。
      const entryReads = [];
      p.onDocumentStart = (context, origin) => {
        let value;
        try { value = require('vm').runInContext('sessionStorage.getItem("owner")', context); } catch (_error) { value = null; }
        entryReads.push({ origin, value });
      };
      await f.login(); assert.strictEqual(await completed(p), true);
      const entry = new URL(p.config.url).origin;
      assert.ok(entryReads.some(r => r.origin === entry), 'replacement document actually started on the entry origin');
      for (const r of entryReads) assert.strictEqual(r.value, null, r.origin + ': replacement document read A sessionStorage before its own scripts');
      for (const [origin, values] of p.origins) assert.strictEqual(values.size, 0, origin + ': session history must be cleared or context destroyed');
      allClean(p);
    });
    // t1 作废 V09（V09_I2_session_navigation_interrupted_is_failure）：故障点是旧文档上的 sessionStorage 清理脚本被导航打断；
    // 新方案没有这条脚本。拆这一步自己的「等不到」由 V39b / N1 覆盖。
    test('V10_I3_pending_marker_is_on_disk_before_cleanup', async () => {
      const f = make(), p = f.open('persist-first'), gate = f.ports.hold('cookie');
      f.logout();
      try {
        assert.strictEqual(new DiskJournal(f.ports.journal.directory).readPending(), 'user-a',
          'synchronous persisted ownership before any cleanup await');
        await gate.entered.promise;
        assert.strictEqual(f.ports.journal.trace.includes('remove'), false);
      } finally { gate.gate.resolve(); }
      assert.strictEqual(await completed(p), true);
      assert.strictEqual(f.ports.journal.readPending(), null);
    });
    test('V30_I3_missing_production_pending_store_blocks_initial_load_and_shows_failure', async () => {
      // 使用生产 AppNetwork 默认接线，既不 attach 沙盒也不注入标记存储。
      // Ports 的磁盘后端仍存在，但明确传 null，生产不能偷偷借用它或内存兜底。
      const f = make({ pending: null }), p = f.open('missing-store');
      assert.strictEqual(p.loads.length, 0, 'missing marker storage must block the very first trusted load');
      assert.strictEqual(await completed(p), false, 'configuration failure must surface through settlement');
      failure(p);
      assert.strictEqual(p.lifecycle.errorVisible(), true, 'production build must render its ErrorState');
      assert.strictEqual(await bridgeCalls(p), 0);
      noHello(p); noNavigation(p);
      assert.strictEqual(p.events.length, 0);
      assert.strictEqual(f.ports.journal.trace.length, 0, 'uninjected test disk must remain unused');
      f.externalUnchanged();
    });
    for (const fail of [false, true]) {
      test('V11_I3_kill_pending_then_cold_boot_' + (fail ? 'fails_closed' : 'cleans_before_load'), async () => {
        const old = make(), original = old.open('before-kill'), gate = old.ports.hold('cookie');
        await old.login(); await gate.entered.promise;
        assert.strictEqual(old.ports.journal.readPending(), 'user-a', 'first process actually recorded its transaction');
        // 杀进程模型：丢掉旧 VM、队列、页面与 API；只复制磁盘标记和浏览器 profile。旧 Promise 永不恢复。
        const ports = new Ports(new DiskJournal(old.ports.journal.directory), old.ports.profile);
        if (fail) ports.fault('cookie', 'reject');
        else ports.hold('cookie');
        const reboot = make({ ports, tokens: new core.SessionTokenSet('access-b', 'refresh-b', 'full', 'user-b', 'epoch-b') });
        const p = reboot.open('cold-start');
        assert.strictEqual(p.loads.length, 0, 'cold trusted initial Web source must not load dirty profile');
        assert.strictEqual(p.events.length, 0, 'cold storage recovery is not an auth event');
        if (fail) {
          assert.strictEqual(await completed(p), false); failure(p);
          assert.strictEqual(ports.journal.readPending(), 'user-a');
        } else {
          await ports.signal('cookie').entered.promise;
          ports.signal('cookie').gate.resolve();
          assert.strictEqual(await completed(p), true); allClean(p); isolated(p, false);
          assert.strictEqual(ports.journal.readPending(), null);
        }
        assert.strictEqual(original.reloads.length, 0);
      });
    }
    // 独立的磁盘重启向量，避免首次 mark 缺失遮住冷启动加载漏洞。
    for (const fail of [false, true]) {
      test('V12_I3_existing_disk_transaction_' + (fail ? 'failure' : 'success'), async () => {
        const ports = new Ports(); ports.journal.markPending('user-a');
        if (fail) ports.fault('cookie', 'reject'); else ports.hold('cookie');
        const f = make({ ports }), p = f.open('persisted');
        try {
          assert.strictEqual(p.loads.length, 0);
          isolated(p);
        } finally { if (!fail) ports.signal('cookie').gate.resolve(); }
        assert.strictEqual(await completed(p), !fail);
        if (fail) failure(p); else allClean(p);
      });
    }
    for (const mode of ['read', 'remove']) {
      test('V13_I3_journal_' + mode + '_error_fails_closed', async () => {
        const ports = new Ports();
        if (mode === 'read') ports.journal.fault = mode;
        const f = make({ ports }), p = f.open('journal-failure');
        ports.journal.fault = mode;
        await f.login();
        assert.strictEqual(await completed(p), false);
        failure(p);
      });
    }
    // v7（独立 Claude，D10-206）：既有规则改动。原断言「标记写不进 + 真实登录 B → 登录成功、清理 0 次、事务失败」与 V37（I3：杀进程
    // 后冷启动不得按 B 加载 A 的数据）互斥：登录成功意味着 B 的令牌已落盘、磁盘上又没有标记，冷启动就只能把 B 当干净基线。I3 要求
    // 「先持久写标记」，写不进时唯一不泄露的做法是新会话不落盘。所以改为：登录被拒（session_save_failed），磁盘会话、页面、Web 数据
    // 都原样不动，产品确实先试过写标记，且不清、不重载、不发 A、不进事务。原来的「没有持久责任不清理」（cookie 0 次）原样保留。
    test('V13_I3_journal_mark_error_fails_closed', async () => {
      const ports = new Ports();
      const f = make({ ports }), p = f.open('journal-failure');
      const oldToken = p.lifecycle.transport.session.currentToken();
      ports.journal.fault = 'mark';
      f.network.server.handler = () => Promise.resolve(f.envelope(0, JSON.stringify({ user_id: 'user-b',
        is_new_user: false, tokens: JSON.parse(f.tokenPair('test-access-b', 'test-refresh-b', 'full')) })));
      const result = await f.network.client.request(new core.ApiRequest('loginBySms', {}, '',
        '{"phone":"13800138000","code":"123456"}'));
      assert.ok(ports.journal.trace.includes('mark:user-a'), 'non-vacuous: product tried to persist the marker for user-a first');
      assert.notStrictEqual(result.code, 0, 'login cannot succeed when the pending marker cannot be persisted first (I3)');
      assert.strictEqual(result.localRejectReason, 'session_save_failed', 'same outcome as a token store write failure');
      assert.strictEqual(f.network.tokens.account(), 'user-a', 'new session must not be saved');
      assert.strictEqual(f.network.tokens.accessToken(), 'test-access-a', 'old session kept as is');
      assert.strictEqual(ports.journal.readPending(), null, 'nothing reached disk');
      assert.strictEqual(await completed(p), true, 'no transaction was started, nothing failed');
      assert.strictEqual(ports.signal('cookie').calls, 0, 'no cleanup without durable responsibility');
      for (const kind of ['session', 'local', 'indexedDB', 'cache']) assert.strictEqual(ports.signal(kind).calls, 0, kind + ' untouched');
      assert.deepStrictEqual([p.reloads.length, p.events.length], [0, 0], 'no reload, no A: identity did not change');
      isolated(p, false);
      assert.strictEqual(p.lifecycle.transport.session.currentToken(), oldToken, 'same document, same token');
      assert.strictEqual(await bridgeCalls(p), 1, 'session unchanged: the A page keeps working for A');
      assert.deepStrictEqual([p.cookie, p.local.get('owner'), p.sessionStorage.get('owner'), p.cache],
        ['old-cookie', 'user-a', 'user-a', 'old-cache'], 'A data stays with A, who is still signed in');
    });
    // v7：明确清会话（登出）的同一边角：会话必须清，不能拒绝；标记写不进 → 进程内失败关门，不重载、不报成功、不删标记。
    test('V13b_I3_journal_mark_error_on_logout_fails_closed', async () => {
      const ports = new Ports();
      const f = make({ ports }), p = f.open('journal-failure-logout');
      ports.journal.fault = 'mark';
      f.logout();
      assert.strictEqual(f.network.tokens.account(), null, 'explicit session clear still happens');
      assert.strictEqual(await completed(p), false);
      failure(p);
      assert.ok(ports.journal.trace.includes('mark:user-a'), 'non-vacuous: product tried to persist the marker');
      assert.ok(!ports.journal.trace.includes('remove'), 'no marker removal = no claimed success');
      assert.strictEqual(await bridgeCalls(p), 0);
      assert.strictEqual(p.events.length, 1, 'A still reaches the old document (I7)');
    });
    test('V14_I4_open_during_cookie_pending_joins_all_pages', async () => {
      const f = make(), a = f.open('original'), gate = f.ports.hold('cookie');
      await f.login(); await gate.entered.promise;
      const b = f.open('opened-during-clean');
      try { assert.strictEqual(b.loads.length, 0, 'new page must not load old profile'); isolated(b); noHello(b); }
      finally { gate.gate.resolve(); }
      assert.strictEqual(await completed(a), true); assert.strictEqual(await completed(b), true); await turns();
      for (const p of [a, b]) { allClean(p); isolated(p, false); }
      eventOnce(a, true);
    });
    test('V15_I4_new_page_retry_cannot_abandon_original_blocked_page', async () => {
      const f = make(), a = f.open('original-failed');
      f.ports.fault('cookie', 'reject'); await f.login(); assert.strictEqual(await completed(a), false);
      const b = f.open('new-after-failure');
      assert.strictEqual(b.loads.length, 0); assert.strictEqual(await completed(b), false);
      f.ports.failures.delete('cookie');
      assert.strictEqual(await b.config.retryAuth(), true); await turns();
      for (const p of [a, b]) { allClean(p); isolated(p, false); }
      assert.strictEqual(f.ports.journal.readPending(), null);
      const before = a.reloads.length;
      assert.strictEqual(await a.config.retryAuth(), true);
      assert.strictEqual(a.reloads.length, before, 'all recovered; retry is now idempotent');
    });
    for (const during of [false, true]) {
      test('V16_I1_I3_I4_rapid_switch_' + (during ? 'while_cleaning' : 'same_turn'), async () => {
        const f = make(), p = f.open('rapid'), gate = f.ports.hold('cookie');
        if (during) { await f.login('user-b'); await gate.entered.promise; await f.login('user-c'); }
        else { f.logout(); await f.login('user-b'); await f.login('user-c'); }
        try {
          assert.strictEqual(f.network.tokens.account(), 'user-c');
          assert.strictEqual(p.reloads.length, 0);
          assert.strictEqual(await bridgeCalls(p), 0);
          isolated(p);
          assert.notStrictEqual(f.ports.journal.readPending(), null);
        } finally { gate.gate.resolve(); }
        assert.strictEqual(await completed(p), true); allClean(p); isolated(p, false);
        assert.strictEqual(f.ports.journal.readPending(), null);
        // t1：during 时第二次切号发生在旧文档已拆掉之后（夹具不再把脚本执行进已销毁的文档），没有可投递的文档；新文档本来就以 C 起步。
        // v3 的「两次 A」依赖旧夹具把 A 执行进已丢弃文档的假象，按真实语义改为一次。same_turn 三次照旧（都在拆之前）。
        assert.deepStrictEqual(p.events.map(e => e.data), during ? [{ logged_in: true }] :
          [{ logged_in: false }, { logged_in: true }, { logged_in: true }]);
      });
    }
    for (const cause of ['environment', 'withdrawal']) {
      for (const fail of [false, true]) {
        test('V17_I5_' + cause + '_' + (fail ? 'failure' : 'reopen'), async () => {
          const f = make(), p = f.open(cause);
          const registry = new core.LocalDataCleanerRegistry(), gate = new core.EnvironmentSwitchGate();
          core.NetworkComposition.install(f.network.client, registry, () => {}, gate, f.network.tokens);
          const hold = f.ports.hold('cookie');
          if (fail) f.ports.fault('cookie', 'reject');
          f.network.context.readable = false;
          if (cause === 'environment') { f.network.context.settled = false; gate.close(); }
          else f.network.context.privacyRaw = 'basic';
          let reads = 0;
          for (const key of ['account', 'accessToken', 'refreshToken', 'loginEpoch', 'readStatus']) {
            const previous = f.network.tokens[key].bind(f.network.tokens);
            f.network.tokens[key] = () => { if (!f.network.context.readable) reads++; return previous(); };
          }
          const report = cause === 'environment' ? await registry.cleanAll() : await registry.cleanOnly(registry.names());
          assert.strictEqual(report.ok, true, 'real composition token cleaner finished');
          assert.strictEqual(f.network.client.sessionIdentity(f.network.tokens).known, false);
          await turn();
          try {
            assert.strictEqual(reads, 0, 'explicit clear must not probe closed credential store');
            assert.notStrictEqual(f.ports.journal.readPending(), null, 'explicit clear persists even when identity is unknown');
            isolated(p);
            f.network.context.readable = true; f.network.context.settled = true; f.network.context.privacyRaw = 'full';
            if (cause === 'environment') gate.reopen(true);
            noNavigation(p);
          } finally { hold.gate.resolve(); }
          assert.strictEqual(await completed(p), !fail);
          if (fail) failure(p); else { allClean(p); isolated(p, false); }
        });
      }
    }
    test('V18_I5_real_10404_response_clears_and_records', async () => {
      const f = make(), p = f.open('unauthorized'), gate = f.ports.hold('cookie');
      // 使用已有 Rig 的真实响应包装，保留协议字段。
      const { envelope } = require(require('path').join(environment.root, 'common/core/src/test/NetworkTestRig.ets'));
      f.network.server.handler = () => Promise.resolve(envelope(10404, '{}'));
      const result = await f.network.client.request(new core.ApiRequest('getMe'));
      try {
        assert.strictEqual(result.code, 10404);
        assert.strictEqual(f.network.tokens.account(), null);
        assert.notStrictEqual(f.ports.journal.readPending(), null);
        isolated(p);
      } finally { gate.gate.resolve(); }
      assert.strictEqual(await completed(p), true); allClean(p); eventOnce(p, false);
    });
    test('V19_I6_only_external_open_retains_cached_response_bytes', async () => {
      const f = make(); const sync = f.boot();
      assert.ok(sync, 'production startup has registered watcher without trusted pages');
      const before = f.ports.cachedExternal();
      f.logout(); assert.strictEqual(await sync.settled(), true);
      assert.strictEqual(f.ports.cachedExternal(), before, 'read actual retained response, not only invocation counts');
      assert.strictEqual(f.ports.globalCacheCalls, 0, 'global removeAllCache is forbidden even without trusted pages');
      f.externalUnchanged();
    });
    test('V20_I6_last_trusted_closed_external_remains', async () => {
      const f = make(), p = f.open('will-close'); f.close(p);
      const before = f.ports.cachedExternal();
      await f.login(); assert.strictEqual(await completed(p), true);
      assert.strictEqual(f.ports.cachedExternal(), before); assert.strictEqual(f.ports.globalCacheCalls, 0);
      assert.strictEqual(p.reloads.length, 0); f.externalUnchanged();
    });
    test('V21_I7_event_while_isolated_waits_for_delivery', async () => {
      const f = make(), pages = [f.open('visible'), f.open('covered'), f.open('background')];
      const event = require('./fx25-v3-ports').deferred(); f.holdEvents(event.promise);
      await f.login(); await f.eventStarted;
      try {
        await turns(10);
        for (const p of pages) {
          isolated(p); assert.strictEqual(p.reloads.length, 0);
          // t1（teardown-before-A）：A 执行完之前不下树，否则旧文档收不到 A。
          assert.strictEqual(p.disappears, 0, p.name + ': old Web must stay mounted until A has executed');
        }
        assert.strictEqual(f.ports.clearCalls(), 0);
      } finally { event.resolve(); }
      assert.strictEqual(await completed(pages[0]), true); await turns();
      for (const p of pages) { eventOnce(p, true); allClean(p); }
    });
    test('V22_I7_unknown_read_is_not_explicit_logout', async () => {
      const f = make(), p = f.open('unknown');
      f.network.context.readable = false;
      f.network.client.onSessionChanged(); await turn();
      assert.strictEqual(await completed(p), true);
      assert.strictEqual(p.events.length, 0); assert.strictEqual(p.reloads.length, 0);
      assert.strictEqual(f.ports.signal('cookie').calls, 0);
      assert.strictEqual(f.ports.journal.readPending(), null);
    });
    test('V23_I7_clean_cold_start_has_no_A_or_B', async () => {
      const f = make(); f.network.context.readable = false;
      const p = f.open('unknown-start');
      f.network.context.readable = true;
      f.network.client.onSessionChanged();
      assert.strictEqual(await completed(p), true);
      assert.strictEqual(p.events.length, 0); assert.strictEqual(p.reloads.length, 0);
      assert.strictEqual(f.ports.signal('cookie').calls, 0);
    });
    // 此成功对照专供删调用变异；不会被缺隔离/持久接口挡在前面。
    // t1 改写：四类存储各自的完成信号（sessionStorage 不再单列清理）+ 重载入口所在的是一个新 Web 实例，它的 sessionStorage 为空。
    test('V24_I2_each_storage_has_its_own_completion_and_empty_value', async () => {
      const f = make(), p = f.open('all-stores');
      const oldInstance = p.instances[0];
      await f.login(); assert.strictEqual(await completed(p), true);
      allClean(p); eventOnce(p, true);
      for (const kind of ['cookie', 'local', 'indexedDB']) {
        assert.ok(f.ports.signal(kind).completed > 0, kind + ': actual completion signal required');
      }
      // t6（D10-396）：缓存一项改为「没有任何缓存清理调用」。
      assert.strictEqual(f.ports.signal('cache').calls, 0, 'D10-396: no HTTP cache clear API is entered');
      assert.notStrictEqual(p.inst, oldInstance, 'entry reloaded in a new Web instance');
      assert.strictEqual(oldInstance.unmounted, true, 'old Web instance (and its sessionStorage namespace) is gone');
      for (const [origin, values] of p.origins) assert.strictEqual(values.size, 0, origin + ': new instance sessionStorage is empty');
      assert.deepStrictEqual([p.cookie, [...p.local], [...p.indexedDB], p.cache], ['', [], [], 'old-cache'],
        'profile is empty except the HTTP cache, which is not cleared (D10-396)');
      f.externalUnchanged();
    });
    // t1 改写（加严）：v3 只在「最后一项清完、重载之前」攻击；现在每一项清理进入系统接口的那一刻（含第一项）旧 realm 都必须已经销毁。
    test('V25_I1_old_realm_cannot_write_after_last_clear_before_reload', async () => {
      const f = make(), p = f.open('last-clear-race');
      let attempts = 0;
      const wrote = [];
      f.ports.enteredHooks.push(kind => { attempts++; if (f.ports.oldWrite(p)) wrote.push(kind + ':entered'); });
      f.ports.afterCompletion = kind => { if (f.ports.oldWrite(p)) wrote.push(kind + ':completed'); };
      await f.login(); assert.strictEqual(await completed(p), true);
      assert.ok(attempts >= 3, 'adversary ran at every clear (cookie, local, indexedDB; t6: no cache clear, D10-396)');
      assert.deepStrictEqual(wrote, [], 'old realm must already be destroyed before the first clear starts');
      allClean(p);
    });
    // t6 新增（D10-396 ②）：切号不调用任何 HTTP 缓存清理（removeCache / removeAllCache 都是全应用级，会波及外部 / 隐私页，I6）。
    // (a) 静态：产品源码（按本次运行实际加载的、含变异的文本）里没有对这两个接口的调用（TypeScript AST，注释与字符串不算）；
    // (b) 行为：可信页与外部页同在时切号，外部那份缓存的响应字节仍可读回，可信那份也原样保留，没有任何缓存清理调用；
    // (c) 正向对照：同一读法在显式清缓存之后读不到（证明读法能区分命中 / 未命中，不是空跑）。
    test('V43_D10_396_switch_never_calls_any_http_cache_clear_and_external_cache_survives', async () => {
      const fs = require('fs'), path = require('path'), ts = require(environment.tsDir);
      const { mutate } = require('./fx25-v3-mutations');
      const roots = ['features/web/src/main', 'common/core/src/main', 'entry/src/main', 'entry/src/staging', 'entry/src/release'];
      const files = [];
      const walk = dir => { for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, e.name);
        if (e.isDirectory()) walk(full); else if (/\.(ets|ts)$/.test(e.name)) files.push(full);
      } };
      for (const r of roots) if (fs.existsSync(path.join(environment.root, r))) walk(path.join(environment.root, r));
      assert.ok(files.some(x => x.endsWith('TrustedWebView.ets')) && files.some(x => x.endsWith('TrustedAuthSync.ets')), 'non-vacuous: product sources scanned');
      const calls = [];
      for (const file of files) {
        const text = mutate(file, fs.readFileSync(file, 'utf8'));
        const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
        const visit = node => {
          if (ts.isCallExpression(node)) {
            const callee = node.expression;
            const name = ts.isPropertyAccessExpression(callee) ? callee.name.text :
              ts.isElementAccessExpression(callee) && ts.isStringLiteralLike(callee.argumentExpression) ? callee.argumentExpression.text :
              ts.isIdentifier(callee) ? callee.text : '';
            if (name === 'removeCache' || name === 'removeAllCache') {
              calls.push(path.relative(environment.root, file) + ':' + (sf.getLineAndCharacterOfPosition(node.getStart()).line + 1) + ' ' + node.getText());
            }
          }
          ts.forEachChild(node, visit);
        };
        visit(sf);
      }
      assert.deepStrictEqual(calls, [], 'D10-396: no removeCache / removeAllCache call in product code');
      const f = make(), p = f.open('with-external'), q = f.open('covered-too');
      f.cover(q);
      const before = f.ports.cachedExternal();
      await f.login(); assert.strictEqual(await completed(p), true); await turns();
      f.uncover(q); await turns(40);
      allClean(p); allClean(q); eventOnce(p, true);
      assert.strictEqual(f.ports.cachedExternal(), before, 'external HTTP cache bytes still readable after the switch');
      assert.strictEqual(p.cache, 'old-cache', 'trusted HTTP cache left as is (server side no-store, D10-396 ③)');
      assert.deepStrictEqual([f.ports.signal('cache').calls, f.ports.globalCacheCalls, p.cacheVia.length, q.cacheVia.length], [0, 0, 0, 0],
        'no cache clear API entered, on any controller');
      assert.ok(f.ports.signal('cookie').completed > 0 && f.ports.signal('local').completed > 0, 'non-vacuous: the switch did clean Cookie / DOM');
      f.externalUnchanged();
      // 正向对照：显式清一次（夹具端口，不经产品、不记 globalCalls）之后同一读法读不到。
      f.ports.clearCache();
      assert.throws(() => f.ports.cachedExternal(), /evicted/, 'positive control: the same read sees the eviction');
    });
    test('V26_I4_new_page_auto_retry_does_not_clear_global_pending_for_only_itself', async () => {
      const f = make(), a = f.open('first-blocked');
      f.ports.fault('cookie', 'reject'); await f.login(); assert.strictEqual(await completed(a), false);
      f.ports.failures.delete('cookie');
      const b = f.open('second-triggers-recovery');
      await completed(b);
      assert.strictEqual(await b.config.retryAuth(), true); await turns();
      allClean(a); allClean(b);
      const counts = [a.reloads.length, b.reloads.length];
      assert.strictEqual(await a.config.retryAuth(), true);
      assert.deepStrictEqual([a.reloads.length, b.reloads.length], counts);
    });
    test('V27_I3_I4_second_switch_transaction_outlives_first_completion', async () => {
      const f = make(), p = f.open('second-transaction');
      const first = f.ports.holdCall('cookie', 1), second = f.ports.holdCall('cookie', 2);
      await f.login('user-b'); await first.entered.promise;
      await f.login('user-c');
      first.gate.resolve();
      await second.entered.promise;
      try {
        assert.notStrictEqual(f.ports.journal.readPending(), null, 'first clear must not remove pending later switch');
        isolated(p); noHello(p);
        assert.strictEqual(await bridgeCalls(p), 0);
      } finally { second.gate.resolve(); }
      assert.strictEqual(await completed(p), true); allClean(p);
      assert.strictEqual(f.ports.journal.readPending(), null);
    });
    test('V28_I7_real_token_refresh_never_marks_or_isolates', async () => {
      const f = make(), p = f.open('refresh-control');
      const { envelope, tokenPair } = require(require('path').join(environment.root, 'common/core/src/test/NetworkTestRig.ets'));
      const epoch = f.network.tokens.loginEpoch();
      f.network.server.handler = () => Promise.resolve(envelope(0, tokenPair('refreshed-access', 'refreshed-refresh', 'full')));
      const result = await f.network.client.request(new core.ApiRequest('refreshToken', {}, '',
        '{"refresh_token":"test-refresh-a"}'));
      assert.strictEqual(result.code, 0);
      assert.strictEqual(f.network.tokens.accessToken(), 'refreshed-access');
      assert.strictEqual(f.network.tokens.loginEpoch(), epoch);
      assert.strictEqual(await completed(p), true);
      assert.strictEqual(p.events.length, 0); assert.strictEqual(p.reloads.length, 0);
      assert.strictEqual(f.ports.signal('cookie').calls, 0);
      assert.strictEqual(f.ports.journal.readPending(), null);
      assert.strictEqual(f.ports.journal.trace.some(x => x.startsWith('mark:')), false);
      assert.strictEqual(await bridgeCalls(p), 1, 'normal refresh keeps document usable');
    });
    test('V29_I7_same_account_new_epoch_is_A_only', async () => {
      const f = make(), p = f.open('same-account-control');
      await f.login('user-a'); assert.strictEqual(await completed(p), true);
      eventOnce(p, true);
      assert.strictEqual(p.reloads.length, 0); assert.strictEqual(f.ports.signal('cookie').calls, 0);
      assert.strictEqual(f.ports.journal.readPending(), null);
      assert.strictEqual(f.ports.journal.trace.some(x => x.startsWith('mark:')), false);
      assert.strictEqual(await bridgeCalls(p), 1);
    });
  });
};
