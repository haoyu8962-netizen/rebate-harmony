// F-X-25 系统端口；只模拟存储、文档及完成信号，不含身份决策/订阅/重载调度。
// t1（新方案「先拆后清再建」，D10-279）：sessionStorage 不再由端口按「页 × 源」保存（作废），改由夹具按 Web 实例保存（新实例 = 新命名空间，
// 前提由设备 E01 取证）；Cookie / localStorage / IndexedDB / HTTP 缓存仍是所有可信容器共用的一份 profile。端口只多三样：
// - 全局清理接口（removeAllCache、deleteAllData(true)、clearAllCookiesSync(true)、带参数的 clearAllCookies）一律记进 globalCalls（I6）；
//   t6（D10-396）：控制器的 removeCache 也是全应用级（clearCache 同样清外部那一份），由夹具记进 globalCalls；HTTP 缓存不再是切号
//   清理项，可信 profile 的 cache 切号后应原样保留（'old-cache'）；

// - enteredHooks：每项清理进入系统接口的那一刻通知观察者（用来断言「此刻旧文档都已销毁」，I1）；
// - 生产沙盒文件（@kit.CoreFileKit 的 fileIo）的 Node 端口：只在测试显式打开、且只允许测试自己的临时目录，生产 FileSlot / FileTrusted* 原样执行。
// t4（评审新 r1 之后，NR1-01）：
// - Cookie 读回（existCookie / fetchCookieSync / fetchCookie，只读）：读 profile 里那一份；readbackFault = 'throw' 时读回抛错；
//   每次读回记进 readbacks（读的是哪种接口、当时 Cookie 已完成清理几次、读到什么）。lateCookie(value) 模拟「迟到响应的
//   Set-Cookie 此刻落进共用 Cookie 库」。
// - 拆后宽限计时器（生产 TrustedAuthSync.COOKIE_GRACE_MS，只认 core 经本模块 setTimeout 设的、恰好这个时长的那一个）：缺省下一轮
//   自己到期；Clock.holdGrace() 之后只在 releaseGrace() 时到期，expire() 也会让它到期，expireDelay(ms) 不碰它（t3 的入口看门狗
//   恰好也是 2000 ms）。onGrace(event) 记 'start' / 'end'。
'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { AsyncLocalStorage } = require('async_hooks');
const clocks = new AsyncLocalStorage();
const turn = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, bad) => { resolve = ok; reject = bad; });
  return { promise, resolve, reject };
}
class DiskJournal {
  constructor(directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fx25-journal-'))) {
    this.directory = directory;
    this.file = path.join(directory, 'pending.json');
    this.trace = [];
    this.fault = '';
  }
  readPending() {
    this.trace.push('read');
    if (this.fault === 'read') throw new Error('pending read failed');
    return fs.existsSync(this.file) ? JSON.parse(fs.readFileSync(this.file, 'utf8')) : null;
  }
  markPending(owner) {
    this.trace.push('mark:' + owner);
    if (this.fault === 'mark') throw new Error('pending write failed');
    assert.strictEqual(typeof owner, 'string');
    fs.writeFileSync(this.file, JSON.stringify(owner));
  }
  clearPending() {
    this.trace.push('remove');
    if (this.fault === 'remove') throw new Error('pending remove failed');
    fs.rmSync(this.file, { force: true });
  }
  dispose() { fs.rmSync(this.directory, { force: true, recursive: true }); }
}
// v7（R2-04 第三道）：「可信 Web 数据归属」记录的磁盘替身（生产 FileTrustedWebOwnerRecord 的语义：没有为 null，读写失败抛出）。
// 和标记放同一个目录，杀进程模型里一起带走。生产类本身由 t1 的 N7 经 sandboxFileIo 真实执行（R3-04）。
class DiskOwnerRecord {
  constructor(directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fx25-owner-'))) {
    this.directory = directory;
    this.file = path.join(directory, 'owner.json');
    this.trace = [];
    this.fault = '';
  }
  readOwner() {
    this.trace.push('read');
    if (this.fault === 'read') throw new Error('owner record read failed');
    return fs.existsSync(this.file) ? JSON.parse(fs.readFileSync(this.file, 'utf8')) : null;
  }
  writeOwner(owner) {
    this.trace.push('write:' + owner);
    if (this.fault === 'write') throw new Error('owner record write failed');
    assert.strictEqual(typeof owner, 'string');
    fs.writeFileSync(this.file, JSON.stringify(owner));
  }
}
// 假系统时钟：期限类长计时器（≥ SHORT_MS）只在测试 expire() 时触发；短计时器（产品轮询，例如等旧控制器报 17100001）下一轮事件
// 循环自己触发，不需要测试推动，也不会被 expire() 算进「到期的期限」。
// t3：hold(ms) 让恰好这个时长的短计时器也改按期限对待（只在 expireDelay(ms) / expire() 时触发；缺省不用，原行为不变）；
// expireDelay(ms) 只触发恰好这个时长的期限（例如产品的入口看门狗），不连带别的期限（例如切号处理 15 s 的步骤期限）。
class Clock {
  constructor() { this.jobs = new Map(); this.sequence = 0; this.held = new Set(); this.graceHeld = false; this.graces = 0; this.onGrace = null; }
  /** t4：宽限计时器（见文件头）。 */
  grace(fn) {
    const id = ++this.sequence;
    this.graces++;
    if (this.onGrace) this.onGrace('start');
    const run = () => { if (this.onGrace) this.onGrace('end'); fn(); };
    if (!this.graceHeld) {
      const handle = setImmediate(() => { if (this.jobs.has(id)) { this.jobs.delete(id); run(); } });
      this.jobs.set(id, { fn: run, delay: graceDelay, short: true, handle, grace: true });
      return id;
    }
    this.jobs.set(id, { fn: run, delay: graceDelay, grace: true });
    return id;
  }
  holdGrace() { this.graceHeld = true; }
  /** 让挂着的宽限计时器到期；返回到期的个数。 */
  releaseGrace() {
    const jobs = [...this.jobs].filter(([, job]) => job.grace && !job.short);
    for (const [id] of jobs) this.jobs.delete(id);
    for (const [, job] of jobs) job.fn();
    return jobs.length;
  }
  gracePending() { return [...this.jobs.values()].filter(job => job.grace && !job.short).length; }
  hold(ms) { this.held.add(Number(ms)); }
  expireDelay(ms) {
    const jobs = [...this.jobs].filter(([, job]) => !job.short && !job.grace && Number(job.delay) === Number(ms));
    for (const [id] of jobs) this.jobs.delete(id);
    for (const [, job] of jobs) job.fn();
    return jobs.length;
  }
  pending(ms) { return [...this.jobs.values()].filter(job => !job.short && !job.grace && Number(job.delay) === Number(ms)).length; }
  setTimeout = (fn, delay = 0) => {
    const id = ++this.sequence;
    if (Number(delay) < Clock.SHORT_MS && !this.held.has(Number(delay))) {
      const handle = setImmediate(() => { if (this.jobs.has(id)) { this.jobs.delete(id); fn(); } });
      this.jobs.set(id, { fn, delay, short: true, handle });
      return id;
    }
    this.jobs.set(id, { fn, delay });
    return id;
  };
  clearTimeout = id => {
    const job = this.jobs.get(id);
    if (job && job.handle) clearImmediate(job.handle);
    this.jobs.delete(id);
  };
  expire() {
    const jobs = [...this.jobs].filter(([, job]) => !job.short);
    for (const [id] of jobs) this.jobs.delete(id);
    for (const [, job] of jobs) job.fn();
    return jobs.length;
  }
}
Clock.SHORT_MS = 1000;
/** t4：生产拆后宽限的时长（fixture 从 TrustedAuthSync.COOKIE_GRACE_MS 读来设置；null = 产品还没有，不接管）。 */
let graceDelay = null;
class Ports {
  constructor(journal = new DiskJournal(), profile = null) {
    this.journal = journal;
    this.profile = profile || { cookie: 'old-cookie', local: new Map([['owner', 'user-a']]),
      indexedDB: new Map([['owner', 'user-a']]), cache: 'old-cache' };
    this.clock = clocks.getStore() || new Clock();
    this.signals = new Map();
    this.failures = new Map();
    this.log = [];
    this.globalCacheCalls = 0;
    /** t1（I6）：任何全局 / 含隐私模式的清理调用；每个测试结束时必须为空。 */
    this.globalCalls = [];
    /** t1（I1）：每项清理进入系统接口时调用 hook(kind)。 */
    this.enteredHooks = [];
    // 可读回的响应体；全局删除必须真正删它，不能只增加计数器。
    this.externalCache = new Map([['/cached-resource', Buffer.from('external-cache-response-v3')]]);
    this.deferDocument = false;
    /** t4：Cookie 读回的记录与故障。 */
    this.readbacks = [];
    this.readbackFault = '';
    /** t4：每次 Cookie 清理完成后调用（例如迟到的 Set-Cookie 在清完那一刻落地）。 */
    this.afterCookieClear = null;
  }
  /** t4：迟到响应的 Set-Cookie 此刻落进共用的非无痕 Cookie 库。 */
  lateCookie(value) { this.profile.cookie = this.profile.cookie ? this.profile.cookie + '; ' + value : value; }
  readback(api, incognito) {
    const entry = { api, incognito: incognito === true, clears: this.signal('cookie').completed, value: null };
    this.readbacks.push(entry);
    if (this.mark) this.mark('readback:' + api);
    if (this.readbackFault === 'throw') { entry.value = 'THROW'; throw new Error('injected cookie read-back failure'); }
    entry.value = incognito === true ? this.external.cookie : this.profile.cookie;
    return entry.value;
  }
  signal(kind) {
    if (!this.signals.has(kind)) this.signals.set(kind, { entered: deferred(), gate: null, completed: 0, calls: 0 });
    return this.signals.get(kind);
  }
  hold(kind) { const s = this.signal(kind); s.gate = deferred(); return s; }
  holdCall(kind, nth) {
    const s = this.signal(kind);
    if (!s.gates) s.gates = new Map();
    const entry = { gate: deferred(), entered: deferred() };
    s.gates.set(nth, entry); return entry;
  }
  fault(kind, mode) { this.failures.set(kind, mode); }
  /** 四类可信存储（Cookie / DOM / IndexedDB / 缓存）各自的调用次数之和（t6：缓存一项在 D10-396 之后应恒为 0）。 */
  clearCalls() { return ['cookie', 'local', 'indexedDB', 'cache'].reduce((sum, kind) => sum + this.signal(kind).calls, 0); }
  operation(kind, perform, asynchronous = false) {
    const s = this.signal(kind);
    s.calls++;
    this.log.push(kind + ':entered');
    if (this.mark) this.mark('op:' + kind + ':entered');
    for (const hook of this.enteredHooks) hook(kind);
    s.entered.resolve(true);
    const callGate = s.gates && s.gates.get(s.calls);
    if (callGate) callGate.entered.resolve(true);
    const mode = this.failures.get(kind);
    if (mode === 'throw') throw new Error(kind + ' sync throw');
    if (mode === 'reject') return Promise.reject(new Error(kind + ' Promise rejected'));
    const finish = () => {
      if (mode === 'unconfirmed') return 'unconfirmed';
      const result = perform();
      s.completed++;
      this.log.push(kind + ':completed');
      if (this.mark) this.mark('op:' + kind + ':completed');
      if (this.afterCompletion) this.afterCompletion(kind);
      if (kind === 'cookie' && this.afterCookieClear) this.afterCookieClear(s.completed);
      return result === undefined ? 'true' : result;
    };
    const gate = callGate ? callGate.gate : s.gate;
    if (gate) {
      assert.ok(asynchronous, 'only asynchronous SDK APIs may be suspended');
      return gate.promise.then(finish);
    }
    return asynchronous ? Promise.resolve().then(finish) : finish();
  }
  install(webview, pages, external, trace, mark) {
    this.pages = pages; this.external = external; this.trace = trace; this.mark = mark;
    // SDK：clearAllCookies() 没有 incognito 参数（是否波及隐私模式由设备 E04 取证）；任何实参都记为违规。
    webview.WebCookieManager.clearAllCookies = (...args) => {
      if (args.length > 0) this.globalCalls.push('clearAllCookies(' + args.map(String).join(',') + ')');
      return this.operation('cookie', () => { this.profile.cookie = ''; }, true);
    };
    webview.WebCookieManager.existCookie = (incognito = false) => this.readback('existCookie', incognito) !== '';
    webview.WebCookieManager.fetchCookieSync = (_url, incognito = false) => this.readback('fetchCookieSync', incognito);
    webview.WebCookieManager.fetchCookie = (_url, incognito = false) => {
      try { return Promise.resolve(this.readback('fetchCookie', incognito)); } catch (error) { return Promise.reject(error); }
    };
    webview.WebCookieManager.clearAllCookiesSync = (incognito = false) => {
      if (incognito === true) this.globalCalls.push('clearAllCookiesSync(true)');
      return this.operation('cookie', () => { this.profile.cookie = ''; });
    };
    webview.WebStorage.deleteAllData = (incognito = false) => {
      if (incognito === true) { this.globalCalls.push('deleteAllData(true)'); external.local = ''; }
      // SDK 返回 void：正常返回分别是 DOM/IDB 的同步完成信号；从不触碰 sessionStorage。
      this.operation('local', () => this.profile.local.clear());
      this.operation('indexedDB', () => this.profile.indexedDB.clear());
    };
    webview.WebviewController.removeAllCache = () => {
      this.globalCacheCalls++;
      this.globalCalls.push('removeAllCache');
      this.operation('cache', () => { this.profile.cache = ''; external.cache = ''; this.externalCache.clear(); });
    };
  }
  /**
   * t6（D10-396）：控制器的 removeCache 也是全应用级（SDK 6.1.1：「clear the cache for all webviews in the same application」，t5 设备
   * 取证），效果同 removeAllCache：可信 profile 与外部 incognito 页的缓存一起清掉。调用方（夹具的假控制器）负责记进 globalCalls。
   */
  clearCache() {
    this.operation('cache', () => {
      this.profile.cache = '';
      if (this.external) this.external.cache = '';
      this.externalCache.clear();
    });
  }
  preparePage(p) {
    for (const kind of ['cookie', 'cache']) Object.defineProperty(p, kind,
      { get: () => this.profile[kind], set: value => { this.profile[kind] = value; }, configurable: true });
    p.local = this.profile.local;
    p.indexedDB = this.profile.indexedDB;
  }
  stop(p) { this.log.push(p.name + ':stop'); } // stop() 不停止旧文档 JS、定时器或存储写入。
  /**
   * 旧文档写回（攻击者）：在 p.documents[index] 这份文档里写 Cookie / localStorage / sessionStorage / IndexedDB。文档只在它所在的 Web
   * 实例真正卸下（夹具派发生产 onDisAppear）那一刻销毁；错误页遮罩、stop、令牌轮换、Web 撤出 build 都不算销毁。返回是否写成。
   */
  oldWrite(p, index = 0) {
    const realm = p.documents[index];
    if (!realm || !realm.alive) return false;
    vm.runInContext('document.cookie="old-cookie-rewritten";localStorage.setItem("owner","old-user-rewritten");' +
      'sessionStorage.setItem("owner","old-user-rewritten");indexedDB.put("owner","old-user-rewritten");', realm.context);
    return true;
  }
  cachedExternal() {
    const bytes = this.externalCache.get('/cached-resource');
    assert.ok(bytes, 'only-if-cached: external HTTP response was evicted');
    return bytes.toString('utf8');
  }
}
// ---- t1（R3-04）：生产沙盒文件端口。缺省关闭（同其他 @kit 一样一用就抛）；enable(dir) 后只放行 dir 之下的路径。 ----
const sandbox = { root: null, fault: '' };
function inside(target) {
  const resolved = path.resolve(String(target));
  if (sandbox.root === null || (resolved !== sandbox.root && !resolved.startsWith(sandbox.root + path.sep))) {
    throw new Error('Node fileIo port: path outside the test sandbox: ' + target);
  }
  return resolved;
}
function busy(error) {
  const failure = new Error(error.message);
  failure.code = error.code === 'ENOENT' ? 13900002 : 13900005; // fileIo：没有这个文件或目录 / I/O 错误
  return failure;
}
const nodeFileIo = {
  OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 0o100, TRUNC: 0o1000 },
  statSync(target) { try { return fs.statSync(inside(target)); } catch (error) { throw busy(error); } },
  readTextSync(target) {
    if (sandbox.fault === 'read') throw busy(new Error('injected read failure'));
    try { return fs.readFileSync(inside(target), 'utf8'); } catch (error) { throw busy(error); }
  },
  openSync(target, _mode) {
    if (sandbox.fault === 'write') throw busy(new Error('injected write failure'));
    return { fd: fs.openSync(inside(target), 'w') };
  },
  writeSync(fd, value) { return fs.writeSync(fd, String(value)); },
  fsyncSync(fd) { fs.fsyncSync(fd); },
  closeSync(file) { fs.closeSync(typeof file === 'number' ? file : file.fd); },
  renameSync(from, to) { fs.renameSync(inside(from), inside(to)); },
  unlinkSync(target) { fs.unlinkSync(inside(target)); }
};
const sandboxFileIo = new Proxy({}, { get(_target, member) {
  if (sandbox.root === null) throw new Error('Node fallback cannot use platform API: @kit.CoreFileKit.' + String(member));
  return nodeFileIo[member];
} });
function enableSandbox(directory) { sandbox.root = path.resolve(directory); sandbox.fault = ''; }
function disableSandbox() { sandbox.root = null; sandbox.fault = ''; }
module.exports = { Ports, DiskJournal, DiskOwnerRecord, Clock, deferred, turn, sandbox, sandboxFileIo, enableSandbox, disableSandbox,
  withClock: run => clocks.run(new Clock(), run),
  // 只有 core 的 TrustedAuthSync 经这里设计时器（fx25-auth-change-test.js 的 clockPort）。t4：恰好是宽限时长的那个交给 grace 模型。
  setTimeout: (fn, delay, ...rest) => {
    const clock = clocks.getStore();
    if (graceDelay !== null && Number(delay) === graceDelay) {
      if (clock) return clock.grace(fn);
      return { fx25Grace: setImmediate(fn) };
    }
    return clock ? clock.setTimeout(fn, delay, ...rest) : setTimeout(fn, delay, ...rest);
  },
  clearTimeout: id => {
    if (id && id.fx25Grace) { clearImmediate(id.fx25Grace); return; }
    return clocks.getStore() ? clocks.getStore().clearTimeout(id) : clearTimeout(id);
  },
  setGraceDelay: ms => { graceDelay = ms === null ? null : Number(ms); },
  graceDelay: () => graceDelay
};
