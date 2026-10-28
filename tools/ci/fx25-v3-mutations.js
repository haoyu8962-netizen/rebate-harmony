// 只在 Node 内存里改真实产品源码；不写 src/main 或工作树副本。
// t1（新方案「先拆后清再建」，D10-279，独立 Claude）：作废 3（delete-session、token-before-session-wipe、release-on-receipt：sessionStorage
// 追踪整套删除，这三个调用点不存在了）；保留并重新定位 13；改写 1（token-before-fresh-confirm → open-before-marker-cleared）；新增 11
// （其中 partial-clear 两个写法、global-clear 三个写法）。
// 三种改法：
// - text：原文恰好出现一次（inside / outside 可把范围限定在某个方法体内 / 之外），否则 DRIFT 失败，绝不跳过；
// - regex：正则恰好匹配一次；
// - wrap：把方法 NAME（本文件里恰好一个这样的方法定义）改名为 __fx25_NAME，再插入同名包装（包装体里 ORIGINAL(...) 调原方法）。
//   包装只依赖 plan-teardown.md 附表 A 定下的方法名（discardDocument / mountFresh / bind / pageStarted、attempt / finish /
//   checkOwner、TrustedWebProfile.clearStorage），不依赖方法体原文，实现换写法也不用重定位。
// 实现交付后：text / regex 类按新调用点重新定位（目标用例不许改），然后「目标先绿 → 变异变红」。
'use strict';
const WEB = 'features/web/src/main/ets/TrustedWebView.ets';
const SYNC = 'common/core/src/main/ets/bridge/TrustedAuthSync.ets';
const APP = 'entry/src/main/ets/web/AppBridge.ets';
const edits = {
  // ---- 保留并重新定位（13） ----
  'delete-cookie': { file: WEB, from: 'await webview.WebCookieManager.clearAllCookies();', to: '' },
  'delete-dom-and-indexeddb': { file: WEB, from: 'webview.WebStorage.deleteAllData(false);', to: '' },
  // t6（D10-396）作废 delete-cache（定位点 this.clearCache(pages) 随缓存清理一起从产品删除；切号不再清 HTTP 缓存）。反方向的
  // 变异见下面 switch-calls-removeCache。
  // v6（R2-03b，评审 M3）：控制器未挂上（17100001）当成功。t6（D10-396）重新定位：原定位点 clearCache 里的 17100001 分支已删，
  // 现在载体上唯一会撞到 17100001 的是入口加载（loadEntry）；变异 = 17100001 当成「新文档已加载」，直接解除隔离并兑现。
  'not-attached-as-success': { file: WEB, inside: 'loadEntry', target: 'AuthV6_FX25.V35_|AuthT3_FX25.T3_C2_',
    from: 'if (BridgeTransport.notAttached(e as BusinessError)) {',
    to: 'if (BridgeTransport.notAttached(e as BusinessError)) {\n        if (this.authCleared) { this.open(); this.settleFresh(null); return true; }' },
  // R2-05a → t1：拆不等两信号（Web 照常撤出 build，但不等 onDisAppear / 17100001 就报拆完）。
  'discard-without-unmount-wait': { file: WEB, wrap: 'discardDocument', target: 'AuthV7_FX25.V39_|AuthT1_FX25.N1_',
    body: 'ORIGINAL(...__fx25a).catch(() => {}); return Promise.resolve();' },
  // R2-01d → t1：删标记之前就解除隔离。新方案里「解除」只对重载出的新文档生效，单独提前 release 是空操作（等价变异），所以
  // 写成「先 release 并重载、再删标记」——新文档在标记还在盘上时就开放、拿令牌。
  'release-before-marker': { file: SYNC, wrap: 'finish', target: 'AuthV7_FX25.V41',
    body: 'for (const page of this.pages.slice()) { try { page.release(); page.reload().catch(() => {}); } catch (e) {} } return ORIGINAL(...__fx25a);' },
  // R2-04c：忽略归属记录（冷启动比对整个不做）。
  'ignore-owner-record': { file: SYNC, wrap: 'checkOwner', target: 'AuthV7_FX25.V38|AuthT1_FX25.N7_R3_04_',
    body: 'return;' },
  'owner-missing-as-clean': { file: SYNC, target: 'AuthV7_FX25.V38_R2_04_cold_start_owner_record_missing_|AuthT1_FX25.N7_R3_04_production_sandbox_owner_record_missing',
    from: 'if (recorded !== null && recorded === TrustedAuthSync.ownerKey(this.confirmed)) {',
    to: 'if (recorded === null || recorded === TrustedAuthSync.ownerKey(this.confirmed)) {' },
  'owner-unreadable-as-clean': { file: SYNC, target: 'AuthV7_FX25.V38_R2_04_cold_start_owner_record_unreadable_',
    from: '      recorded = this.ownerRecord.readOwner();\n    } catch (e) {\n      recorded = null;',
    to: '      recorded = this.ownerRecord.readOwner();\n    } catch (e) {\n      return;' },
  'owner-guest-not-compared': { file: SYNC, target: 'AuthV7_FX25.V38_R2_04_cold_start_owner_record_member_record_guest_now_',
    from: 'if (recorded !== null && recorded === TrustedAuthSync.ownerKey(this.confirmed)) {',
    to: 'if (this.confirmed.account === null || recorded !== null && recorded === TrustedAuthSync.ownerKey(this.confirmed)) {' },
  // R2-02c → t1：延期（在开的都没有 Web / 只有被压页）判成失败。
  'webless-only-is-failure': { file: SYNC, wrap: 'attempt', target: 'AuthV7_FX25.V40_|AuthT1_FX25.N6_only_refused|AuthT1_FX25.N3_only_covered',
    body: 'const deferred = await ORIGINAL(...__fx25a); if (deferred === true && this.pages.length > 0) { throw new Error(\'no trusted controller\'); } return deferred;',
    async: true },
  // R2-04a：登录不先写标记。
  'no-login-guard': { file: APP, target: 'AuthV3_FX25.V13_I3_journal_mark_',
    from: 'client.guardSessionSave((account: string | null): boolean => sync.admit(account));', to: '' },
  // R2-04b：写标记失败不做紧急同步清理。
  'no-emergency-scrub': { file: SYNC, target: 'AuthV6_FX25.V37b_',
    from: '      if (!this.recorded) {\n        this.scrub();\n      }', to: '' },
  // ---- 改写（1）：token-before-fresh-confirm → 新文档一开始就解除隔离、交令牌（不等删标记） ----
  'open-before-marker-cleared': { file: WEB, wrap: 'pageStarted', target: 'AuthV7_FX25.V41|AuthT1_FX25.N4_marker',
    body: 'const result = ORIGINAL(...__fx25a); if (this.isolated() && typeof this.open === \'function\') { this.open(); } return result;' },
  // ---- 新增（11） ----
  // 先清后拆：拆之前就清 Cookie / DOM（旧文档还活着）。
  'clear-before-teardown': { file: SYNC, wrap: 'attempt', target: 'AuthT1_FX25.N1_|AuthV7_FX25.V39_', async: true,
    body: 'try { await this.store.clearCookies(); this.store.clearStorage(); } catch (e) {} return ORIGINAL(...__fx25a);' },
  // 只拆最前面的一页（被压页、后台页不拆）。
  'skip-covered-teardown': { file: WEB, wrap: 'discardDocument', target: 'AuthT1_FX25.N3_covered|NativeAuth_FX25.P02_|AuthT1_FX25.N2_',
    body: 'BridgeTransport.__fx25torn = (BridgeTransport.__fx25torn || 0) + 1; if (BridgeTransport.__fx25torn > 1) { return Promise.resolve(); } return ORIGINAL(...__fx25a);' },
  // 复用旧控制器：组件 / 传输层里每一处 new webview.WebviewController() 都换成「本对象第一次 new 出来的那个」。
  'reuse-old-controller': { file: WEB, regexAll: 'new webview\\.WebviewController\\(\\)', to: '(this.__fx25Kept ??= new webview.WebviewController())',
    target: 'NativeAuth_FX25.P01_|AuthT1_FX25.N2_|AuthT1_FX25.N4_cookie' },
  // 清理失败仍新建并加载（attempt 的失败被吞掉，finish 照常走）。
  'load-after-clear-failure': { file: SYNC, wrap: 'attempt', target: 'AuthT1_FX25.N4_', async: true,
    body: 'try { return await ORIGINAL(...__fx25a); } catch (e) { return false; }' },
  // 只清部分存储：事务里跳过 DOM 存储（紧急同步清理 scrub 里的那次不动）。
  'partial-clear-skip-dom': { file: SYNC, from: 'this.store.clearStorage();', to: '', outside: 'scrub', target: 'AuthV3_FX25.V24_|AuthV3_FX25.V05_I2_local' },
  // t6（D10-396）作废 partial-clear-skip-cache（包装的 clearCache 方法已删；不清缓存现在是正确行为，不再是变异）。
  // 不删标记就新建加载：finish 一开始就让所有页面重载入口。
  'load-before-marker-cleared': { file: SYNC, wrap: 'finish', target: 'AuthV7_FX25.V41|AuthV3_FX25.V13_I3_journal_remove|AuthT1_FX25.N4_marker',
    body: 'for (const page of this.pages.slice()) { try { page.reload().catch(() => {}); } catch (e) {} } return ORIGINAL(...__fx25a);' },
  // 调全局清理接口（三种写法）；每个用例结束都核对全局调用为 0，所以凡是走到清理的目标用例都会红。
  // t6（D10-396）重新定位：原定位点 removeCache(true) 已删；改为清 DOM 存储时顺手调静态 removeAllCache(true)。
  'global-clear-removeAllCache': { file: WEB, from: 'webview.WebStorage.deleteAllData(false);',
    to: 'webview.WebviewController.removeAllCache(true);\n    webview.WebStorage.deleteAllData(false);',
    target: 'AuthV3_FX25.V24_|AuthV3_FX25.V43_|AuthT1_FX25.N6_' },
  // t6 新增（D10-396 ②，必须红）：切号时经载体控制器调用 removeCache(true)（即删掉前的产品行为：全应用级，会波及外部 / 隐私页）。
  'switch-calls-removeCache': { file: WEB, inside: 'loadEntry', from: 'this.controller.loadUrl(this.authEntryUrl);',
    to: 'this.controller.removeCache(true);\n      this.controller.loadUrl(this.authEntryUrl);',
    target: 'AuthV3_FX25.V43_|AuthV3_FX25.V24_|NativeAuth_FX25.P01_|AuthT1_FX25.N2_' },
  // t6 新增：同上，只清内存缓存的写法（removeCache(false)）同样是全应用级，同样禁止。
  'switch-calls-removeCache-memory': { file: WEB, inside: 'loadEntry', from: 'this.controller.loadUrl(this.authEntryUrl);',
    to: 'this.controller.removeCache(false);\n      this.controller.loadUrl(this.authEntryUrl);',
    target: 'AuthV3_FX25.V43_|NativeAuth_FX25.P01_' },
  'global-clear-deleteAllData': { file: WEB, from: 'webview.WebStorage.deleteAllData(false);', to: 'webview.WebStorage.deleteAllData(true);',
    target: 'AuthV3_FX25.V24_|AuthV3_FX25.V20_|AuthT1_FX25.N6_' },
  'global-clear-clearAllCookiesSync': { file: WEB, from: 'await webview.WebCookieManager.clearAllCookies();',
    to: 'webview.WebCookieManager.clearAllCookiesSync(true);', target: 'AuthV3_FX25.V24_|AuthV3_FX25.V19_|AuthT1_FX25.N6_' },
  // 换控制器时新建 BridgePageSession（世代号从 0 重来）。
  'new-page-session': { file: WEB, wrap: 'bind', target: 'AuthT1_FX25.N5_|NativeAuth_FX25.P08_',
    body: 'const result = ORIGINAL(...__fx25a); this.session = new BridgePageSession(randomToken); this.host.pageGeneration = () => this.session.generation; return result;' },
  // 旧 nativeObject 仍转发（换控制器时不换代理对象）。
  'old-proxy-bound': { file: WEB, wrap: 'bind', target: 'AuthT1_FX25.N2_',
    body: 'const old = this.nativeObject; const result = ORIGINAL(...__fx25a); this.nativeObject = old; return result;' },
  // 拆前不等 A 执行完。
  'teardown-before-A': { file: SYNC, from: 'await this.drainNotices();', to: '', inside: 'attempt', target: 'AuthV3_FX25.V21_|NativeAuth_FX25.P10_' },
  // R3-03：身份未知时照常加载（推迟比对）。不论修法写在 attach 还是 checkOwner：容器登记那一刻身份未知时，把「还要比对归属」藏起来。
  'owner-unknown-loads': { file: SYNC, wrap: 'attach', target: 'AuthT1_FX25.N7_R3_03_',
    body: 'const due = this.ownerCheckDue; const unknown = !this.read().known; if (unknown) { this.ownerCheckDue = false; } ' +
      'const result = ORIGINAL(...__fx25a); if (unknown && !this.confirmed.known) { this.ownerCheckDue = due; } return result;' },
  // ---- t3（设备问题修复后；目标用例在 tools/ci/fx25-auth-t3-test.js） ----
  // 不等载体空白页：reload 一来就发入口（空白页还在途 → 被顶掉）。
  'no-carrier-settle-wait': { file: WEB, from: 'if (this.carrierSettled) {\n      this.firstEntryLoad();', to: 'if (true) {\n      this.firstEntryLoad();',
    inside: 'reload', target: 'AuthT3_FX25.T3_L1_' },
  // 等载体空白页没有期限：空白页的 onPageBegin 不来（加载被取消）就永远不发入口。
  'no-settle-fallback': { file: WEB, inside: 'reload', target: 'AuthT3_FX25.T3_L2_',
    from: '        this.carrierSettled = true;\n        this.flushSettle();\n      }, BridgeTransport.CARRIER_SETTLE_MS);',
    to: '      }, BridgeTransport.CARRIER_SETTLE_MS);' },
  // 去掉看门狗：入口请求被吞就永远等着。
  'no-entry-watchdog': { file: WEB, from: 'this.watchEntryStart();', to: '', inside: 'loadEntry', target: 'AuthT3_FX25.T3_L3_|AuthT3_FX25.T3_L5_' },
  // 「发了 loadUrl」就当作已开始（原设备缺陷：没发请求当成功）。
  'loadurl-counts-as-started': { file: WEB, from: 'this.watchEntryStart();', to: 'this.watchEntryStart();\n      this.entryStarted = true;',
    inside: 'loadEntry', target: 'AuthT3_FX25.T3_L3_' },
  // 重发次数无上限。
  'unbounded-entry-retries': { file: WEB, from: 'if (this.entryAttempts >= BridgeTransport.ENTRY_LOAD_ATTEMPTS) {', to: 'if (false) {',
    inside: 'watchEntryStart', target: 'AuthT3_FX25.T3_L5_' },
  // 未开始即解除隔离（一）：onLoadIntercept 放行入口就解除（新文档还没开始）。
  'open-at-intercept': { file: WEB, inside: 'navigationStarted', target: 'AuthT3_FX25.T3_L3_',
    from: '      this.entryStarted = true;\n    }', to: '      this.entryStarted = true;\n      this.open();\n      this.settleFresh(null);\n    }' },
  // 未开始即解除隔离（二）：等入口期间任何新文档开始都算（载体自己的空白页也解除）。
  'open-on-blank-begin': { file: WEB, inside: 'pageStarted', target: 'AuthT3_FX25.T3_L4_',
    from: 'if (this.authAwaiting && this.authCleared && this.carrierReady && trusted) {',
    to: 'if (this.authAwaiting && this.authCleared && this.carrierReady) {' },
  // 看门狗不认「已开始」：请求已发出、文档还在加载也重发（取消 / 双加载）。
  'watchdog-ignores-start': { file: WEB, inside: 'watchEntryStart', target: 'AuthT3_FX25.T3_D1_',
    from: 'if (!this.authAwaiting || this.entryStarted || controller !== this.controller || this.disposed) {',
    to: 'if (!this.authAwaiting || controller !== this.controller || this.disposed) {' },
  // 看门狗活过事务（两处一起：隔离 / 换控制器 / 解除时不撤计时器，到时也不核对本轮状态）——解除隔离后或下一轮里再加载一次。
  'watchdog-outlives-transaction': { file: WEB, target: 'AuthT3_FX25.T3_D2_|AuthT3_FX25.T3_D3_', steps: [
    { wrap: 'stopEntryWatch', body: 'this.stopSettleTimer();' },
    { inside: 'watchEntryStart', from: 'if (!this.authAwaiting || this.entryStarted || controller !== this.controller || this.disposed) {',
      to: 'if (this.disposed) {' }] },
  // 只认数值码（设备上 code 是字符串 "17100001"）。
  'numeric-code-only': { file: WEB, inside: 'notAttached', target: 'AuthT3_FX25.T3_C1_|AuthT3_FX25.T3_C2_',
    from: 'return Number(e.code) === BridgeTransport.CONTROLLER_NOT_ATTACHED;', to: 'return e.code === BridgeTransport.CONTROLLER_NOT_ATTACHED;' },
  // 空值不设防（null / undefined 读 code 抛错）。
  'not-attached-null-unguarded': { file: WEB, inside: 'notAttached', target: 'AuthT3_FX25.T3_C1_',
    from: 'if (e === null || e === undefined) {\n      return false;\n    }', to: '' },
  // ---- t4（评审新 r1 之后；目标用例在 tools/ci/fx25-auth-t4-test.js 与 t1 N1） ----
  // NR1-04：拆只等 17100001、不等 onDisAppear（评审探针 nr1-other-signal）。
  'teardown-skip-disappear-signal': { file: WEB, inside: 'discardDocument', target: 'AuthT4_FX25.T4_D1_',
    from: 'this.webNodes === 0 && BridgeTransport.unbound(old)', to: 'BridgeTransport.unbound(old)' },
  // NR1-04：拆只等 onDisAppear、不等 17100001（评审探针 nr1-one-signal）。
  'teardown-skip-unbind-signal': { file: WEB, inside: 'discardDocument', target: 'AuthT1_FX25.N1_|AuthT4_FX25.T4_G2_',
    from: 'this.webNodes === 0 && BridgeTransport.unbound(old)', to: 'this.webNodes === 0' },
  // NR1-01 (1)：隔离中放行子资源（只拦主框架 / 子框架文档，回到 r1 时的写法）。按方法名包装，不依赖方法体原文。
  'isolated-subresources-allowed': { file: WEB, wrap: 'interceptResource', target: 'AuthT4_FX25.T4_I1_',
    body: 'let main = true; try { main = __fx25a[0].isMainFrame(); } catch (e) {} ' +
      'if (this.transport !== null && this.transport.isolated() && !main) { return null; } return ORIGINAL(...__fx25a);' },
  // NR1-01 (1)：隔离中连 reload 之后入口的主框架加载也拦（新文档永远出不来）。
  'isolated-entry-refused': { file: WEB, wrap: 'interceptResource', target: 'AuthT4_FX25.T4_I1_',
    body: 'if (this.transport !== null && this.transport.isolated()) { return TrustedWebView.forbidden(); } return ORIGINAL(...__fx25a);' },
  // NR1-01 (2)：不留宽限，拆完立刻清 Cookie（实现进行中的写法；交回后按新调用点重新定位）。
  'no-cookie-grace': { file: SYNC, from: 'await TrustedAuthSync.pause(TrustedAuthSync.COOKIE_GRACE_MS);', to: '',
    target: 'AuthT4_FX25.T4_G1_' },
  // NR1-01 (3)：不读回（读回永远说「没有了」）。
  'no-cookie-readback': { file: WEB, wrap: 'cookiesRemain', target: 'AuthT4_FX25.T4_R1_|AuthT4_FX25.T4_R2_', body: 'return false;' },
  // NR1-01 (3)：读回抛错当作「没有了」（吞错）。
  'readback-error-as-clean': { file: WEB, wrap: 'cookiesRemain', target: 'AuthT4_FX25.T4_R3_',
    body: 'try { return ORIGINAL(...__fx25a); } catch (e) { return false; }' },
  // NR1-01 (3)：读回非空也只清一轮（不再清，直接失败关门）。
  'single-cookie-round': { file: SYNC, regex: 'COOKIE_CLEAR_ROUNDS: number = \\d+', to: 'COOKIE_CLEAR_ROUNDS: number = 1',
    target: 'AuthT4_FX25.T4_R1_' },
  // NR1-01 (3)：轮数没有上限（一直有 Cookie 落地就一直清）。
  'unbounded-cookie-rounds': { file: SYNC, regex: 'COOKIE_CLEAR_ROUNDS: number = \\d+', to: 'COOKIE_CLEAR_ROUNDS: number = 1000',
    target: 'AuthT4_FX25.T4_R2_' }
  // 作废：delete-session（page.clearSessionStorage 已删）、token-before-session-wipe（verifyThenDeliver 已删）、release-on-receipt
  // （confirmFresh / freshToken 回执已删）。理由同 V04 / V32b / V42 作废。
};
const DEFAULT_TARGET = 'AuthV3_FX25.V24_';
function drift(name, why) {
  throw new Error('Mutation site drift: ' + name + ' (' + why + '); adapt to new production call, never skip');
}
/** 方法 name 的定义（两格缩进的类成员；恰好一个）；返回 { start, headerEnd, end, header }。 */
function methodRange(name, source, mutation) {
  const header = new RegExp('^  ((?:private |public |protected )?(?:static )?(?:async )?)' + name + '\\(([^)]*)\\)(:[^{\\n]*)? \\{$', 'mg');
  const found = [...source.matchAll(header)];
  if (found.length !== 1) drift(mutation, 'method ' + name + ' defined ' + found.length + ' times');
  const start = found[0].index;
  const headerEnd = start + found[0][0].length;
  const end = source.indexOf('\n  }\n', headerEnd);
  if (end < 0) drift(mutation, 'end of method ' + name);
  return { start, headerEnd, end, match: found[0] };
}
function mutate(filename, source) {
  const name = process.env.FX25_MUTATION;
  if (!name) return source;
  const edit = edits[name];
  if (!edit) throw new Error('Unknown mutation: ' + name);
  if (!filename.replaceAll('\\', '/').endsWith(edit.file)) return source;
  // t3：steps = 同一文件里依次做几处改动（每一步同样定位不到就 DRIFT）。
  if (edit.steps) return edit.steps.reduce((text, step) => apply(name, step, text), source);
  return apply(name, edit, source);
}
function apply(name, edit, source) {
  if (edit.wrap) {
    const { start, match } = methodRange(edit.wrap, source, name);
    const modifiers = match[1].replace('async ', '');
    const wrapper = '  ' + modifiers + (edit.async ? 'async ' : '') + edit.wrap + '(...__fx25a) {\n    ' +
      edit.body.replaceAll('ORIGINAL(', 'this.__fx25_' + edit.wrap + '(') + '\n  }\n';
    const renamed = match[0].replace(edit.wrap + '(', '__fx25_' + edit.wrap + '(');
    return source.slice(0, start) + wrapper + renamed + source.slice(start + match[0].length);
  }
  if (edit.regexAll) {
    const pattern = new RegExp(edit.regexAll, 'g');
    if (!pattern.test(source)) drift(name, 'pattern ' + edit.regexAll + ' not found');
    return source.replace(new RegExp(edit.regexAll, 'g'), edit.to);
  }
  if (edit.regex) {
    const found = [...source.matchAll(new RegExp(edit.regex, 'g'))];
    if (found.length !== 1) drift(name, 'pattern matched ' + found.length + ' times');
    return source.slice(0, found[0].index) + edit.to + source.slice(found[0].index + found[0][0].length);
  }
  let lo = 0, hi = source.length, skip = null;
  if (edit.inside) { const r = methodRange(edit.inside, source, name); lo = r.headerEnd; hi = r.end; }
  if (edit.outside) { const r = methodRange(edit.outside, source, name); skip = [r.start, r.end]; }
  const hits = [];
  for (let i = source.indexOf(edit.from, lo); i >= 0 && i < hi; i = source.indexOf(edit.from, i + 1)) {
    if (skip && i >= skip[0] && i < skip[1]) continue;
    hits.push(i);
  }
  if (hits.length !== 1) drift(name, 'site found ' + hits.length + ' times');
  return source.slice(0, hits[0]) + edit.to + source.slice(hits[0] + edit.from.length);
}
module.exports = { mutate, edits };
if (require.main === module) {
  const { spawnSync } = require('child_process');
  const path = require('path');
  const runner = path.join(__dirname, 'fx25-auth-change-test.js');
  const run = (mutation, target) => spawnSync(process.execPath, [runner], { encoding: 'utf8',
    env: { ...process.env, FX25_MUTATION: mutation, FX25_TEST_FILTER: target }, timeout: 300000 });
  const only = process.argv.slice(2);
  const names = Object.keys(edits).filter(name => only.length === 0 || only.includes(name));
  const baselines = new Map();
  let bad = 0;
  // 每个变异只在它的目标用例先在未变异产品上全绿时才计入；目标基线红 = BASELINE-RED（不计，不算杀死）；定位不到 = DRIFT（失败，不跳过）。
  for (const name of names) {
    const target = edits[name].target || DEFAULT_TARGET;
    if (!baselines.has(target)) baselines.set(target, run('', target));
    const base = baselines.get(target);
    const red = base.stdout.split('\n').filter(line => line.startsWith('FAIL ')).map(line => line.slice(5));
    if (base.status !== 0 || !base.stdout.includes('PASS ') || red.length > 0) {
      bad++;
      console.log('BASELINE-RED ' + name + ' [' + target + '] — not credited; red targets: ' + red.join(', '));
      continue;
    }
    const result = run(name, target);
    if (result.stdout.includes('Mutation site drift') || result.stderr.includes('Mutation site drift')) {
      bad++;
      const why = /Mutation site drift: [^\n]*/.exec(result.stdout + result.stderr);
      console.log('DRIFT ' + name + ' — ' + (why ? why[0] : ''));
      continue;
    }
    const killers = result.stdout.split('\n').filter(line => line.startsWith('FAIL ') && !/harness|Core /.test(line)).map(line => line.slice(5));
    const killed = result.status === 1 && killers.length > 0 && !/FAIL (V3|V6|V7|T1|Native) harness/.test(result.stdout);
    console.log((killed ? 'KILLED ' : 'SURVIVED ') + name + ' [' + target + ']' + (killed ? ' by ' + killers.join(', ') : ''));
    if (!killed) { bad++; console.log(result.stdout.split('\n').slice(-30).join('\n') + result.stderr); }
  }
  console.log('mutations: ' + names.length + '; not killed (survived / drift / baseline red): ' + bad);
  process.exitCode = bad ? 1 : 0;
}
