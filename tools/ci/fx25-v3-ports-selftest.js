#!/usr/bin/env node
// F-X-25 系统端口自测（t1：sessionStorage 改由夹具按 Web 实例保存，这里不再有 session 端口）。
'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { Ports, DiskJournal, turn, sandboxFileIo, enableSandbox, disableSandbox } = require('./fx25-v3-ports');
async function run() {
  const ports = new Ports();
  try {
    const p = { name: 'fixture', documents: [] };
    ports.preparePage(p);
    const web = { WebviewController: class {}, WebStorage: {}, WebCookieManager: {} };
    const external = { cookie: 'external-cookie', local: 'external-local', cache: 'external-cache' };
    const marks = [];
    ports.install(web, [p], external, [], entry => marks.push(entry));
    const entered = [];
    ports.enteredHooks.push(kind => entered.push(kind));
    web.WebStorage.deleteAllData(false);
    assert.strictEqual(p.cookie, 'old-cookie'); assert.strictEqual(p.cache, 'old-cache');
    assert.strictEqual(ports.signal('local').completed, 1); assert.strictEqual(ports.signal('indexedDB').completed, 1);
    assert.deepStrictEqual(entered, ['local', 'indexedDB']);
    assert.ok(marks.includes('op:local:entered') && marks.includes('op:indexedDB:completed'));
    assert.deepStrictEqual(ports.globalCalls, []);
    console.log('PASS WebStorage never clears Cookie/cache; DOM and IDB record separate completion and entry hooks');
    const cookies = ports.hold('cookie');
    const deletingCookie = web.WebCookieManager.clearAllCookies();
    await cookies.entered.promise;
    assert.strictEqual(cookies.completed, 0); assert.strictEqual(p.cookie, 'old-cookie');
    cookies.gate.resolve(); await deletingCookie;
    assert.strictEqual(p.cookie, ''); assert.strictEqual(cookies.completed, 1);
    cookies.gate = null;
    console.log('PASS asynchronous cookie gate holds completion until released');
    p.local.set('owner', 'x'); p.indexedDB.set('owner', 'x');
    ports.fault('indexedDB', 'throw');
    assert.throws(() => web.WebStorage.deleteAllData(false), /indexedDB/);
    assert.strictEqual(p.local.size, 0); assert.strictEqual(p.indexedDB.get('owner'), 'x');
    ports.failures.delete('indexedDB');
    console.log('PASS IDB failure does not become a DOM failure or success');
    assert.strictEqual(ports.cachedExternal(), 'external-cache-response-v3');
    web.WebviewController.removeAllCache(true);
    assert.throws(() => ports.cachedExternal(), /evicted/);
    web.WebStorage.deleteAllData(true); web.WebCookieManager.clearAllCookiesSync(true); web.WebCookieManager.clearAllCookies(true);
    assert.deepStrictEqual(ports.globalCalls, ['removeAllCache', 'deleteAllData(true)', 'clearAllCookiesSync(true)', 'clearAllCookies(true)']);
    console.log('PASS global cache deletion actually evicts external bytes; every global / incognito clear is recorded');
    const context = vm.createContext({ document: {}, localStorage: { setItem: (k, v) => p.local.set(k, v) },
      sessionStorage: { setItem() {} }, indexedDB: { put: (k, v) => p.indexedDB.set(k, v) } });
    Object.defineProperty(context.document, 'cookie', { set: value => { p.cookie = value; } });
    p.documents.push({ alive: true, context });
    assert.strictEqual(ports.oldWrite(p), true);
    assert.deepStrictEqual([p.cookie, p.local.get('owner'), p.indexedDB.get('owner')],
      ['old-cookie-rewritten', 'old-user-rewritten', 'old-user-rewritten']);
    p.documents[0].alive = false;
    assert.strictEqual(ports.oldWrite(p), false);
    console.log('PASS old-document write-back reaches Cookie/local/IDB while alive, never after destruction');
    ports.journal.markPending('user-a');
    const reboot = new DiskJournal(ports.journal.directory);
    assert.strictEqual(reboot.readPending(), 'user-a');
    reboot.clearPending(); assert.strictEqual(ports.journal.readPending(), null);
    console.log('PASS fresh journal instance sees disk marker and completed removal');
    let fired = false, polled = false;
    ports.clock.setTimeout(() => { fired = true; }, 9000);
    ports.clock.setTimeout(() => { polled = true; }, 16);
    await turn(); await turn();
    assert.strictEqual(fired, false); assert.strictEqual(polled, true, 'short production timers (polling) run by themselves');
    assert.strictEqual(ports.clock.expire(), 1); assert.strictEqual(fired, true);
    console.log('PASS deterministic deadline without wall-clock sleep; short timers self-run');
    assert.throws(() => sandboxFileIo.statSync('/tmp/x'), /platform API/);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fx25-sandbox-'));
    try {
      enableSandbox(dir);
      const file = path.join(dir, 'slot');
      assert.throws(() => sandboxFileIo.statSync(file), error => error.code === 13900002);
      const handle = sandboxFileIo.openSync(file + '.tmp', 0);
      sandboxFileIo.writeSync(handle.fd, 'v'); sandboxFileIo.fsyncSync(handle.fd); sandboxFileIo.closeSync(handle);
      sandboxFileIo.renameSync(file + '.tmp', file);
      assert.strictEqual(sandboxFileIo.readTextSync(file), 'v');
      assert.throws(() => sandboxFileIo.readTextSync('/etc/hosts'), /outside the test sandbox/);
    } finally { disableSandbox(); fs.rmSync(dir, { recursive: true, force: true }); }
    console.log('PASS fileIo port: disabled by default, sandbox-only, ENOENT = 13900002');
  } finally { ports.journal.dispose(); }
}
run().catch(error => { console.error(error.stack); process.exitCode = 1; });
