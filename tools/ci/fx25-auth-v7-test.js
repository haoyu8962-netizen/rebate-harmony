// F-X-25 v7（评审 r2 修复后，独立 Claude 测试作者）：实现交回列出的 5 个存活错误实现各至少一条会变红的用例。
// 与 v3 / v6 同一条生产链路：真实 ApiClient → AppBridge → TrustedAuthSync → TrustedWebView 生命周期；测试不调 sync.changed /
// attach / cleanAndReload，不替产品补监听、补清理或补重载。端口在 v6 之外只多两样（都在夹具里，缺省关着，旧用例路径逐字不变）：
// - mountModel：系统派发生产 Web 链上的 onAppear / onDisAppear 回调原文；Web 从 build 撤掉后，节点和旧文档要等 ArkUI 真正卸下
//   （onDisAppear）才销毁，p.holdUnmount 可让它一直挂着（窗口在后台 / Navigation 下层不刷新，R2-05）。
// - owner：按生产签名 AppBridge.trustedAuth(client, epochs, pending, owner) 接「可信 Web 数据归属」记录（R2-04 第三道防线）。
// t1（新方案「先拆后清再建」，D10-279，独立 Claude）：mountModel 现在是夹具唯一模型（开关作废）。改写 V39（旧文档在卸下前写回
// Cookie / localStorage / IndexedDB / sessionStorage 四类，都不得进入新文档）；V40 等待改为按轮次（新方案载体挂上之前不动 Cookie）；
// 作废 V42×2（恢复后进入仍待清的历史源、文档开始清理失败：新方案没有「待清历史源」与文档开始清理）。交令牌监视改挂 scriptHooks。
'use strict';
const assert = require('assert');
const vm = require('vm');
const { Ports, DiskJournal, DiskOwnerRecord, turn, withClock } = require('./fx25-v3-ports');
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
    p.lifecycle.transport.nativeObject.post(token, JSON.stringify({ v: 1, id: 'v7-probe-' + p.scripts.length,
      method: 'app.getEnv', params: {} }));
    await turn();
    return calls;
  }
  // t6（D10-396）：HTTP 缓存不再是切号清理项、不算「脏」；「不调用任何缓存清理」由 test() 的 globalCalls 守卫与下面的显式断言守。
  const dirty = load => load.cookie !== '' || load.local.length > 0 || load.indexedDB.length > 0 ||
    (load.session || []).some(([, value]) => isA(value));
  function heldOrigins(p) {
    return [...p.origins].filter(([, values]) => [...values.values()].some(isA)).map(([origin]) => origin);
  }
  // 交令牌监视：记下每次把令牌送进文档的那一刻，盘上的待清标记和接收文档所在源的 sessionStorage。
  function watchTokens(f, p) {
    const deliveries = [];
    p.scriptHooks.push((script, controller, realm) => {
      if (script.includes('__couliBridgeToken(')) {
        deliveries.push({ origin: realm ? realm.origin : 'none', marker: f.ports.journal.readPending(),
          heldA: !!realm && [...realm.storage.values()].some(isA), document: realm ? realm.index : 0, controller: controller.id });
      }
    });
    return deliveries;
  }
  function seedA(p) {
    p.cookie = 'old-cookie'; p.local.set('owner', 'user-a'); p.indexedDB.set('owner', 'user-a'); p.cache = 'old-cache';
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
  hypium.describe('AuthV7_FX25', () => {
    // ---------- R2-05：旧 Web 节点卸下（onDisAppear）之前不清 Cookie；等不到就失败 ----------
    // t1 改写：旧文档在卸下之前写回四类（Cookie、localStorage、IndexedDB、sessionStorage）。卸下之前任何清理都不得开始；卸下后清理，
    // 重载入口的 profile 与新文档的第一段页面脚本都读不到任何一类旧值（sessionStorage 跟着旧 Web 实例一起没了）。
    test('V39_R2_05_cookie_clear_waits_for_old_web_ondisappear', async () => {
      const f = make({ ports: ports({ mount: true }) }), p = f.open('slow-unmount');
      assert.strictEqual(p.appears, 1, 'non-vacuous: production onAppear handler was dispatched for the initial Web');
      const reads = [];
      p.onDocumentStart = (context, origin) => {
        reads.push({ origin, value: vm.runInContext('sessionStorage.getItem("owner")', context),
          local: vm.runInContext('localStorage.getItem("owner")', context), cookie: vm.runInContext('document.cookie', context),
          idb: vm.runInContext('indexedDB.get("owner")', context) });
      };
      p.holdUnmount = true;
      f.logout();
      await turns();
      assert.ok(p.pendingUnmounts.length > 0, 'production removed the old Web from build (discardDocument)');
      assert.strictEqual(p.disappears, 0);
      // ArkUI 还没卸下节点：旧文档的定时器照样能写回 A 的数据，四类都写。
      const old = p.documents[0];
      assert.strictEqual(old.alive, true, 'precondition: old document still alive until onDisAppear');
      vm.runInContext('document.cookie="old-cookie-rewritten";localStorage.setItem("owner","old-user-rewritten");' +
        'indexedDB.put("owner","old-user-rewritten");sessionStorage.setItem("owner","old-user-rewritten");', old.context);
      old.pagehide = realm => vm.runInContext('sessionStorage.setItem("late","old-user-rewritten");localStorage.setItem("late","old-user-rewritten");' +
        'indexedDB.put("late","old-user-rewritten");document.cookie="late=old-user-rewritten";', realm.context);
      assert.strictEqual(f.ports.clearCalls(), 0, 'R2-05: nothing (Cookie / DOM / IndexedDB / cache) is cleared before the old Web is really gone');
      assert.strictEqual(p.reloads.length, 0); isolated(p);
      assert.ok(p.releaseUnmount() > 0);
      assert.strictEqual(old.alive, false);
      assert.strictEqual(await completed(p), true, 'cleanup proceeds once onDisAppear arrives');
      await turns();
      assert.ok(p.reloads.length > 0, 'replacement load issued');
      for (const r of p.reloads) assert.ok(!dirty(r), 'clean at load entry, including what the old document wrote back: ' + JSON.stringify(r));
      const entry = reads.filter(r => r.origin === ENTRY);
      assert.ok(entry.length > 0, 'the replacement document started on the entry origin');
      for (const r of entry) {
        assert.deepStrictEqual([r.value, r.local, r.cookie, r.idb], [null, null, '', null], 'new document read old write-back: ' + JSON.stringify(r));
      }
      assert.deepStrictEqual([p.cookie, [...p.local], [...p.indexedDB], p.cache], ['', [], [], 'old-cache'],
        'nothing of A survives in Cookie / DOM storage; HTTP cache is not cleared (D10-396)');
      for (const [origin, values] of p.origins) assert.strictEqual(values.size, 0, origin + ': new Web instance sessionStorage');
      isolated(p, false);
      assert.strictEqual(f.ports.journal.readPending(), null);
      assert.strictEqual(await bridgeCalls(p), 1);
    });
    test('V39b_R2_05_old_web_never_disappears_is_failure_not_success', async () => {
      const f = make({ ports: ports({ mount: true }) }), p = f.open('never-unmounts');
      p.holdUnmount = true;
      f.logout();
      await turns();
      assert.ok(p.pendingUnmounts.length > 0, 'production removed the old Web from build');
      f.ports.clock.expire(); // 生产截止计时器
      assert.strictEqual(await completed(p), false, 'no onDisAppear within the deadline must fail closed');
      await turns();
      assert.strictEqual(f.ports.signal('cookie').calls, 0, 'and nothing after it ran');
      assert.strictEqual(p.reloads.length, 0); isolated(p);
      assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker kept');
    });
    // ---------- R2-04 第三道：冷启动无标记时按归属记录补清（读不出 / 没有 / 不符 → 加载前先清；相符 → 照常加载） ----------
    const ownerCases = [
      { name: 'mismatch_member', record: 'account:user-a', tokens: 'b', expect: 'account:user-b', clean: true },
      { name: 'missing', record: null, tokens: 'b', expect: 'account:user-b', clean: true },
      { name: 'unreadable', record: 'account:user-b', fault: 'read', tokens: 'b', expect: 'account:user-b', clean: true },
      { name: 'member_record_guest_now', record: 'account:user-a', tokens: null, expect: 'guest', clean: true },
      { name: 'matches', record: 'account:user-b', tokens: 'b', expect: 'account:user-b', clean: false }
    ];
    for (const c of ownerCases) {
      test('V38_R2_04_cold_start_owner_record_' + c.name + (c.clean ? '_cleans_before_first_load' : '_loads_without_cleanup'), async () => {
        const journal = new DiskJournal();
        const owner = new DiskOwnerRecord(journal.directory);
        if (c.record !== null) owner.writeOwner(c.record);
        owner.trace = [];
        owner.fault = c.fault || '';
        const tokens = c.tokens === 'b' ? new core.SessionTokenSet('access-b', 'refresh-b', 'full', 'user-b', 'epoch-b') : null;
        const f = make({ ports: ports({ journal }), owner, tokens });
        const p = f.open('cold-start');
        assert.ok(owner.trace.includes('read'), 'non-vacuous: production consulted the owner record');
        assert.strictEqual(journal.readPending() === null || c.clean, true);
        if (c.clean) {
          assert.strictEqual(p.loads.length, 0, 'cold trusted initial Web source must not load a profile of unknown / other owner');
          isolated(p);
        }
        assert.strictEqual(await completed(p), true); await turns();
        assert.strictEqual(p.events.length, 0, 'cold storage recovery is not an auth event');
        if (c.clean) {
          assert.ok(f.ports.signal('cookie').completed > 0 && f.ports.signal('local').completed > 0, 'really cleaned');
          assert.strictEqual(f.ports.signal('cache').calls, 0, 'D10-396: no cache clear API');
          assert.ok(p.reloads.length > 0, 'loaded after cleanup');
          for (const load of [...p.loads, ...p.reloads]) assert.ok(!dirty(load), 'clean at every load: ' + JSON.stringify(load));
        } else {
          assert.strictEqual(p.loads.length, 1, 'matching owner: the initial load happens directly');
          assert.deepStrictEqual([f.ports.signal('cookie').calls, f.ports.signal('cache').calls, p.reloads.length], [0, 0, 0],
            'matching owner: no extra wipe of the user own Web data');
        }
        isolated(p, false);
        assert.strictEqual(journal.readPending(), null);
        owner.fault = '';
        assert.strictEqual(owner.readOwner(), c.expect, 'owner record names the identity the Web data now belongs to');
        assert.strictEqual(await bridgeCalls(p), 1);
      });
    }
    // 端到端：标记写不进、紧急同步清理也失败（第 1、2 道都没兜住），杀进程——只剩归属记录能挡住冷启动。
    test('V38e_R2_04_marker_and_scrub_fail_then_kill_only_owner_record_blocks_A_data', async () => {
      const journal = new DiskJournal();
      const owner = new DiskOwnerRecord(journal.directory);
      const old = make({ ports: ports({ journal }), owner }), original = old.open('before-kill');
      assert.strictEqual(await completed(original), true);
      assert.strictEqual(owner.readOwner(), 'account:user-a', 'precondition: first process recorded A as owner of the Web data');
      seedA(original); // A 继续用可信页，Web 数据又是 A 的
      journal.fault = 'mark';
      for (const kind of ['cookie', 'local']) old.ports.fault(kind, 'throw'); // t6：cache 不再是清理项（D10-396）
      old.logout();
      assert.strictEqual(await completed(original), false, 'in-process fails closed');
      isolated(original);
      assert.strictEqual(journal.readPending(), null, 'precondition: no marker reached disk');
      assert.deepStrictEqual([old.ports.profile.cookie, old.ports.profile.local.get('owner'), old.ports.profile.cache],
        ['old-cookie', 'user-a', 'old-cache'], 'precondition: emergency scrub failed, A data still in the profile');
      const persisted = old.network.tokens.current === undefined ? null : old.network.tokens.current;
      assert.strictEqual(persisted, null, 'precondition: logout persisted no session');
      journal.fault = '';
      const reboot = make({ ports: new Ports(new DiskJournal(journal.directory), old.ports.profile),
        owner: new DiskOwnerRecord(journal.directory), tokens: persisted });
      const p = reboot.open('cold-start');
      assert.strictEqual(p.loads.length, 0, 'cold start must not load A Web data for the guest');
      assert.strictEqual(await completed(p), true); await turns();
      for (const load of [...p.loads, ...p.reloads]) assert.ok(!dirty(load), 'cold start loaded A Web data: ' + JSON.stringify(load));
      assert.ok(p.reloads.length > 0, 'and it does recover');
      isolated(p, false);
    });
    // ---------- R2-02：在开的只有被拒页（没有 Web）= 没有在开可信页面：延期，不判失败；标记保留到下一个有 Web 的页面 ----------
    test('V40_R2_02_only_refused_pages_defers_like_no_trusted_page', async () => {
      const none = make({ ports: ports({ attach: true }) });
      const sync = none.boot(); // App 启动时的同一个生产入口；没有任何容器
      none.logout();
      const noPage = await completed(sync.settled());
      assert.notStrictEqual(none.ports.journal.readPending(), null, 'reference: no trusted page keeps the marker');
      const f = make({ ports: ports({ attach: true }) });
      const head = f.open('under-login');
      assert.strictEqual(head.lifecycle.initialWeb(), null, 'precondition: refused container has no Web');
      f.logout();
      await turns(40); // t1：载体挂上之前不动 Cookie，等轮次而不是等 Cookie 完成
      const ok = await completed(head);
      assert.strictEqual(ok, noPage, 'same outcome as no trusted page open');
      assert.strictEqual(ok, true, 'deferral is not a failure: a Web-less container must not be turned into a retry loop');
      assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker kept: no trusted Web to clean through (deferral)');
      assert.deepStrictEqual([head.loads.length, head.reloads.length], [0, 0], 'auth page never loads in a trusted container');
      assert.strictEqual(await bridgeCalls(head), 0);
      const p = f.open('normal-after');
      assert.strictEqual(p.loads.length, 0, 'next trusted page with a Web does not load before the pending cleanup');
      isolated(p);
      assert.strictEqual(await completed(p), true); await turns();
      assert.ok(f.ports.signal('cookie').completed > 0 && f.ports.signal('local').completed > 0, 'cleaned once a trusted Web exists');
      assert.strictEqual(f.ports.signal('cache').calls, 0, 'D10-396: no cache clear API');
      assert.ok(p.reloads.length > 0);
      for (const r of p.reloads) assert.ok(!dirty(r), 'clean at load entry: ' + JSON.stringify(r));
      isolated(p, false);
      assert.strictEqual(f.ports.journal.readPending(), null);
      assert.deepStrictEqual([head.loads.length, head.reloads.length], [0, 0]);
    });
    // ---------- R2-01d：隔离只在待清标记删掉并核对之后解除（回执通过不等于事务成功） ----------
    function historyOrigin(f, name, origins = [ENTRY, OTHER]) {
      const p = f.open(name);
      p.config.trustedOrigins = () => origins;
      p.config.host.state.trustedOrigins = () => origins; // 宿主的来源核对与容器白名单同一份（生产里都来自 BridgeStatePort）
      for (const origin of origins.slice(1)) {
        p.controller.url = origin + '/page';
        p.createDocument(); p.sessionStorage.set('owner', 'user-a'); p.lifecycle.transport.pageStarted();
      }
      for (const origin of origins) assert.strictEqual(p.origins.get(origin).get('owner'), 'user-a', 'precondition: ' + origin + ' holds A');
      return p;
    }
    for (const path of ['history_origin', 'current_origin']) {
      test('V41_R2_01d_' + path + '_no_token_while_pending_marker_on_disk', async () => {
        const f = make({ ports: ports() });
        const p = path === 'history_origin' ? historyOrigin(f, 'release-order') : f.open('release-order');
        const deliveries = watchTokens(f, p);
        await f.login();
        assert.strictEqual(await completed(p), true); await turns();
        assert.ok(deliveries.length > 0, 'non-vacuous: the replacement document did receive a token');
        for (const d of deliveries) {
          assert.strictEqual(d.marker, null, 'R2-01d: token (isolation lifted) while the pending marker is still on disk: ' + JSON.stringify(d));
          assert.strictEqual(d.heldA, false);
        }
        isolated(p, false);
      });
    }
    test('V41b_R2_01d_history_origin_marker_removal_fails_stays_isolated_no_token', async () => {
      const f = make({ ports: ports() }), p = historyOrigin(f, 'remove-fails');
      f.ports.journal.fault = 'remove';
      const deliveries = watchTokens(f, p);
      await f.login();
      assert.strictEqual(await completed(p), false, 'marker removal failure fails the transaction');
      await turns();
      assert.ok(f.ports.journal.trace.includes('remove'), 'non-vacuous: production reached the marker removal');
      assert.deepStrictEqual(deliveries, [], 'no token to the replacement document before the transaction succeeded');
      isolated(p);
      assert.strictEqual(await bridgeCalls(p), 0);
      f.ports.journal.fault = '';
      assert.notStrictEqual(f.ports.journal.readPending(), null, 'marker kept');
    });
    // t1 作废 V42×2（V42_R2_03c_navigate_to_still_dirty_history_origin_{start_clear_fails_no_token,control_token_after_clear}）：
    // 前提「恢复后仍有待清的历史源、进入它时在文档开始清理」不存在了——新方案切号后整个 Web 实例换新，所有源的 sessionStorage
    // 随旧实例一起销毁，没有遗留的待清源，也没有文档开始清理这一步。新文档读不到任何源的 A 由 V31 / V39 / N2 守。
  });
};
