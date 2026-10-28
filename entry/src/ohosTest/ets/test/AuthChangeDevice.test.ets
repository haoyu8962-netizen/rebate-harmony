import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { ApiResult } from 'core';
import { webview } from '@kit.ArkWeb';
import { Fx25ExternalCacheRig } from './Fx25ExternalCacheRig';
import { Fx25DeviceRig, Fx25Tick } from './Fx25DeviceRig';
import { Fx25Controllers } from './Fx25Controllers';
import { Fx25CookieRig, FX25_E04_EXTERNAL, FX25_E04_TRUSTED } from './Fx25CookieRig';
import { Fx25OwnerRig, FX25_E05_COOKIE, FX25_E05_URL } from './Fx25OwnerRig';
import { Fx25CoverRig, FX25_E06_COVER, FX25_E06_HOST } from './Fx25CoverRig';
import { Fx25Scene } from './Fx25Scene';
import { Fx25CacheRig, Fx25SpyController, FX25_E02_EXTERNAL_MARK, FX25_E02_TRUSTED_MARK } from './Fx25CacheRig';
import { Fx25BeaconRig, Fx25LateRequest, Fx25SeenCookie, FX25_E07_PRE_DELAYS } from './Fx25BeaconRig';

/**
 * 等 signal，最多 ms 毫秒；到期按 fallback。t2：设备上文档正在切换时 runJavaScript 的 Promise 可能永远不兑现，原先的轮询会卡在
 * 一次检查里，用例一直挂到 Hypium 的 600 s 单例上限（E05 实测）。只给单次等待加上限，判定不变。
 */
function bounded<T>(signal: Promise<T>, ms: number, fallback: T): Promise<T> {
  return new Promise<T>((resolve: (value: T) => void, reject: (reason: Object) => void): void => {
    const timer: number = setTimeout((): void => resolve(fallback), Math.max(ms, 0));
    signal.then((value: T): void => {
      clearTimeout(timer);
      resolve(value);
    }, (reason: Object): void => {
      clearTimeout(timer);
      reject(reason);
    });
  });
}

// 轮询真实状态，有上限且调用方必须断言结果；不以固定等待代替成功信号。单次检查同样受这个上限约束。
async function until(check: () => Promise<boolean>): Promise<boolean> {
  const deadline: number = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (await bounded(check(), deadline - Date.now(), false)) {
      return true;
    }
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 20); });
  }
  return false;
}

/**
 * t5：同 until（同一判定），另把判定时刻的状态写进 hilog（FX25T5 <label>），没等到时也写——只取证，不改判定。nr1 那次 E02 红在
 * 第 191 行（外部页仍命中），被当成第 188 行（可信页 MISS）读错了；以后红了直接看 hilog 里读到的是什么。
 */
async function untilLogged(label: string, check: () => Promise<boolean>, state: () => Promise<string>): Promise<boolean> {
  const ok: boolean = await until(check);
  let seen: string = '';
  try {
    seen = await bounded(state(), 5000, 'state timeout');
  } catch (e) {
    seen = 'state failed: ' + JSON.stringify(e);
  }
  console.info('FX25T5 ' + label + ' ok=' + ok + ' ' + seen);
  return ok;
}

/** 在 controller 当前文档里求一个布尔表达式；控制器没挂上 / 文档换了 / 5 s 内没有结果时为 false。 */
async function holds(controller: () => webview.WebviewController, expression: string): Promise<boolean> {
  try {
    return await bounded(controller().runJavaScript('(' + expression + ')===true'), 5000, 'timeout') === 'true';
  } catch (e) {
    return false;
  }
}

/** 固定等待：只给「已答完的迟到响应」留落盘余量，不代替任何成功信号（之前都有有上限的状态轮询）。 */
function pause(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); });
}

async function startFx25(): Promise<void> {
  await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
    bundleName: 'com.couli.hm', abilityName: 'Fx25TestAbility'
  });
}

// t1：localStorage / sessionStorage / Cookie 三类同步写入并读回；IndexedDB 异步写入，完成后 window.fx25IdbSeeded = "ok"。
const SEED: string = 'localStorage.setItem("fx25_owner","user-a");sessionStorage.setItem("fx25_owner","user-a");' +
  'document.cookie="fx25_owner=user-a; Path=/; SameSite=Lax; Secure";' +
  '(localStorage.getItem("fx25_owner")==="user-a"&&sessionStorage.getItem("fx25_owner")==="user-a"&&' +
  'document.cookie.indexOf("fx25_owner=user-a")>=0)';
const IDB_SEED: string = 'window.fx25IdbSeeded="PENDING";(function(){var r=indexedDB.open("fx25db",1);' +
  'r.onupgradeneeded=function(){r.result.createObjectStore("kv");};r.onerror=function(){window.fx25IdbSeeded="open-error";};' +
  'r.onsuccess=function(){try{var t=r.result.transaction("kv","readwrite");t.objectStore("kv").put("user-a","fx25_owner");' +
  't.oncomplete=function(){window.fx25IdbSeeded="ok";};t.onerror=function(){window.fx25IdbSeeded="put-error";};}' +
  'catch(e){window.fx25IdbSeeded="throw";}};})();';
// 旧文档的写回攻击：pagehide / unload / 每 20 ms 一次，四类都写 A 的值；每写一次都同步回执 /fx25-tick（文档号 + 页面时钟）。
const ATTACK: string = '(function(){var d=window.fx25Document;function w(tag){try{localStorage.setItem("fx25_late",tag);' +
  'sessionStorage.setItem("fx25_late",tag);document.cookie="fx25_late="+tag+"; Path=/; SameSite=Lax; Secure";' +
  'var r=indexedDB.open("fx25db",1);r.onupgradeneeded=function(){r.result.createObjectStore("kv");};' +
  'r.onsuccess=function(){try{r.result.transaction("kv","readwrite").objectStore("kv").put(tag,"fx25_late");}catch(e){}};}catch(e){}' +
  'try{var x=new XMLHttpRequest();x.open("GET","/fx25-tick?doc="+d+"&at="+Date.now()+"&tag="+tag,false);x.send();}catch(e){}}' +
  'window.addEventListener("pagehide",function(){w("pagehide-user-a");});window.addEventListener("unload",function(){w("unload-user-a");});' +
  'setInterval(function(){w("tick-user-a");},20);return true;})()';
// 新文档：四类 + sessionStorage 全空（IndexedDB 异步核对，结果在 window.fx25Clean）。
const CLEAN_CHECK: string = 'window.fx25Clean="PENDING";(function(){var ok=localStorage.getItem("fx25_owner")===null&&' +
  'localStorage.getItem("fx25_late")===null&&sessionStorage.getItem("fx25_owner")===null&&sessionStorage.getItem("fx25_late")===null&&' +
  'sessionStorage.length===0&&document.cookie.indexOf("fx25_owner=")<0&&document.cookie.indexOf("fx25_late=")<0;' +
  'var r=indexedDB.open("fx25db",1);r.onupgradeneeded=function(){r.result.createObjectStore("kv");};' +
  'r.onerror=function(){window.fx25Clean="idb-open-error";};r.onsuccess=function(){try{var g=r.result.transaction("kv","readonly")' +
  '.objectStore("kv").getAll();g.onsuccess=function(){window.fx25Clean=ok&&g.result.length===0?"clean":"dirty";};' +
  'g.onerror=function(){window.fx25Clean="idb-read-error";};}catch(e){window.fx25Clean="idb-throw";}};})();';

export default function authChangeDeviceTest() {
  describe('AuthChangeDevice_FX25', () => {
    // t1 改写（D10-279 c 合并门槛）：新 Web 实例不继承旧 sessionStorage；旧 Web 卸下（旧控制器报 17100001）之后旧文档不再写任何东西；
    // 换的是新控制器；IndexedDB 也清了；旧文档收到 A 恰好一次。
    // t5（D10-391 ②）：A 的回执改为不走网络（旧文档写 document.title，测试在旧控制器解绑前每 2 ms 读一次 getTitle），「恰好一次、
    // data 只有 logged_in=true」三条断言一字不动。原同步 XHR 回执留作纵深探针（加严）：它发在隔离中，必须一条都到不了 handler，
    // 且产品确实拦过（诊断 auth_isolated_request）。
    it('E01_real_trusted_storage_is_gone_after_account_switch_and_old_document_received_event', 0, async () => {
      const rig: Fx25DeviceRig = Fx25DeviceRig.shared;
      Fx25ExternalCacheRig.shared.externalOnly = false;
      Fx25Scene.shared.mode = Fx25Scene.TRUSTED;
      await startFx25();
      const attached: boolean = await until((): Promise<boolean> => Promise.resolve(rig.tryAttach()));
      expect(attached).assertTrue();
      expect(await until((): Promise<boolean> => holds((): webview.WebviewController => rig.controller, 'window.fx25Ready'))).assertTrue();
      const old: webview.WebviewController = rig.controller;
      const before: number = Number(await old.runJavaScript('window.fx25Document'));
      expect(await old.runJavaScript(SEED)).assertEqual('true');
      await old.runJavaScript(IDB_SEED);
      expect(await until((): Promise<boolean> => holds((): webview.WebviewController => old, 'window.fx25IdbSeeded==="ok"'))).assertTrue();
      expect(await old.runJavaScript(ATTACK)).assertEqual('true');
      // 非空跑：攻击确实在旧文档里跑起来了。
      expect(await until((): Promise<boolean> => Promise.resolve(rig.ticks.some((t: Fx25Tick): boolean => t.doc === before)))).assertTrue();
      let gone: number = 0;
      const poll: number = setInterval((): void => {
        if (gone === 0 && Fx25Controllers.detached(old)) {
          gone = Date.now();
        }
      }, 10);
      const titles: number = setInterval((): void => {
        if (gone === 0) {
          rig.observeTitle(old);
        }
      }, 2);
      const result: ApiResult = await rig.switchAccount();
      expect(result.code).assertEqual(0);
      expect(rig.network.tokens.account()).assertEqual('user-b');
      const settled: boolean = await rig.config.whenAuthSettled();
      expect(settled).assertTrue();
      const newDocument: boolean = await until(async (): Promise<boolean> => {
        if (rig.controllers.current === old) return false;
        try {
          const marker: string = await rig.controller.runJavaScript('window.fx25Ready===true?window.fx25Document:0');
          return Number(marker) > before;
        } catch (e) { return false; }
      });
      expect(newDocument).assertTrue();
      expect(await until((): Promise<boolean> => Promise.resolve(gone > 0))).assertTrue();
      clearInterval(poll);
      clearInterval(titles);
      // 新控制器（产品经 controllerFactory 新建），旧控制器已解绑。
      expect(rig.controller === old).assertFalse();
      expect(rig.controllers.made.indexOf(rig.controller) >= 0).assertTrue();
      expect(Fx25Controllers.detached(old)).assertTrue();
      await rig.controller.runJavaScript(CLEAN_CHECK);
      expect(await until((): Promise<boolean> => holds((): webview.WebviewController => rig.controller, 'window.fx25Clean!=="PENDING"'))).assertTrue();
      expect(await holds((): webview.WebviewController => rig.controller, 'window.fx25Clean==="clean"')).assertTrue();
      // 卸下即停写：旧控制器报 17100001 之后，旧文档没有任何一次写回（页面时钟晚于解绑时刻的回执一条都不能有）。
      const late: number = rig.ticks.filter((t: Fx25Tick): boolean => t.doc === before && t.at > gone).length;
      expect(late).assertEqual(0);
      console.info('FX25T5 e01 received=' + JSON.stringify(rig.received) + ' eventRequests=' + rig.eventRequests.length +
        ' diagnostics=' + JSON.stringify(rig.diagnostics) + ' gone=' + gone);
      expect(rig.received.length).assertEqual(1);
      const payload: Record<string, Object> = JSON.parse(rig.received[0]) as Record<string, Object>;
      expect(Object.keys(payload).length).assertEqual(1);
      expect(payload['logged_in']).assertEqual(true);
      // t5 加严（D10-391 ① 纵深）：旧文档收到 A 时（隔离中）发的普通同步 XHR 一条都没到 handler，产品确实拦过。
      expect(rig.eventRequests.length).assertEqual(0);
      expect(rig.diagnostics.indexOf('auth_isolated_request') >= 0).assertTrue();
    });
    // t4 改写（评审新 r1 NR1-02）：原写法场景里没有可信页，新方案下产品一项都不清（延期），断言对任何缓存实现都成立（空跑）。
    // 现在可信页与隐私外部页同屏：产品真的走「拆 → 载体 → 实例 removeCache(true)」。正向证据：可信页清理前读两次都由缓存供给的
    // 资源，清理后的新文档里读到 MISS；同屏外部 incognito 页的缓存仍命中、外部页没被重载；settled 同时核对待清标记已删（完成，
    // 不是延期）。阳性对照：全局 removeAllCache(true) 之后外部页 MISS。用例名不变（DS-02 登记表）。
    // t5（D10-391 ②「E02 改读法」）：查明 readIs 没有问题——nr1 的 E02 红在第 191 行（清理后外部页不再命中），不是第 188 行
    // （可信页 MISS 已经读到、断言已过）；实现者诊断时在第 188 行前插了 2 行，把栈里的行号对错了。判定一字不动，只把判定时刻
    // 读到的值写进 hilog（untilLogged）。
    // t6（D10-396 ②，新鲜独立 Claude）：产品不再在切号时清 HTTP 缓存（removeCache 是全应用级，t5 证实它清掉了外部 incognito 缓存）。
    // 改断言：(1) 切号全程产品没有在任何可信控制器上调用 removeCache（Fx25SpyController 记录；静态 removeAllCache 不可挂钩，由 Node V43
    // 的源码 AST 守，且它的效果会被 (2) 读出）；(2) 同屏外部 incognito 页缓存仍命中、外部页没被重载；(3) 正向对照：同一读法切号前
    // 未清时读到 HIT（两次）、显式全局清缓存后读到 MISS——证明读法能区分命中 / 未命中。作废「可信页清理后读到 MISS」（空跑，见交回
    // t5 / t6），改为只写 hilog 取证。用例名不变（DS-02 登记表）。
    it('E02_I6_only_external_real_arkweb_http_cache_survives_auth_cleanup', 0, async () => {
      const rig: Fx25CacheRig = Fx25CacheRig.shared;
      Fx25ExternalCacheRig.shared.externalOnly = false;
      Fx25Scene.shared.mode = Fx25Scene.CACHE;
      await startFx25();
      expect(await until((): Promise<boolean> => Promise.resolve(rig.tryAttach()))).assertTrue();
      const trusted: () => webview.WebviewController = (): webview.WebviewController => rig.controllers.controller();
      const external: () => webview.WebviewController = (): webview.WebviewController => rig.externalController;
      expect(await until((): Promise<boolean> => holds(trusted, 'window.fx25Ready'))).assertTrue();
      expect(await until((): Promise<boolean> => holds(external, 'window.fx25ExtReady'))).assertTrue();
      const old: webview.WebviewController = trusted();
      const before: number = Number(await old.runJavaScript('window.fx25Document'));
      // 布置：两边各种一份缓存；第二次读仍是标记值 = 由缓存供给（handler 之后只回 MISS）。
      rig.trusted.seed();
      rig.outside.seed();
      for (let i = 0; i < 2; i++) {
        await rig.trusted.startRead(old);
        expect(await until((): Promise<boolean> => rig.trusted.readIs(old, FX25_E02_TRUSTED_MARK))).assertTrue();
        await rig.outside.startRead(external());
        expect(await until((): Promise<boolean> => rig.outside.readIs(external(), FX25_E02_EXTERNAL_MARK))).assertTrue();
      }
      const externalLoads: number = rig.outside.pageLoads;
      // t6：前提——可信页确实挂在受监视的控制器上（否则「没调用」是空跑）。
      expect(rig.spies.indexOf(old as Fx25SpyController) >= 0).assertTrue();
      const spiesBefore: number = rig.spies.length;
      // 生产路径：登出 → 拆 → 载体 → 清 → 新文档。
      expect(rig.network.client.clearSessionIfEpoch(rig.network.client.loginEpoch())).assertTrue();
      expect(await rig.config.whenAuthSettled()).assertTrue();
      // 是「完成」不是「延期」：待清标记已删。
      expect(rig.journal.readPending()).assertNull();
      expect(await until(async (): Promise<boolean> => {
        if (rig.controllers.current === old) return false;
        try {
          return Number(await trusted().runJavaScript('window.fx25Ready===true?window.fx25Document:0')) > before;
        } catch (e) { return false; }
      })).assertTrue();
      expect(Fx25Controllers.detached(old)).assertTrue();
      expect(rig.config.isAuthIsolated()).assertFalse();
      // t6（D10-396）：切号流程没有调用任何缓存清理；清理载体也经受监视的控制器（非空跑：切号确实新造了控制器）。
      expect(rig.spies.length > spiesBefore).assertTrue();
      expect(rig.spies.indexOf(trusted() as Fx25SpyController) >= 0).assertTrue();
      console.info('FX25T6 e02 spies=' + rig.spies.length + ' removeCache=' + rig.cacheClearCalls());
      expect(rig.cacheClearCalls()).assertEqual(0);
      // t6 作废原正向断言（可信新文档读到 MISS）：只取证，不判定。
      await rig.trusted.startRead(trusted());
      await untilLogged('e02 trusted-after (evidence only)', (): Promise<boolean> => rig.trusted.readIs(trusted(), 'MISS'),
        (): Promise<string> => rig.trusted.describe(trusted()));
      // I6：外部 incognito 页的缓存仍命中，外部页没被重载。
      await rig.outside.startRead(external());
      expect(await untilLogged('e02 external-after', (): Promise<boolean> => rig.outside.readIs(external(), FX25_E02_EXTERNAL_MARK),
        (): Promise<string> => rig.outside.describe(external()))).assertTrue();
      expect(rig.outside.pageLoads).assertEqual(externalLoads);
      // 阳性对照：全局清理确实会驱逐外部这份缓存，否则读法不成立，必须红（与切号前的两次 HIT 一起：同一读法能区分命中 / 未命中）。
      expect(rig.cacheClearCalls()).assertEqual(0);
      webview.WebviewController.removeAllCache(true);
      await rig.outside.startRead(external());
      expect(await untilLogged('e02 external-positive', (): Promise<boolean> => rig.outside.readIs(external(), 'MISS'),
        (): Promise<string> => rig.outside.describe(external()))).assertTrue();
    });
    // t1 新增（D10-279 c 合并门槛）：产品清 Cookie 用的是没有参数的 clearAllCookies()，它不得波及 ExternalWebView 的 incognito Cookie。
    it('E04_I6_no_arg_cookie_clear_keeps_incognito_external_cookie', 0, async () => {
      const rig: Fx25CookieRig = Fx25CookieRig.shared;
      Fx25ExternalCacheRig.shared.externalOnly = false;
      Fx25Scene.shared.mode = Fx25Scene.BOTH;
      await startFx25();
      expect(await until((): Promise<boolean> => Promise.resolve(rig.tryAttach()))).assertTrue();
      const trusted: () => webview.WebviewController = (): webview.WebviewController => rig.controllers.controller();
      const external: () => webview.WebviewController = (): webview.WebviewController => rig.externalController;
      expect(await until((): Promise<boolean> => holds(trusted, 'window.fx25Ready'))).assertTrue();
      expect(await until((): Promise<boolean> => holds(external, 'window.fx25ExtReady'))).assertTrue();
      const old: webview.WebviewController = trusted();
      const before: number = Number(await old.runJavaScript('window.fx25Document'));
      expect(await holds(external, 'document.cookie="fx25_ext=keep; Path=/; SameSite=Lax; Secure",document.cookie.indexOf("fx25_ext=keep")>=0'))
        .assertTrue();
      expect(await holds(trusted, 'document.cookie="fx25_trusted=user-a; Path=/; SameSite=Lax; Secure",document.cookie.indexOf("fx25_trusted=user-a")>=0'))
        .assertTrue();
      // 读回方法成立（阳性）：隐私模式那一份读得到外部 Cookie，普通那一份读得到可信 Cookie，且互不串。
      expect(Fx25CookieRig.cookies(FX25_E04_EXTERNAL, true).indexOf('fx25_ext=keep') >= 0).assertTrue();
      expect(Fx25CookieRig.cookies(FX25_E04_TRUSTED, false).indexOf('fx25_trusted=user-a') >= 0).assertTrue();
      expect(Fx25CookieRig.cookies(FX25_E04_EXTERNAL, false).indexOf('fx25_ext=keep') < 0).assertTrue();
      // (a) 生产路径：登出 → 产品拆、清、建。可信 Cookie 没了，隐私模式的外部 Cookie 还在，外部页也没被重载。
      expect(rig.network.client.clearSessionIfEpoch(rig.network.client.loginEpoch())).assertTrue();
      expect(await rig.config.whenAuthSettled()).assertTrue();
      expect(await until(async (): Promise<boolean> => {
        if (rig.controllers.current === old) return false;
        try {
          return Number(await trusted().runJavaScript('window.fx25Ready===true?window.fx25Document:0')) > before;
        } catch (e) { return false; }
      })).assertTrue();
      expect(Fx25CookieRig.cookies(FX25_E04_TRUSTED, false).indexOf('fx25_trusted=') < 0).assertTrue();
      expect(await holds(trusted, 'document.cookie.indexOf("fx25_trusted=")<0')).assertTrue();
      expect(Fx25CookieRig.cookies(FX25_E04_EXTERNAL, true).indexOf('fx25_ext=keep') >= 0).assertTrue();
      expect(await holds(external, 'window.fx25ExtReady&&document.cookie.indexOf("fx25_ext=keep")>=0')).assertTrue();
      // (b) 直接取证 SDK 本身：无参 clearAllCookies() 清掉普通 Cookie（阳性），不清隐私模式 Cookie（门槛判定）。
      webview.WebCookieManager.configCookieSync(FX25_E04_TRUSTED, 'fx25_direct=1; Path=/; Secure', false);
      expect(Fx25CookieRig.cookies(FX25_E04_TRUSTED, false).indexOf('fx25_direct=1') >= 0).assertTrue();
      await webview.WebCookieManager.clearAllCookies();
      expect(Fx25CookieRig.cookies(FX25_E04_TRUSTED, false).indexOf('fx25_direct=1') < 0).assertTrue();
      expect(Fx25CookieRig.cookies(FX25_E04_EXTERNAL, true).indexOf('fx25_ext=keep') >= 0).assertTrue();
      // (c) 阳性对照：隐私模式的全局清理确实能清掉它——读不到就说明读回方法不成立，必须红。
      webview.WebCookieManager.clearAllCookiesSync(true);
      expect(Fx25CookieRig.cookies(FX25_E04_EXTERNAL, true).indexOf('fx25_ext=keep') < 0).assertTrue();
    });
    // t1 新增（R3-04）：生产沙盒文件（FileTrustedAuthJournal + FileTrustedWebOwnerRecord）下冷启动，归属记录是 A、会话是 B、没有标记：
    // 第一个可信页的任何一次入口请求都不得带着 A 的 Cookie；清完后归属记录改写为 B，标记删掉。
    it('E05_R3_04_production_sandbox_owner_mismatch_cleans_before_first_trusted_load', 0, async () => {
      const rig: Fx25OwnerRig = Fx25OwnerRig.shared;
      await startFx25();
      expect(await until((): Promise<boolean> => Promise.resolve(rig.initialized()))).assertTrue();
      webview.WebCookieManager.configCookieSync(FX25_E05_URL, FX25_E05_COOKIE + '; Path=/; Secure', false);
      expect(Fx25CookieRig.cookies(FX25_E05_URL, false).indexOf(FX25_E05_COOKIE) >= 0).assertTrue();
      // 前置条件（上一个进程留下的盘面）在冷启动之前核对：没有标记、归属 A。
      rig.seed();
      expect(rig.journal.readPending()).assertNull();
      expect(rig.record.readOwner()).assertEqual('account:user-a');
      // 冷启动：归属 A ≠ 会话 B → 第一个可信页出现之前补清事务已持久登记在盘上（I3）。
      rig.prepare();
      expect(rig.journal.readPending() !== null).assertTrue();
      Fx25ExternalCacheRig.shared.externalOnly = false;
      Fx25Scene.shared.mode = Fx25Scene.OWNER;
      expect(await until((): Promise<boolean> =>
        holds((): webview.WebviewController => rig.controllers.controller(), 'window.fx25Ready'))).assertTrue();
      expect(await rig.config.whenAuthSettled()).assertTrue();
      expect(rig.requestCookies.length > 0).assertTrue();
      for (const cookie of rig.requestCookies) {
        expect(cookie.indexOf('fx25_e05=') < 0).assertTrue();
      }
      expect(await holds((): webview.WebviewController => rig.controllers.controller(), 'window.fx25Cookie.indexOf("fx25_e05=")<0'))
        .assertTrue();
      expect(Fx25CookieRig.cookies(FX25_E05_URL, false).indexOf('fx25_e05=') < 0).assertTrue();
      expect(rig.record.readOwner()).assertEqual('account:user-b');
      expect(rig.journal.readPending()).assertNull();
      expect(rig.config.isAuthIsolated()).assertFalse();
      // t4（评审新 r1 NR1-06）阳性对照：同一读法（scheme handler 的 Cookie 请求头）在没清的时候读得到 A 的 Cookie——否则上面的
      // 「入口请求不带 A 的 Cookie」是空跑。清理已结束，这里重新种回 A 的 Cookie，由测试自己再加载一次入口。
      webview.WebCookieManager.configCookieSync(FX25_E05_URL, FX25_E05_COOKIE + '; Path=/; Secure', false);
      expect(Fx25CookieRig.cookies(FX25_E05_URL, false).indexOf(FX25_E05_COOKIE) >= 0).assertTrue();
      const seen: number = rig.requestCookies.length;
      rig.controllers.controller().loadUrl(FX25_E05_URL);
      expect(await until((): Promise<boolean> => Promise.resolve(rig.requestCookies.length > seen))).assertTrue();
      expect(rig.requestCookies[seen].indexOf(FX25_E05_COOKIE) >= 0).assertTrue();
      expect(await until((): Promise<boolean> =>
        holds((): webview.WebviewController => rig.controllers.controller(), 'window.fx25Cookie.indexOf("fx25_e05=user-a")>=0'))).assertTrue();
      // 收尾：不把 A 的 Cookie 留给后面的用例。
      webview.WebCookieManager.configCookieSync(FX25_E05_URL, 'fx25_e05=; Path=/; Secure; Max-Age=0', false);
    });
    // t1 新增：宿主 NavDestination 被另一个 NavDestination 压着时切号。压着期间旧 Web 就下树（旧控制器解绑）；弹出后看到的是干净的
    // 新文档（新控制器）。
    it('E06_covered_host_tears_down_while_covered_and_shows_clean_new_document_after_pop', 0, async () => {
      const rig: Fx25CoverRig = Fx25CoverRig.shared;
      Fx25ExternalCacheRig.shared.externalOnly = false;
      await startFx25();
      Fx25Scene.shared.mode = Fx25Scene.COVERED;
      rig.stack.pushPathByName(FX25_E06_HOST, null, false);
      expect(await until((): Promise<boolean> => Promise.resolve(rig.tryAttach()))).assertTrue();
      const current: () => webview.WebviewController = (): webview.WebviewController => rig.controllers.controller();
      expect(await until((): Promise<boolean> => holds(current, 'window.fx25Ready'))).assertTrue();
      const old: webview.WebviewController = current();
      const before: number = Number(await old.runJavaScript('window.fx25Document'));
      expect(await old.runJavaScript(SEED)).assertEqual('true');
      rig.stack.pushPathByName(FX25_E06_COVER, null, false);
      expect(await until((): Promise<boolean> => Promise.resolve(rig.hidden > 0))).assertTrue();
      const result: ApiResult = await rig.switchAccount();
      expect(result.code).assertEqual(0);
      expect(await until((): Promise<boolean> => Promise.resolve(Fx25Controllers.detached(old)))).assertTrue();
      expect(rig.stack.size()).assertEqual(2);
      expect(rig.config.isAuthIsolated()).assertTrue();
      rig.stack.pop(false);
      expect(await until((): Promise<boolean> => Promise.resolve(rig.shown >= 2))).assertTrue();
      expect(await rig.config.whenAuthSettled()).assertTrue();
      expect(await until(async (): Promise<boolean> => {
        if (rig.controllers.current === old) return false;
        try {
          return Number(await current().runJavaScript('window.fx25Ready===true?window.fx25Document:0')) > before;
        } catch (e) { return false; }
      })).assertTrue();
      const clean: boolean = await holds(current, 'localStorage.getItem("fx25_owner")===null&&sessionStorage.getItem("fx25_owner")===null&&' +
        'sessionStorage.length===0&&document.cookie.indexOf("fx25_owner=")<0');
      // t5：只取证（nr1 诊断里这条偶发红过一次）：判定时刻的文档、各项存储与容器状态写进 hilog，判定不变。
      let state: string = '';
      try {
        state = await bounded(current().runJavaScript('JSON.stringify({doc:window.fx25Document,ready:window.fx25Ready,' +
          'ls:localStorage.getItem("fx25_owner"),ss:sessionStorage.getItem("fx25_owner"),ssLen:sessionStorage.length,' +
          'cookie:document.cookie,url:location.href})'), 5000, 'timeout');
      } catch (e) {
        state = 'runJavaScript failed: ' + JSON.stringify(e);
      }
      console.info('FX25T5 e06 clean=' + clean + ' page=' + state + ' documents=' + rig.documents + ' made=' +
        rig.controllers.made.length + ' reported=' + rig.controllers.reported.length + ' isolated=' + rig.config.isAuthIsolated() +
        ' shown=' + rig.shown + ' hidden=' + rig.hidden);
      expect(clean).assertTrue();
      expect(rig.controllers.made.indexOf(current()) >= 0).assertTrue();
      expect(rig.config.isAuthIsolated()).assertFalse();
    });
    // t4 新增（评审新 r1 NR1-01，合并门槛，D10-385）：旧文档的 sendBeacon / fetch(keepalive) 带回的迟到 Set-Cookie 不得进新账号。
    // 可信页由本机回环 HTTP 服务应答（Fx25BeaconRig；scheme handler 跟着控制器失效，量不到网络服务里跑完的 keepalive）。
    // - 隔离之前已在途：切号前发出 beacon / keepalive 各两条，服务扣 300–1500 ms（远超设备上拆到清的 33–45 ms，又都在 2 s 宽限内）
    //   再带 Set-Cookie 答；
    // - 隔离之后才发出（每 20 ms 的 beacon、pagehide 时 beacon + keepalive）：产品必须拦下（一个都到不了服务）；放过了的服务扣
    //   1.2 s 再答，一定落在清理之后。
    // 断言：所有迟到响应都答完之后，可信 Cookie 库、新文档的 document.cookie、新文档的入口请求与普通请求（新账号的请求）都没有它们；
    // 阳性对照：切号前同一种迟到 Set-Cookie 确实落进 Cookie 库、并随下一个请求带出；切号后新种的 Cookie 同一读法读得到。
    // t5（D10-391 ②）：改为只断言最终状态（上面这几条与两个阳性对照一字不动）。删去两条在 ArkWeb 上不成立的前提：隔离前在途请求的
    // 答复不得出错（下树即断连），以及隔离后发出的 beacon / keepalive 0 条到达、产品拦过（onInterceptRequest 看不到它们）。
    it('E07_NR1_01_old_document_beacon_and_keepalive_late_set_cookie_never_reaches_new_account', 0, async () => {
      const rig: Fx25BeaconRig = Fx25BeaconRig.shared;
      Fx25ExternalCacheRig.shared.externalOnly = false;
      // t5（设施）：先起测试 Ability 再起回环服务——rig.start() 要用 Ability 记下的沙盒目录；原写法在整套里靠前面的用例起过
      // Ability 才成立，单跑 E07 时 start() 恒为 false（设备 10 次单跑都红在这一行）。之后才切到 BEACON 场景（页面要用 rig.config）。
      await startFx25();
      expect(await until((): Promise<boolean> => rig.start())).assertTrue();
      Fx25Scene.shared.mode = Fx25Scene.BEACON;
      await startFx25();
      expect(await until((): Promise<boolean> => Promise.resolve(rig.tryAttach()))).assertTrue();
      const current: () => webview.WebviewController = (): webview.WebviewController => rig.controllers.controller();
      expect(await until((): Promise<boolean> => holds(current, 'window.fx25Ready'))).assertTrue();
      // t5（设施）：回环页不靠 scheme handler，Web 自己的 src 加载和 tryAttach 的 loadUrl 都可能打到服务，先就绪的那份随后会被后一份
      // 顶掉（suite4 实测：fx25Ready 之后几毫秒内 runJavaScript 失败，红在下面的阳性对照）。等到当前文档就是服务答出的最后一份、
      // 且 500 ms 内没有新的入口请求，才开始布置。只是前置条件更严，判定不变。
      expect(await until(async (): Promise<boolean> => {
        const served: number = rig.documents;
        if (served === 0 || !(await holds(current, 'window.fx25Ready===true&&window.fx25Document===' + served))) return false;
        await pause(500);
        return rig.documents === served && await holds(current, 'window.fx25Document===' + served);
      })).assertTrue();
      const old: webview.WebviewController = current();
      const before: number = Number(await old.runJavaScript('window.fx25Document'));
      // 阳性对照（切号前）：beacon 与 keepalive 的迟到 Set-Cookie 真的落进共用 Cookie 库，并随下一个请求带出。
      expect(await holds(current, 'fx25Late("beacon","ctl",300)')).assertTrue();
      expect(await holds(current, 'fx25Late("keepalive","ctl",300)')).assertTrue();
      expect(await until((): Promise<boolean> => Promise.resolve(rig.late.filter((r: Fx25LateRequest): boolean =>
        r.tag === 'ctl' && r.servedAt > 0).length === 2))).assertTrue();
      expect(await until((): Promise<boolean> => Promise.resolve(
        Fx25CookieRig.cookies(rig.url, false).indexOf('fx25_late_beacon_ctl=user-a') >= 0 &&
        Fx25CookieRig.cookies(rig.url, false).indexOf('fx25_late_keepalive_ctl=user-a') >= 0))).assertTrue();
      expect(await holds(current, 'fx25Probe("ctl")')).assertTrue();
      expect(await until((): Promise<boolean> => Promise.resolve(rig.probes.some((seen: Fx25SeenCookie): boolean =>
        seen.tag === 'ctl' && seen.cookie.indexOf('fx25_late_beacon_ctl=user-a') >= 0 &&
        seen.cookie.indexOf('fx25_late_keepalive_ctl=user-a') >= 0)))).assertTrue();
      // 隔离之前已在途的迟到请求：都到了服务（在途）才切号。
      for (let i = 0; i < FX25_E07_PRE_DELAYS.length; i++) {
        const kind: string = i % 2 === 0 ? 'beacon' : 'keepalive';
        expect(await holds(current, 'fx25Late("' + kind + '","pre' + i + '",' + FX25_E07_PRE_DELAYS[i] + ')')).assertTrue();
      }
      expect(await until((): Promise<boolean> => Promise.resolve(rig.late.filter((r: Fx25LateRequest): boolean =>
        r.tag.startsWith('pre')).length === FX25_E07_PRE_DELAYS.length))).assertTrue();
      expect(await holds(current, 'fx25Arm()')).assertTrue();
      const result: ApiResult = await rig.switchAccount();
      expect(result.code).assertEqual(0);
      expect(await rig.config.whenAuthSettled()).assertTrue();
      expect(rig.isolatedAt > 0).assertTrue();
      expect(await until(async (): Promise<boolean> => {
        if (rig.controllers.current === old) return false;
        try {
          return Number(await current().runJavaScript('window.fx25Ready===true?window.fx25Document:0')) > before;
        } catch (e) { return false; }
      })).assertTrue();
      expect(Fx25Controllers.detached(old)).assertTrue();
      // 所有到了服务的迟到请求都已答完（带 Set-Cookie），再给网络服务 1 s 落盘。
      expect(await until((): Promise<boolean> => Promise.resolve(rig.allServed()))).assertTrue();
      await pause(1000);
      // 取证记录（hilog FX25E07）：每个迟到请求的发出 / 到达 / 答出时刻与分类、隔离时刻、旧控制器解绑之后的诊断计数。
      console.info('FX25E07 isolatedAt=' + rig.isolatedAt + ' diagnostics=' + JSON.stringify(rig.diagnostics));
      for (const r of rig.late) {
        console.info('FX25E07 late ' + r.kind + ' ' + r.tag + ' issued=' + r.issuedAt + ' arrived=' + r.arrivedAt + ' delay=' + r.delay +
          ' served=' + r.servedAt + ' post=' + r.postIsolation + ' err=' + r.sendError);
      }
      for (const seen of rig.entries.concat(rig.probes)) {
        console.info('FX25E07 seen doc=' + seen.doc + ' tag=' + seen.tag + ' cookie=' + seen.cookie);
      }
      console.info('FX25E07 jar=' + Fx25CookieRig.cookies(rig.url, false));
      const pre: Fx25LateRequest[] = rig.late.filter((r: Fx25LateRequest): boolean => r.tag.startsWith('pre'));
      expect(pre.length).assertEqual(FX25_E07_PRE_DELAYS.length);
      // t5（D10-391 ②）：删去「隔离前在途的请求答复时不得出错」——旧 Web 下树时 ArkWeb 断开这类连接，晚到的答复报 Network is down
      // 属预期（这正是 D10-391 ① 认定的防线之一），只记 hilog。
      // t5（D10-391 ①）：删去「隔离后发出的请求 0 条到达服务」「产品拦过（auth_isolated_request）」——设备上 ArkWeb 的
      // onInterceptRequest 看不到 sendBeacon / fetch keepalive（nr1 取证 diagnostics=[]、tick1 到达），拦截不是这类请求的防线；
      // 隔离起本地 403 作普通 fetch / XHR 的纵深，改由 E01 的纵深探针断言。这些请求到没到、答没答出只记 hilog，它们带回的
      // Set-Cookie 有没有进新账号由下面的最终状态判定。
      const post: Fx25LateRequest[] = rig.late.filter((r: Fx25LateRequest): boolean => r.postIsolation);
      console.info('FX25T5 e07 pre=' + pre.length + ' preServed=' + pre.filter((r: Fx25LateRequest): boolean => r.servedAt > 0).length +
        ' preCut=' + pre.filter((r: Fx25LateRequest): boolean => r.sendError.length > 0).length + ' post=' + post.length +
        ' postServed=' + post.filter((r: Fx25LateRequest): boolean => r.servedAt > 0).length + ' isolatedRequests=' +
        rig.diagnostics.filter((kind: string): boolean => kind === 'auth_isolated_request').length);
      // 门槛判定：迟到的 Set-Cookie 一个都不在可信 Cookie 库、新文档、新账号的请求里（含切号前对照种下的 A 的 Cookie）。
      expect(Fx25CookieRig.cookies(rig.url, false).indexOf('fx25_late_') < 0).assertTrue();
      expect(await holds(current, 'document.cookie.indexOf("fx25_late_")<0')).assertTrue();
      const fresh: Fx25SeenCookie[] = rig.entries.filter((seen: Fx25SeenCookie): boolean => seen.doc > before);
      expect(fresh.length > 0).assertTrue();
      for (const seen of fresh) {
        expect(seen.cookie.indexOf('fx25_late_') < 0).assertTrue();
      }
      expect(await holds(current, 'fx25Probe("after")')).assertTrue();
      expect(await until((): Promise<boolean> => Promise.resolve(rig.probes.some((seen: Fx25SeenCookie): boolean =>
        seen.tag === 'after')))).assertTrue();
      for (const seen of rig.probes.filter((x: Fx25SeenCookie): boolean => x.tag === 'after')) {
        expect(seen.cookie.indexOf('fx25_late_') < 0).assertTrue();
      }
      // 阳性对照（切号后）：新种一个 Cookie，同一读法在新文档的请求里读得到它。
      webview.WebCookieManager.configCookieSync(rig.url, 'fx25_probe=b; Path=/', false);
      expect(await holds(current, 'fx25Probe("positive")')).assertTrue();
      expect(await until((): Promise<boolean> => Promise.resolve(rig.probes.some((seen: Fx25SeenCookie): boolean =>
        seen.tag === 'positive' && seen.cookie.indexOf('fx25_probe=b') >= 0 && seen.cookie.indexOf('fx25_late_') < 0)))).assertTrue();
      // 再给一次落盘机会：测试自己重载入口，入口请求同样不带迟到 Cookie（带着刚种的那个）。
      const last: number = rig.documents;
      current().loadUrl(rig.url);
      expect(await until((): Promise<boolean> => Promise.resolve(rig.entries.some((seen: Fx25SeenCookie): boolean =>
        seen.doc > last)))).assertTrue();
      for (const seen of rig.entries.filter((x: Fx25SeenCookie): boolean => x.doc > last)) {
        expect(seen.cookie.indexOf('fx25_probe=b') >= 0).assertTrue();
        expect(seen.cookie.indexOf('fx25_late_') < 0).assertTrue();
      }
      expect(Fx25CookieRig.cookies(rig.url, false).indexOf('fx25_late_') < 0).assertTrue();
      expect(rig.config.isAuthIsolated()).assertFalse();
      await rig.stop();
    });
  });
}
