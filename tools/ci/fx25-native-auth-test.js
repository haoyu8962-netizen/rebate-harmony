// F-X-25：与 F-X-24 一样抽取生产声明和生命周期原文；外围只替换系统端口。
// 不手调 auth listener / reload，不复制订阅、判定或调度。ApiClient 是现有 NetworkTestRig 中的真实类。
//
// t1（新方案「先拆后清再建」，D10-277 / D10-279；独立 Claude 测试作者）夹具改动：
// - 作废 v6 的 documentStart「文档开始回执」开关、v6 attachModel / v7 mountModel 开关：三者现在都是唯一模型、始终打开。
// - 作废「sessionStorage 按页 × 源保存、Web 重建不重置」：改为按 Web 实例保存——每次生产 build() 挂上一个新的 Web 节点就是一个新实例，
//   带全新的 sessionStorage 命名空间（D10-279 I2 的前提，由设备 E01 取证；设备结果相反时这个模型和依赖它的断言都要回到编排）。
// - 控制器：从生产 build() 的 Web(...) 参数里读 Web 实际绑定的 controller（不看产品自报）。webview.WebviewController 是本夹具的假类，
//   生产 `new webview.WebviewController()` 或测试给的 config.controllerFactory 都从它出来。控制器只在它的 Web 挂上且系统派发了
//   onControllerAttached 之后可用；Web 卸下之后（或从未挂上）任何调用都按 SDK 抛 {code:17100001}。
// - 生命周期：生产 state 换成真实 TrustedWebState（去掉 V2 装饰器）外包一层观察：任何字段变化后下一轮事件循环按生产 build() 的 Web
//   分支条件重算一次（同 ArkUI 的状态驱动重建）。Web 进 build = 挂上新实例并派发生产 onAppear，下一轮派发 onControllerAttached，
//   随后加载 Web 自己的 src（about:blank 也会有一份空白文档与 onPageBegin）；Web 出 build = 卸下：旧文档在这一刻销毁（先跑它登记的
//   pagehide 写回），先解绑旧控制器（之后调用抛 17100001），再派发生产 onDisAppear。p.holdUnmount 让卸下挂着；p.holdUnbind 让「已
//   onDisAppear、旧控制器还没解绑」挂着（两信号缺一，I1）；p.holdAttach / p.neverAttach 让新 Web 等不到 attach（被压页 / 永不渲染）。
// - 系统回调一律派发生产 build() 里 Web 链上的回调原文：onAppear / onDisAppear / onControllerAttached / onPageBegin / onPageEnd；
//   javaScriptProxy 与 javaScriptOnDocumentStart 的参数在每个 Web 实例挂上时取一次（代理对象跟着实例走，不跟着组件字段走）。
//
// t3（设备问题修复后的补测，独立 Claude）：两样都缺省关闭，原 135 条走的路径逐字不变。
// - p.loadModel（测试在 open 之后、切号之前设）：「异步加载 / 入口请求被吞」模型，只作用于之后挂上的 Web（清理载体）。
//   { blank: 'sync' | 'turn' | 'held' | 'intercept' | 'silent', swallow: n, holdCommit: bool }
//   · blank：载体自己的 about:blank 加载何时开始——sync 同缺省（挂上即开始）；turn 下一轮；held 等测试 p.releaseBlank()；
//     intercept 下一轮先派发生产 onLoadIntercept(about:blank)，被取消就永远不开始（看不到它的 onPageBegin）；silent 直接被取消
//     （不在途、永远没有 onPageBegin）。
//     about:blank 还在途时发出的 loadUrl 被它顶掉（设备 t2 实测现象）：没有请求、没有 onLoadIntercept、没有 onPageBegin。
//   · swallow：另外强制吞掉接下来 n 次入口 loadUrl（同上，什么都不发生）。
//   · 没被吞的 loadUrl：下一轮派发生产 onLoadIntercept（隔离中由产品决定放不放行），放行 = 请求真的发出（记 p.reloads），
//     再下一轮（holdCommit 时等 p.releaseCommit()）新文档提交、派发 onPageBegin。同一 Web 上新的 loadUrl 取代还没提交的上一次。
//   · p.entryCalls 记每一次 loadUrl（含被吞的），p.commits 记每一次真正提交的文档及提交前后的隔离状态。
// - fixture({ stringCode: true })：假控制器的 17100001 按设备实测抛字符串 code（"17100001"）。
//
// t4（评审新 r1 之后，独立 Claude；NR1-01 / NR1-04）：新增的都缺省关闭或只在调用时生效，原 146 条走的路径不变。
// - onInterceptRequest 也从生产 Web 链上取原文；只有测试调 p.intercept(request) 时才派发（系统对一个资源请求问一次产品）。
//   request 用 resourceRequest(url, { mainFrame, dest, method, unreadable }) 造；生产回的 WebResourceResponse 是本夹具的假类，
//   记下状态码 / 就绪等字段（null = 放行，交给系统照常加载）。
// - Cookie 读回（清完复核用）：WebCookieManager.existCookie / fetchCookieSync / fetchCookie 读的是同一份 Cookie（非无痕 = 可信
//   容器那一份，incognito = ExternalWebView 那一份）；只读，不算清理。
// - p.holdDisappear：卸下时旧控制器先解绑（之后抛 17100001），onDisAppear 挂着、旧文档仍活着（NR1-04「已解绑、节点还没卸下」）；
//   p.releaseDisappear() 放行（这时旧文档销毁、派发 onDisAppear）。与 holdUnbind（先 onDisAppear、后解绑）正好相反。
// - 拆后宽限（NR1-01）：生产 TrustedAuthSync.COOKIE_GRACE_MS 这一个计时器由端口 fx25-v3-ports 的 grace 模型接管——缺省下一轮
//   自己到期（原用例不用真等 2 s）；测试 clock.holdGrace() 后只在 clock.releaseGrace() 时到期，用来断言宽限期内不清。
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

// 只供测试显式注入；不依赖生产在缺沙盒目录时的内存兜底，也不冒充跨进程持久化。
class MemoryPendingStore {
  constructor() { this.pending = null; }
  readPending() { return this.pending; }
  markPending(owner) { this.pending = owner; }
  clearPending() { this.pending = null; }
}
const NOT_ATTACHED = 17100001;
function notAttachedError(api) {
  const error = new Error('17100001 Init error. The WebviewController must be associated with a Web component. (' + api + ')');
  error.code = NOT_ATTACHED;
  return error;
}
// t3：onLoadIntercept 也从生产 Web 链上取原文（只有 p.loadModel 打开时夹具才派发它；缺省路径不派发，与 t1 / t2 相同）。
const WEB_EVENTS = ['onAppear', 'onDisAppear', 'onControllerAttached', 'onPageBegin', 'onPageEnd', 'onLoadIntercept',
  'onInterceptRequest'];
/** t4：系统交给 onInterceptRequest 的请求（WebResourceRequest 的只读面）。unreadable：读请求字段时抛错。 */
function resourceRequest(url, { mainFrame = false, dest = 'empty', method = 'GET', unreadable = false, redirect = false } = {}) {
  const read = value => () => { if (unreadable) throw new Error('request unreadable'); return value; };
  return { getRequestUrl: read(url), isMainFrame: read(mainFrame), isRedirect: read(redirect), getRequestMethod: read(method),
    isRequestGesture: read(false), getRequestHeader: read(dest === null ? [] : [{ headerKey: 'Sec-Fetch-Dest', headerValue: dest }]) };
}
/** t4：假 WebResourceResponse（生产拦截时回的本地响应）；只记字段。 */
class FakeResourceResponse {
  constructor() { this.code = 200; this.ready = false; this.data = null; this.reason = ''; this.mime = ''; this.headers = []; }
  setResponseData(data) { this.data = data; }
  setResponseMimeType(mime) { this.mime = mime; }
  setResponseEncoding(_encoding) {}
  setResponseCode(code) { this.code = code; }
  setReasonMessage(reason) { this.reason = reason; }
  setResponseIsReady(ready) { this.ready = ready; }
  setResponseHeader(headers) { this.headers = headers; }
  getResponseCode() { return this.code; }
}
const WEB_OPTIONS = ['javaScriptProxy', 'javaScriptOnDocumentStart'];
const originOf = url => {
  if (!url || url === 'about:blank') return 'null';
  try { return new URL(url).origin; } catch (_error) { return 'null'; }
};

module.exports = function ({ root, ts, tsDir, hypium, registerLegacy = true }) {
  const loader = path.resolve(tsDir, '../..');
  const config = ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config;
  function ast(relative) {
    const file = path.join(root, relative);
    const tree = ts.createSourceFile(file, require('./fx25-v3-mutations').mutate(file, fs.readFileSync(file, 'utf8')), ts.ScriptTarget.ES2021, true,
      ts.ScriptKind.ETS, { ets: config.compilerOptions.ets, etsLoaderPath: loader });
    assert.strictEqual(tree.parseDiagnostics.length, 0, relative + ' parse');
    return tree;
  }
  function named(nodes, name) {
    const found = nodes.filter(n => n.name && n.name.getText() === name);
    assert.strictEqual(found.length, 1, 'product declaration: ' + name);
    return found[0];
  }
  const web = ast('features/web/src/main/ets/TrustedWebView.ets');
  const app = ast('entry/src/main/ets/web/AppBridge.ets');
  const ext = ast('features/web/src/main/ets/ExternalWebView.ets');
  const component = named(web.statements, 'TrustedWebView');
  const appClass = named(app.statements, 'AppBridge');
  // t1：TrustedWebState 用生产类本身（去掉 @ObservedV2 / @Trace 装饰器，字段与缺省值原样），不再用空对象代替。
  const stripDecorators = text => text.replace(/@(ObservedV2|Trace)\b\s*/g, '');
  const declarations = web.statements.filter(n => (ts.isClassDeclaration(n) && n.name && n.name.text !== 'ApplicationStateListener') ||
    ts.isFunctionDeclaration(n)).map(n => stripDecorators(n.getText(web)));
  // 全部非绘制/系统 UI 方法及字段原文；避免新字段初始化遗漏。UI 方法只做平台注册，与切号无关。
  const uiMethods = new Set(['build', 'registerUiHandlers', 'watchApplicationState', 'restoreStatusBar',
    'goBack', 'setStatusBar', 'applyStatusBar']);
  const members = component.members.filter(n => n.name && !uiMethods.has(n.name.getText()) &&
    !['config', 'state'].includes(n.name.getText()) && !n.getText(web).includes('@Builder'));
  const webConstructors = [];
  const errorGuards = [];
  const webCalls = {};
  for (const name of [...WEB_EVENTS, ...WEB_OPTIONS]) webCalls[name] = [];
  function chainRoot(node) {
    let current = node;
    while (ts.isCallExpression(current) && ts.isPropertyAccessExpression(current.expression)) current = current.expression.expression;
    return current;
  }
  function collectWeb(node, guards = []) {
    if (ts.isIfStatement(node)) {
      collectWeb(node.thenStatement, [...guards, '(' + node.expression.getText(web) + ')']);
      if (node.elseStatement) collectWeb(node.elseStatement, [...guards, '!(' + node.expression.getText(web) + ')']);
      return;
    }
    if (node.expression && node.arguments && node.expression.getText(web) === 'Web') {
      webConstructors.push({ guards, options: node.arguments[0].getText(web) });
    }
    if (node.expression && node.arguments && node.expression.getText(web) === 'ErrorState') {
      errorGuards.push(guards);
    }
    // 只认根是 Web(...) 的链（ETS 里 Web(...) 是 EtsComponentExpression），不收别的组件的同名回调。
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) &&
      Object.prototype.hasOwnProperty.call(webCalls, node.expression.name.text) && node.arguments.length === 1) {
      const rootCall = chainRoot(node);
      if (rootCall !== node && rootCall.expression && rootCall.expression.getText(web) === 'Web') {
        webCalls[node.expression.name.text].push(node.arguments[0].getText(web));
      }
    }
    ts.forEachChild(node, child => collectWeb(child, guards));
  }
  collectWeb(named(component.members, 'build'));
  assert.strictEqual(webConstructors.length, 1, 'one production Web constructor; adapt extractor if layout changes');
  const renderedWeb = 'initialWeb() { if (' + (webConstructors[0].guards.join(' && ') || 'true') +
    ') return ' + webConstructors[0].options + '; return null; }';
  assert.strictEqual(errorGuards.length, 1, 'one production ErrorState; adapt extractor if layout changes');
  const renderedError = 'errorVisible() { return ' + (errorGuards[0].join(' && ') || 'true') + '; }';
  const missing = (name, count) => 'throw new Error("production Web must have exactly one ' + name + '; found ' + count + '");';
  const renderedEvents = 'webEvent(kind, event) {\n' + WEB_EVENTS.map(kind => '  if (kind === ' + JSON.stringify(kind) + ') { ' +
    (webCalls[kind].length === 1 ? 'return (' + webCalls[kind][0] + ')(event);' : missing(kind, webCalls[kind].length)) + ' }').join('\n') +
    '\n  throw new Error("unknown Web event " + kind);\n}';
  const renderedOptions = WEB_OPTIONS.map(name => name + 'Option() { ' + (webCalls[name].length === 1 ? 'return (' + webCalls[name][0] + ');' :
    missing(name, webCalls[name].length)) + ' }').join('\n');
  declarations.push('export class Lifecycle {\n' + members.map(n => n.getText(web)).join('\n') + '\n' + renderedWeb + '\n' + renderedError +
    '\n' + renderedEvents + '\n' + renderedOptions + '\n}');
  declarations.push(appClass.getText(app)); // 完整生产工厂类，后续提取 helper 仍执行同一份接线。
  for (const name of ['ExternalWebConfig', 'ExternalFrame']) declarations.push(named(ext.statements, name).getText(ext));
  const externalView = named(ext.statements, 'ExternalWebView');
  declarations.push('export class ExternalWebView {\n' + ['aboutToAppear', 'aboutToDisappear', 'hostOf']
    .map(name => named(externalView.members, name).getText(ext)).join('\n') + '\n}');
  const compiled = ts.transpileModule(declarations.join('\n'), { fileName: 'Fx25ProductSlice.ts',
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  const core = require(path.join(root, 'common/core/Index.ets'));
  const { Rig, envelope, tokenPair } = require(path.join(root, 'common/core/src/test/NetworkTestRig.ets'));
  const { FakeState } = require(path.join(root, 'common/core/src/test/BridgeHost.test.ets'));
  const { bridgeBootstrapScript } = require(path.join(root, 'features/web/src/main/ets/BridgeBootstrapScript.ets'));
  const portsModule = require('./fx25-v3-ports');
  // t4（NR1-01）：生产的拆后宽限计时器交给端口的 grace 模型（缺省下一轮自己到期；holdGrace 时由测试放行）。产品还没有这个常量时
  // 不接管（t4 用例自己断言常量存在）。
  {
    const sync = require(path.join(root, 'common/core/src/main/ets/bridge/TrustedAuthSync.ets')).TrustedAuthSync;
    portsModule.setGraceDelay(sync && typeof sync.COOKIE_GRACE_MS === 'number' ? sync.COOKIE_GRACE_MS : null);
  }

  function fixture(options = {}) {
    const ports = options.ports || null;
    // t1（R3-04）：production = { filesDir }：走生产 AppBridge.attach(context) → 沙盒 FileTrustedAuthJournal / FileTrustedWebOwnerRecord
    // （FileSlot + 系统 fileIo，fileIo 由 sandboxFileIo 端口落到测试临时目录）；页面配置不传任何切号参数，与 WebPage 路由相同。
    const production = options.production || null;
    // 显式 null 留给缺配置反例；每个夹具一份存储，同一夹具多页面共享。
    const pending = production ? null : Object.prototype.hasOwnProperty.call(options, 'pending') ? options.pending :
      (ports ? ports.journal : new MemoryPendingStore());
    // 显式 tokens: null = 冷启动时磁盘上没有会话（v6 R2-04 按旧进程实际落盘的会话重启）；未给仍是 user-a。
    const network = new Rig(Object.prototype.hasOwnProperty.call(options, 'tokens') ? options.tokens :
      new core.SessionTokenSet('test-access-a', 'test-refresh-a', 'full', 'user-a', 'epoch-a'));
    // t1（R3-03）：从进程一开始身份就暂时读不出（凭据门关着 / 安全存储读不出），切号处理建起来时就是未知。
    if (options.unreadable) network.context.readable = false;
    const trace = [];
    // t1：生命周期 + 清理 + 加载的总时间线（顺序断言「拆 → 清 → 载」用；trace 仍只放 notify / clear / reload，旧断言不变）。
    const timeline = [];
    const mark = entry => timeline.push(entry);
    const pages = [];
    const controllers = [];
    const fixtureGlobals = [];
    const external = { cookie: 'external-cookie', local: 'external-local', cache: 'external-cache', reloads: 0 };
    let sequence = 0;
    let controllerSequence = 0;
    let instanceSequence = 0;
    let cookieGate = null;
    let cookieEntered;
    const cookieStarted = new Promise(resolve => { cookieEntered = resolve; });
    let eventGate = null;
    let eventEntered;
    const eventStarted = new Promise(resolve => { eventEntered = resolve; });
    let clearFailure = null;
    // t3：设备上 BusinessError.code 是字符串 "17100001"（t2 hilog）；缺省仍是数值，原用例不变。
    const notAttached = api => {
      const error = notAttachedError(api);
      if (options.stringCode) error.code = String(NOT_ATTACHED);
      return error;
    };
    const clear = (kind, incognito = false) => {
      trace.push('clear:' + kind + ':' + incognito);
      mark('clear:' + kind + ':' + incognito);
      if (clearFailure && clearFailure.kind === kind) {
        clearFailure.calls++;
        if (clearFailure.calls === clearFailure.nth || (clearFailure.permanent && clearFailure.calls >= clearFailure.nth)) {
          clearFailure.failed++;
          throw new Error('injected ' + kind + ' storage failure');
        }
      }
      if (incognito) { external[kind] = ''; return; }
      for (const p of pages) {
        if (kind === 'cookie') p.cookie = '';
        if (kind === 'local') { p.local.clear(); p.indexedDB.clear(); }
        if (kind === 'cache') p.cache = '';
      }
    };
    /** t6（D10-396）：全应用 HTTP 缓存清理的效果——可信 profile 与外部 incognito 页的缓存一起没了。 */
    const appWideCacheClear = () => {
      if (ports) ports.clearCache(); else clear('cache');
      external.cache = '';
    };
    /** 假 ArkWeb 控制器：只在它的 Web 实例挂上并派发 onControllerAttached 之后、卸下（解绑）之前可用。 */
    class FakeController {
      constructor() {
        this.id = ++controllerSequence;
        this.inst = null; this.page = null; this.attached = false; this.dead = false; this.everBound = false;
        this.loads = []; this.quirks = null; this.refusals = 0;
        controllers.push(this);
      }
      // t6（D10-396）：ArkWeb 的缓存清理不论静态还是经哪个控制器调用，都清全应用所有 Web 的 HTTP 缓存（SDK 6.1.1 文档，t5 设备 7/7）。
      // 两个接口都按全局清理建模：记进 globalCalls（I6，任何时候都不得调用），并真的清掉外部 / 隐私页那一份（externalUnchanged 会红）。
      static removeAllCache(...args) { fixtureGlobals.push('removeAllCache(' + args.map(String).join(',') + ')'); appWideCacheClear(); }
      live(api) {
        const quirk = this.quirks && this.quirks[api];
        if (quirk === 'notAttached' || !this.inst || !this.attached || this.dead) {
          this.refusals++;
          if (this.page) this.page.notAttached.push(api);
          throw notAttached(api);
        }
      }
      get url() { return this.inst ? this.inst.url : ''; }
      set url(value) { if (this.inst) this.inst.url = value; }
      getWebId() { this.live('getWebId'); return this.id; }
      getUrl() { this.live('getUrl'); return this.inst.url; }
      getLastJavascriptProxyCallingFrameUrl() { this.live('getLastJavascriptProxyCallingFrameUrl'); return this.inst.url; }
      getUserAgent() { this.live('getUserAgent'); return 'ArkWeb-Fx25'; }
      setCustomUserAgent(_ua) { this.live('setCustomUserAgent'); }
      setWebSchemeHandler() { this.live('setWebSchemeHandler'); }
      accessBackward() { this.live('accessBackward'); return false; }
      backward() { this.live('backward'); }
      runJavaScript(script) { return this.runJavaScriptExt(script); }
      runJavaScriptExt(script) {
        this.live('runJavaScript');
        const p = this.page;
        const realm = this.inst.current;
        p.scripts.push(script);
        p.executions.push({ document: realm ? realm.index : 0, controller: this, realm, script });
        for (const hook of p.scriptHooks) hook(script, this, realm);
        // 执行落在发起时的那份文档；文档已销毁（Web 卸下、换了文档）就执行失败，不会改投到新文档。
        const execute = () => {
          if (!realm || !realm.alive) throw new Error('document gone: script not executed');
          const result = vm.runInContext(script, realm.context);
          return result === undefined ? '' : String(result);
        };
        if (script.includes('auth.changed')) {
          eventEntered(true);
          if (eventGate) return eventGate.then(execute);
        }
        try { return Promise.resolve(execute()); } catch (error) { return Promise.reject(error); }
      }
      removeCache(disk) {
        this.live('removeCache');
        this.page.cacheVia.push(this);
        mark(this.page.name + ':removeCache#' + this.id);
        fixtureGlobals.push('removeCache(' + String(disk) + ')'); // t6（D10-396）：全应用级，见 removeAllCache
        appWideCacheClear();
      }
      stop() { this.live('stop'); if (ports) ports.stop(this.page); }
      loadUrl(url) {
        this.live('loadUrl');
        const p = this.page, inst = this.inst;
        if (p.loadModel) return modelLoad(p, inst, this, url);
        trace.push(p.name + ':reload');
        mark(p.name + ':reload#' + this.id);
        const session = inst.origins.get(originOf(url));
        p.reloads.push({ url, cookie: p.cookie, local: Array.from(p.local), session: session ? Array.from(session) : [],
          indexedDB: Array.from(p.indexedDB), cache: p.cache });
        p.reloadControllers.push(this);
        this.loads.push(url);
        for (const hook of p.loadHooks) hook(url, this);
        createRealm(p, inst, url);
        if (ports && ports.deferDocument) { p.commit = () => pageBegin(p, inst, url); return; }
        // 系统导航回调：只有产品真正调用 loadUrl/refresh 才派发，测试不得额外补触发。
        pageBegin(p, inst, url);
        if (p.afterCommit) p.afterCommit();
      }
      refresh() { this.loadUrl(this.inst ? this.inst.url : ''); }
    }
    const webview = {
      WebviewController: FakeController,
      WebCookieManager: {
        clearAllCookiesSync: (incognito = false) => {
          if (incognito === true) fixtureGlobals.push('clearAllCookiesSync(true)');
          cookieEntered('sync'); clear('cookie', incognito);
        },
        clearAllCookies: async (...args) => {
          if (args.length > 0) fixtureGlobals.push('clearAllCookies(' + args.map(String).join(',') + ')');
          cookieEntered('async'); if (cookieGate) await cookieGate; clear('cookie');
        },
        // t4：读回（只读）。非无痕 = 各可信容器的 Cookie；incognito = 外部页那一份。
        existCookie: (incognito = false) => incognito === true ? external.cookie !== '' : pages.some(p => p.cookie !== ''),
        fetchCookieSync: (url, incognito = false) => incognito === true ? external.cookie :
          pages.filter(p => originOf(p.config.url) === originOf(url)).map(p => p.cookie).filter(Boolean).join('; '),
        fetchCookie: async (url, incognito = false) => webview.WebCookieManager.fetchCookieSync(url, incognito)
      },
      WebStorage: { deleteAllData: (incognito = false) => {
        if (incognito === true) fixtureGlobals.push('deleteAllData(true)');
        clear('local', incognito);
      } }
    };
    if (ports) ports.install(webview, pages, external, trace, mark);
    const bindings = { exports: {}, webview, Promise,
      setTimeout: ports ? ports.clock.setTimeout : setTimeout,
      clearTimeout: ports ? ports.clock.clearTimeout : clearTimeout,
      util: { generateRandomUUID: () => (++sequence).toString(16).padStart(32, '0') },
      systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 1000000 },
      AppNetwork: { client: network.client, tokens: network.tokens },
      AppClientCore: { shared: { config: null } },
      hilog: { info() {} }, DOMAIN: 0, TAG: 'Fx25' };
    // t4：生产拦截资源请求时回本地响应（WebResourceResponse 是 ArkUI 全局类）；组件静态方法按 TrustedWebView.x() 调用时落到
    // 抽出的 Lifecycle（组件成员原文都在它上面）。
    bindings.WebResourceResponse = FakeResourceResponse;
    Object.defineProperty(bindings, 'TrustedWebView', { get: () => bindings.exports.Lifecycle });
    for (const n of ['BridgeCaller', 'BridgeFrames', 'BridgeGesture', 'BridgePageSession', 'BridgeReplyChannel',
      'BridgeHost', 'OriginRules', 'TrustedNavPolicy', 'SessionIdentity', 'ExternalNavStyle', 'ExternalNavHooks', 'ExternalNavFrame',
      'ExternalPageNavigator', 'ExternalNoticeKey']) bindings[n] = core[n];
    for (const name of Object.keys(core)) {
      if (!(name in bindings)) Object.defineProperty(bindings, name, { get: () => core[name] });
    }
    // 新下沉类只允许来自真实 core 导出/文件，绝不注入测试实现。
    const decisionFile = path.join(root, 'common/core/src/main/ets/bridge/AuthChangeDecision.ets');
    if (fs.existsSync(decisionFile) && !('AuthChangeDecision' in bindings)) {
      bindings.AuthChangeDecision = require(decisionFile).AuthChangeDecision;
    }
    bindings.ExternalTitleColors = { of: () => ({}) }; // 只替换系统绘制颜色
    // 生产 scripts()（javaScriptOnDocumentStart 的条目）原样执行所需的真实依赖，不替换内容。
    bindings.bridgeBootstrapScript = bridgeBootstrapScript;
    if (!('BridgeErrors' in bindings)) Object.defineProperty(bindings, 'BridgeErrors', { get: () => require('generated').BridgeErrors });
    vm.runInNewContext(compiled, bindings);
    const { AppBridge, Lifecycle, BridgeEnvInfo, ExternalWebConfig, ExternalWebView, TrustedWebState } = bindings.exports;
    assert.ok(TrustedWebState, 'production TrustedWebState');
    const externalConfig = new ExternalWebConfig(new core.ExternalPageOptions('https://external.example.test/'),
      new core.ExternalNavPolicy(new FakeState().linkPatterns()), () => new FakeState().linkPatterns(), 'test');
    const externalController = { stop() {}, refresh() { external.reloads++; }, loadUrl() { external.reloads++; },
      removeCache(disk) { fixtureGlobals.push('external.removeCache(' + String(disk) + ')'); appWideCacheClear(); }, runJavaScriptExt() { throw new Error('external must receive no bridge script'); } };
    const externalView = Object.assign(new ExternalWebView(), { config: externalConfig, state: {},
      controller: externalController, fullScreen: new core.WebFullScreen(() => {}) });
    externalView.aboutToAppear();
    assert.strictEqual(externalView.state.host, 'external.example.test');
    Object.assign(AppBridge, { nextContainerId: () => 'fx25-' + (++sequence), containers: new Map(),
      createHost: (_page, state) => new core.BridgeHost(state),
      envInfo: () => new BridgeEnvInfo('1', '1', 'test', 'test') });
    if (production) {
      portsModule.enableSandbox(production.filesDir);
      AppBridge.attach({ filesDir: production.filesDir }); // 生产启动入口（EntryAbility.onCreate）
    }
    // v7（R2-04 第三道）：显式给归属记录时，按生产签名 AppBridge.trustedAuth(client, epochs, pending, owner) 先建好切号处理；
    // 之后容器的 wireAuth 取到的就是这一份（每个 ApiClient 一份）。不给时与 v6 完全一样（注入 pending 时生产缺省没有归属记录）。
    if (ports && pending !== null && Object.prototype.hasOwnProperty.call(options, 'owner')) {
      AppBridge.trustedAuth(network.client, network.tokens, pending, options.owner);
    }

    // ---------- 文档（每份文档属于一个 Web 实例；sessionStorage 跟实例与源走） ----------
    function createRealm(p, inst, url) {
      for (const document of inst.documents) document.alive = false; // 换文档：上一份销毁
      const origin = originOf(url);
      inst.url = url;
      if (!inst.origins.has(origin)) inst.origins.set(origin, new Map());
      const realm = { alive: true, inst, origin, url, storage: inst.origins.get(origin), index: 0, pagehide: null, context: null };
      const guard = () => { if (!realm.alive) throw new Error('destroyed document cannot write'); };
      const storage = map => ({ getItem: key => map.has(key) ? map.get(key) : null,
        setItem: (key, value) => { guard(); map.set(key, String(value)); }, removeItem: key => { guard(); map.delete(key); },
        clear: () => { guard(); map.clear(); }, get length() { return map.size; } });
      const doc = {};
      Object.defineProperty(doc, 'cookie', { get: () => p.cookie, set: value => { guard(); p.cookie = value; } });
      const indexedDB = { put: (key, value) => { guard(); p.indexedDB.set(key, value); },
        get: key => p.indexedDB.has(key) ? p.indexedDB.get(key) : null };
      const globals = { JSON, Promise, Object, Error, localStorage: storage(p.local), sessionStorage: storage(realm.storage),
        document: doc, indexedDB };
      globals.window = globals; globals.top = globals;
      // javaScriptProxy：只对组件创建时的可信源可见，转发到「这个 Web 实例挂上时」的代理对象。
      const permitted = (p.lifecycle.origins || []).some(o => core.OriginRules.normalize(o) === origin);
      if (permitted && inst.proxy && inst.proxy.object) {
        const proxy = {};
        for (const method of inst.proxy.methodList || []) proxy[method] = (...args) => inst.proxy.object[method](...args);
        globals[inst.proxy.name] = proxy;
      }
      realm.context = vm.createContext(globals);
      p.contexts.push(realm.context);
      realm.index = p.contexts.length;
      p.documents.push(realm);
      inst.documents.push(realm);
      inst.current = realm;
      // 文档开始注入：这个 Web 实例挂上时取到的生产 javaScriptOnDocumentStart 条目（按 scriptRules 匹配源），然后页面自己的第一段脚本。
      for (const item of inst.items || []) {
        if ((item.scriptRules || []).some(rule => rule === '*' || rule === origin)) vm.runInContext(item.script, realm.context);
      }
      if (globals.__REBATE_BRIDGE__) subscribe(p, globals);
      if (p.onDocumentStart) p.onDocumentStart(realm.context, origin, realm);
      return realm;
    }
    function subscribe(p, window) {
      window.__REBATE_BRIDGE__.subscribe(message => {
        p.messages.push(JSON.parse(JSON.stringify(message)));
        if (message.event === 'auth.changed') {
          trace.push(p.name + ':notify');
          mark(p.name + ':notify');
          p.events.push(JSON.parse(JSON.stringify(message)));
        }
      });
    }
    // ---------- t3：异步加载 / 入口请求被吞（p.loadModel；缺省关闭） ----------
    const interceptEvent = url => ({ data: { getRequestUrl: () => url, isMainFrame: () => true, isRedirect: () => false,
      getRequestMethod: () => 'GET', getRequestHeader: () => [], isRequestGesture: () => false } });
    function modelLoad(p, inst, c, url) {
      const m = p.loadModel;
      const swallowed = inst.blankInFlight === true || (m.swallow || 0) > 0;
      p.entryCalls.push({ url, controller: c, inst, swallowed, isolated: p.config.isAuthIsolated ? p.config.isAuthIsolated() : null });
      c.loads.push(url);
      mark(p.name + ':loadUrl#' + c.id + (swallowed ? ':swallowed' : ''));
      for (const hook of p.loadHooks) hook(url, c);
      if (swallowed) {
        if (inst.blankInFlight !== true) m.swallow--;
        p.swallowed.push({ url, controller: c });
        return;
      }
      const nav = ++inst.navigation;
      const current = () => nav === inst.navigation && !inst.removed && !inst.unmounted && !p.closed;
      setImmediate(() => {
        if (!current()) return;
        const cancelled = p.lifecycle.webEvent('onLoadIntercept', interceptEvent(url));
        if (cancelled === true) { p.cancelledLoads.push({ url, controller: c }); mark(p.name + ':cancelled#' + c.id); return; }
        // 请求真的发出：这一刻的存储快照（与缺省模型的 p.reloads 同一含义）。
        trace.push(p.name + ':reload');
        mark(p.name + ':reload#' + c.id);
        const session = inst.origins.get(originOf(url));
        p.reloads.push({ url, cookie: p.cookie, local: Array.from(p.local), session: session ? Array.from(session) : [],
          indexedDB: Array.from(p.indexedDB), cache: p.cache });
        p.reloadControllers.push(c);
        const commit = () => {
          if (!current()) return;
          const entry = { url, controller: c, isolatedBefore: p.config.isAuthIsolated ? p.config.isAuthIsolated() : null, isolatedAfter: null };
          p.commits.push(entry);
          mark(p.name + ':commit#' + c.id);
          createRealm(p, inst, url);
          pageBegin(p, inst, url);
          entry.isolatedAfter = p.config.isAuthIsolated ? p.config.isAuthIsolated() : null;
          if (p.afterCommit) p.afterCommit();
        };
        if (m.holdCommit) p.pendingCommits.push(commit); else setImmediate(commit);
      });
    }
    function modelBlank(p, inst) {
      const mode = p.loadModel.blank || 'sync';
      if (mode === 'sync') return false;
      inst.blankInFlight = true;
      const begin = () => {
        if (inst.removed || inst.unmounted || p.closed || !inst.blankInFlight) return;
        inst.blankInFlight = false;
        mark(p.name + ':blankBegin#' + inst.controller.id);
        createRealm(p, inst, 'about:blank');
        pageBegin(p, inst, 'about:blank');
      };
      if (mode === 'silent') { inst.blankInFlight = false; return true; } // 空白加载被取消：不在途，也永远没有 onPageBegin
      if (mode === 'turn') setImmediate(begin);
      else if (mode === 'held') p.pendingBlanks.push(begin);
      else if (mode === 'intercept') {
        setImmediate(() => {
          if (inst.removed || inst.unmounted || p.closed) return;
          if (p.lifecycle.webEvent('onLoadIntercept', interceptEvent('about:blank')) === true) {
            inst.blankInFlight = false;
            p.blankCancelled++;
            mark(p.name + ':blankCancelled#' + inst.controller.id);
            return;
          }
          begin();
        });
      } else throw new Error('unknown blank mode ' + mode);
      return true;
    }
    function pageBegin(p, inst, url) {
      if (inst.unmounted || p.closed) return;
      p.lifecycle.webEvent('onPageBegin', { url });
      p.generations.push(p.lifecycle.transport.session.generation);
    }
    // ---------- Web 节点（ArkUI 状态驱动：挂上 / 撤出 / 卸下） ----------
    function scheduleRender(p) {
      if (p.renderQueued) return;
      p.renderQueued = true;
      setImmediate(() => { p.renderQueued = false; render(p); });
    }
    function render(p, initial = false) {
      if (p.closed) return;
      const node = p.lifecycle.initialWeb();
      if (node && !p.inst) mount(p, node, initial);
      else if (!node && p.inst) remove(p);
      else if (node && p.inst && node.controller !== p.inst.controller) {
        // ArkUI 不会给一个已经存在的 Web 换控制器：要换只能先下树再挂新的。
        p.ignoredControllerSwaps++;
      }
    }
    function mount(p, node, initial) {
      const c = node.controller;
      assert.ok(c instanceof FakeController, p.name + ': production Web must be given a WebviewController');
      if (c.everBound) { p.reusedControllers++; mark(p.name + ':reuse#' + c.id); }
      const inst = { id: ++instanceSequence, controller: c, src: node.src, url: node.src, origins: new Map(), documents: [],
        current: null, proxy: p.lifecycle.javaScriptProxyOption(), items: p.lifecycle.javaScriptOnDocumentStartOption(),
        removed: false, unmounted: false, navigation: 0, blankInFlight: false };
      // A 已经在用的第一份 Web：入口源的 sessionStorage 里是 A（全新进程的冷启动、空白载体不种）。
      if (initial && node.src !== 'about:blank') inst.origins.set(originOf(p.config.url), new Map([['owner', 'user-a']]));
      c.everBound = true; c.inst = inst; c.page = p; c.attached = false; c.dead = false; c.quirks = p.quirks;
      p.inst = inst; p.instances.push(inst); p.mounts++;
      mark(p.name + ':mount#' + c.id + ':' + node.src);
      if (p.onMount) p.onMount(inst, c);
      p.appears++;
      p.lifecycle.webEvent('onAppear');
      if (initial) attach(p, inst, true);
      else setImmediate(() => attach(p, inst));
    }
    function attach(p, inst, initial = false) {
      const c = inst.controller;
      if (p.inst !== inst || inst.removed || p.closed || c.attached || p.neverAttach || p.holdAttach) return false;
      c.attached = true; p.attaches++;
      mark(p.name + ':attach#' + c.id);
      const before = c.loads.length;
      p.lifecycle.webEvent('onControllerAttached');
      if (c.loads.length === before && p.inst === inst && !inst.current) {
        // Web 自己的 src 开始加载（回调里产品已经发起加载的除外）。
        const src = inst.src;
        if (src === 'about:blank' && p.loadModel && !initial && modelBlank(p, inst)) return true;
        if (src !== 'about:blank') {
          p.loads.push({ url: src, cookie: p.cookie, local: [...p.local], indexedDB: [...p.indexedDB], cache: p.cache });
        }
        createRealm(p, inst, src);
        if (!(initial && !p.startInitial)) pageBegin(p, inst, src);
      }
      return true;
    }
    function remove(p) {
      const inst = p.inst;
      p.inst = null;
      inst.removed = true;
      mark(p.name + ':remove#' + inst.controller.id);
      const unmount = () => {
        if (inst.unmounted) return;
        if (p.holdDisappear && !inst.disappearHeld) {
          // t4（NR1-04）：先解绑旧控制器（之后抛 17100001），onDisAppear 与文档销毁挂到 releaseDisappear()。
          inst.disappearHeld = true;
          if (inst.controller.inst === inst) inst.controller.dead = true;
          mark(p.name + ':unbound#' + inst.controller.id);
          p.pendingDisappears.push(() => {
            for (const realm of inst.documents) {
              if (!realm.alive) continue;
              if (realm.pagehide) { try { realm.pagehide(realm); } catch (_error) { /* 页面自己的异常 */ } }
              realm.alive = false;
            }
            inst.unmounted = true; p.disappears++;
            mark(p.name + ':unmount#' + inst.controller.id);
            if (!p.closed) p.lifecycle.webEvent('onDisAppear');
          });
          return;
        }
        for (const realm of inst.documents) {
          if (!realm.alive) continue;
          if (realm.pagehide) { try { realm.pagehide(realm); } catch (_error) { /* 页面自己的异常 */ } }
          realm.alive = false;
        }
        inst.unmounted = true; p.disappears++;
        mark(p.name + ':unmount#' + inst.controller.id);
        const unbind = () => {
          if (inst.controller.inst === inst) inst.controller.dead = true;
          mark(p.name + ':unbound#' + inst.controller.id);
        };
        if (p.holdUnbind) p.pendingUnbinds.push(unbind); else unbind();
        if (!p.closed) p.lifecycle.webEvent('onDisAppear');
      };
      p.pendingUnmounts.push(unmount);
      if (!p.holdUnmount) p.releaseUnmount();
    }
    function reactive(p, state) {
      return new Proxy(state, { set(target, key, value) {
        const changed = target[key] !== value;
        target[key] = value;
        if (changed) scheduleRender(p);
        return true;
      } });
    }
    function open(name, start = true, extra = {}) {
      const p = { name, cookie: 'old-cookie', local: new Map([['owner', 'user-a']]), indexedDB: new Map([['owner', 'user-a']]),
        cache: 'old-cache', events: [], messages: [], reloads: [], reloadControllers: [], scripts: [], contexts: [], executions: [],
        documents: [], instances: [], loads: [], notAttached: [], cacheVia: [], scriptHooks: [], loadHooks: [], onControllerCalls: [],
        factoryMade: [], generations: [], mounts: 0, attaches: 0, appears: 0, disappears: 0, pendingUnmounts: [], pendingUnbinds: [],
        reusedControllers: 0, ignoredControllerSwaps: 0, inst: null, lastController: null, closed: false, renderQueued: false,
        holdUnmount: false, holdUnbind: false, holdAttach: false, neverAttach: false, quirks: null, startInitial: start,
        loadModel: null, entryCalls: [], swallowed: [], cancelledLoads: [], commits: [], pendingBlanks: [], pendingCommits: [],
        blankCancelled: 0, holdDisappear: false, pendingDisappears: [] };
      if (ports) ports.preparePage(p);
      Object.defineProperty(p, 'controller', { get: () => p.inst ? p.inst.controller : p.lastController });
      Object.defineProperty(p, 'sessionStorage', { get: () => p.inst && p.inst.current ? p.inst.current.storage :
        p.inst && p.inst.origins.get(originOf(p.config.url)) || new Map() });
      Object.defineProperty(p, 'origins', { get: () => p.inst ? p.inst.origins : new Map() });
      /** 测试模拟用户在当前 Web 里换文档（不经产品 loadUrl）；系统随后派发 onPageBegin 由调用方决定。 */
      p.createDocument = url => createRealm(p, p.inst, url || p.inst.url);
      p.releaseUnmount = () => { const due = p.pendingUnmounts.splice(0); for (const run of due) run(); return due.length; };
      p.releaseDisappear = () => { const due = p.pendingDisappears.splice(0); for (const run of due) run(); return due.length; };
      /** t4：系统就一个资源请求问产品（生产 onInterceptRequest 原文）；返回生产给的本地响应，null = 放行。 */
      p.intercept = request => p.lifecycle.webEvent('onInterceptRequest', { request });
      p.releaseUnbind = () => { const due = p.pendingUnbinds.splice(0); for (const run of due) run(); return due.length; };
      p.releaseBlank = () => { const due = p.pendingBlanks.splice(0); for (const run of due) run(); return due.length; };
      p.releaseCommit = () => { const due = p.pendingCommits.splice(0); for (const run of due) run(); return due.length; };
      p.attachNow = () => { p.neverAttach = false; p.holdAttach = false; return p.inst ? attach(p, p.inst) : false; };
      const state = new FakeState();
      state.loggedIn = () => network.tokens.account() !== null;
      state.binding = () => String(network.client.sessionGenerationId());
      p.config = production ? AppBridge.trustedConfig('https://h5.example.test/' + name, false, () => {}, state) :
        AppBridge.trustedConfig('https://h5.example.test/' + name, false, () => {}, state,
          ports && pending !== null ? network.client : null,
          ports && pending !== null ? network.tokens : null, pending);
      // t1：controllerFactory 只在测试要求时给（缺省走生产自己 new 的控制器）；onController 一律记下（产品每绑定一个控制器报一次）。
      if (extra.factory) p.config.controllerFactory = () => { const c = new FakeController(); p.factoryMade.push(c); return c; };
      p.config.onController = c => { p.onControllerCalls.push({ controller: c, attached: c.attached === true, loads: c.loads ? c.loads.length : -1 }); };
      p.config.onDiagnostic = () => {};
      p.lifecycle = Object.assign(new Lifecycle(), { config: p.config, state: reactive(p, new TrustedWebState()),
        registerUiHandlers() {}, watchApplicationState() {}, restoreStatusBar() {} });
      p.lifecycle.aboutToAppear();
      assert.ok(p.lifecycle.transport, 'production lifecycle mounted');
      pages.push(p);
      render(p, true);
      return p;
    }
    async function settled() {
      for (const p of pages.filter(p => !p.closed)) {
        assert.strictEqual(typeof p.config.whenAuthSettled, 'function', 'missing production TrustedWebConfig.whenAuthSettled');
        const completed = await p.config.whenAuthSettled();
        assert.strictEqual(completed, true, 'auth processing completed');
      }
      // t1：每个新 Web 在自己的下一轮事件循环里才挂上，别的页的入口加载可能晚于结算屏障几轮（不拖住其他页，V36）；按轮次等，不按墙钟。
      for (let i = 0; i < 20; i++) await new Promise(resolve => setImmediate(resolve));
    }
    function close(p) {
      p.lifecycle.aboutToDisappear();
      p.closed = true;
      if (p.inst) {
        const inst = p.inst;
        p.inst = null; inst.removed = true; inst.unmounted = true;
        for (const realm of inst.documents) realm.alive = false;
        inst.controller.dead = true;
      }
    }
    /** t1（被登录页压着）：宿主 NavDestination onHidden → 生产 TrustedWebConfig.hostVisible(false)；被压页里新建的 Web 等不到 attach。 */
    function cover(p) {
      assert.strictEqual(typeof p.config.hostVisible, 'function',
        'required production interface: TrustedWebConfig.hostVisible(visible) (host NavDestination onShown / onHidden)');
      p.covered = true; p.holdAttach = true;
      p.config.hostVisible(false);
    }
    function uncover(p) {
      p.covered = false; p.holdAttach = false;
      p.config.hostVisible(true);
      if (p.inst) setImmediate(() => attach(p, p.inst));
    }
    function externalUnchanged() {
      assert.deepStrictEqual(external, { cookie: 'external-cookie', local: 'external-local', cache: 'external-cache', reloads: 0 });
      assert.ok(!trace.some(x => x.endsWith(':true')), 'incognito external profile must not be cleared');
    }
    async function login(account = 'user-b') {
      network.server.handler = () => Promise.resolve(envelope(0, JSON.stringify({ user_id: account,
        is_new_user: false, tokens: JSON.parse(tokenPair('test-access-b', 'test-refresh-b', 'full')) })));
      const result = await network.client.request(new core.ApiRequest('loginBySms', {}, '',
        '{"phone":"13800138000","code":"123456"}'));
      assert.strictEqual(result.code, 0, 'login request succeeds');
      assert.strictEqual(network.tokens.account(), account, 'real ApiClient adopted new owner');
    }
    function logout() { assert.strictEqual(network.client.clearSessionIfEpoch(network.client.loginEpoch()), true); }
    return { network, pages, trace, timeline, controllers, open, resourceRequest, settled, close, cover, uncover, externalUnchanged, login, logout,
      cookieStarted, eventStarted, external, ports, AppBridge, envelope, tokenPair, FakeController,
      BridgeTransport: bindings.exports.BridgeTransport,
      globalCalls: () => [...fixtureGlobals, ...(ports ? ports.globalCalls : [])],
      pageBegin: (p, url) => pageBegin(p, p.inst, url || p.inst.url),
      boot() { return AppBridge.trustedAuth(network.client, network.tokens, pending); },
      holdEvents(promise) { eventGate = promise; },
      failClear(value) { clearFailure = value; },
      holdCookies(promise) { cookieGate = promise; } };
  }
  function eventOnce(p, loggedIn) {
    assert.strictEqual(p.events.length, 1, p.name + ': exactly one event');
    assert.strictEqual(p.events[0].event, 'auth.changed');
    assert.deepStrictEqual(p.events[0].data, { logged_in: loggedIn }, 'exact contract payload, no account/token');
  }
  function reloadedClean(f, p) {
    assert.strictEqual(p.reloads.length, 1, p.name + ': exactly one reload');
    // t6（D10-396）：HTTP 缓存不在切号清理范围（全应用级接口会波及外部 / 隐私页，I6）；可信那一份原样保留，且没有任何缓存清理调用。
    assert.deepStrictEqual(p.reloads[0], { url: p.config.url, cookie: '', local: [], session: [], indexedDB: [], cache: 'old-cache' },
      'all old trusted data absent WHEN reload is entered (HTTP cache is not cleared, D10-396)');
    assert.deepStrictEqual(f.globalCalls(), [], 'D10-396 / I6: no global cache clear (removeCache / removeAllCache) during the switch');
    const n = f.trace.indexOf(p.name + ':notify');
    const r = f.trace.indexOf(p.name + ':reload');
    assert.ok(n >= 0 && r > n, 'A must reach page before B reload');
    for (const kind of ['cookie', 'local']) { // t6：cache 不再清（D10-396）
      assert.ok(f.trace.indexOf('clear:' + kind + ':false') >= 0 &&
        f.trace.indexOf('clear:' + kind + ':false') < r, kind + ' clear precedes reload');
    }
  }
  /**
   * t1（P01 / P02 的顺序断言「拆 → 清 → 载」，I1）：本页切号前的旧 Web 已卸下（onDisAppear）且旧控制器已解绑（17100001）、
   * 清理载体的新 Web 已挂上，都早于第一项清理；每一项清理都早于重载；重载只在一个新控制器上。
   */
  function teardownOrder(f, p, oldController) {
    const at = entry => f.timeline.indexOf(entry);
    const firstClear = f.timeline.findIndex(x => /^(clear|op):(cookie|local|indexedDB|cache)/.test(x));
    assert.ok(firstClear >= 0, 'non-vacuous: storage was cleared');
    const unmounted = at(p.name + ':unmount#' + oldController.id);
    const unbound = at(p.name + ':unbound#' + oldController.id);
    assert.ok(unmounted >= 0 && unmounted < firstClear, p.name + ': old Web unmounted (onDisAppear) before the first clear :: ' + f.timeline.join(' '));
    assert.ok(unbound >= 0 && unbound < firstClear, p.name + ': old controller unbound (17100001) before the first clear');
    const reload = f.timeline.findIndex(x => x.startsWith(p.name + ':reload#'));
    assert.ok(reload > firstClear, p.name + ': reload after clearing');
    const lastClear = f.timeline.reduce((last, x, i) => /^(clear|op):(cookie|local|indexedDB|cache)/.test(x) && i < reload ? i : last, -1);
    for (const kind of ['cookie', 'local']) { // t6：cache 不再清（D10-396）
      const i = f.timeline.findIndex(x => x.startsWith('clear:' + kind) || x.startsWith('op:' + kind + ':entered'));
      assert.ok(i > unbound && i < reload, kind + ': cleared after teardown, before reload');
    }
    assert.ok(lastClear < reload);
    assert.ok(p.reloadControllers.length > 0 && p.reloadControllers.every(c => c !== oldController),
      p.name + ': entry reloaded only on a new controller');
  }
  if (!registerLegacy) return { fixture, core, eventOnce, reloadedClean, teardownOrder, originOf, NOT_ATTACHED, resourceRequest };
  hypium.describe('NativeAuth_FX25', () => {
    hypium.it('C01_existing_current_origin_and_rotated_token_gate_control', 0, () => {
      const f = fixture(); const p = f.open('gate-control');
      const token = p.lifecycle.transport.session.currentToken();
      assert.ok(token.length > 0);
      p.controller.url = 'https://untrusted.example.test/';
      const before = p.scripts.length;
      p.lifecycle.transport.nativeObject.hello();
      p.lifecycle.transport.syncMethods();
      assert.strictEqual(p.scripts.length, before);
      f.externalUnchanged();
    });
    hypium.it('P01_logout_notifies_once_cleans_before_reload_external_untouched', 0, async () => {
      const f = fixture(); const p = f.open('visible');
      const oldToken = p.lifecycle.transport.session.currentToken();
      const oldController = p.controller;
      f.logout(); await f.settled();
      eventOnce(p, false); reloadedClean(f, p); f.externalUnchanged();
      teardownOrder(f, p, oldController); // t1：拆 → 清 → 载
      assert.notStrictEqual(p.lifecycle.transport.session.currentToken(), oldToken, 'new page token');
    });
    hypium.it('P02_login_switch_all_open_pages_including_under_login_and_background', 0, async () => {
      // t1：第二页原名 under-login，URL 路径命中授权页规则，是一个被拒容器（没有 Web）——旧夹具不论有没有 Web 都给它一个永远可用的
      // 控制器，所以它也「重载」了，那是假象。它代表「被登录页压着的普通可信页」，改名 covered，断言不变。
      const f = fixture(); const pages = [f.open('visible'), f.open('covered'), f.open('background')];
      const old = pages.map(p => p.controller);
      // ArkUI 被盖住不触发 aboutToDisappear；所有实例保留，且此后不再调 visible/aboutToAppear。
      await f.login(); await f.settled();
      pages.forEach((p, i) => { eventOnce(p, true); reloadedClean(f, p); teardownOrder(f, p, old[i]); });
      f.externalUnchanged();
    });
    hypium.it('P03_real_token_refresh_has_no_event_clear_or_reload', 0, async () => {
      const f = fixture(); const p = f.open('refresh');
      const epoch = f.network.tokens.loginEpoch();
      f.network.server.handler = () => Promise.resolve(envelope(0, tokenPair('test-access-b', 'test-refresh-b', 'full')));
      const result = await f.network.client.request(new core.ApiRequest('refreshToken', {}, '',
        '{"refresh_token":"test-refresh-a"}'));
      assert.strictEqual(result.code, 0);
      assert.strictEqual(f.network.tokens.loginEpoch(), epoch);
      assert.notStrictEqual(f.network.tokens.accessToken(), 'test-access-a', 'new token actually adopted');
      await f.settled();
      const counts = [p.events.length, p.reloads.length, f.trace.length];
      assert.deepStrictEqual(counts, [0, 0, 0]); f.externalUnchanged();
      assert.strictEqual(p.mounts, 1, 't1: token refresh never tears the Web down');
    });
    hypium.it('P04_same_user_login_new_epoch_notifies_only_and_duplicate_signal_is_deduped', 0, async () => {
      const f = fixture(); const p = f.open('same-user');
      await f.login('user-a'); await f.settled();
      eventOnce(p, true);
      assert.strictEqual(p.reloads.length, 0); assert.deepStrictEqual(f.trace, ['same-user:notify']);
      f.network.client.onSessionChanged(); await f.settled();
      eventOnce(p, true); assert.strictEqual(p.reloads.length, 0);
      assert.strictEqual(p.mounts, 1, 't1: A only never tears the Web down');
    });
    hypium.it('P05_current_untrusted_origin_receives_no_event_or_token', 0, async () => {
      const f = fixture(); const p = f.open('offsite');
      p.controller.url = 'https://untrusted.example.test/';
      const before = p.scripts.length;
      f.logout(); await f.settled();
      const events = p.events.length;
      assert.strictEqual(events, 0);
      // 清理可在原生进行；不能向不可信主框架执行任何携带桥事件或新令牌的脚本。
      for (const script of p.scripts.slice(before)) {
        assert.ok(!script.includes('auth.changed') && !script.includes('__couliBridgeToken'));
      }
    });
    hypium.it('P06_disposed_page_unsubscribes_while_other_page_still_updates', 0, async () => {
      const f = fixture(); const closed = f.open('closed'); const live = f.open('live');
      f.close(closed); await f.login(); await f.settled();
      assert.deepStrictEqual([closed.events.length, closed.reloads.length], [0, 0]);
      eventOnce(live, true); reloadedClean(f, live);
    });
    hypium.it('P08_late_old_document_reply_and_old_token_cannot_reach_new_page', 0, async () => {
      const f = fixture(); const p = f.open('late-reply');
      assert.strictEqual(typeof p.config.whenAuthSettled, 'function', 'missing production TrustedWebConfig.whenAuthSettled');
      const host = p.config.host;
      const oldController = p.controller;
      let release;
      let entered;
      const started = new Promise(resolve => { entered = resolve; });
      const pending = new Promise(resolve => { release = resolve; });
      let calls = 0;
      host.register('app.getEnv', () => { calls++; entered(true); return pending; });
      let dispatchDone;
      const dispatch = host.dispatch.bind(host);
      host.dispatch = (...args) => { dispatchDone = dispatch(...args); return dispatchDone; };
      const token = p.lifecycle.transport.session.currentToken();
      p.lifecycle.transport.nativeObject.post(token, JSON.stringify({ v: 1, id: 'old-call', method: 'app.getEnv', params: {} }));
      assert.strictEqual(await started, true);
      await f.login(); await f.settled();
      // t1：替换文档在新控制器上（旧回复通道跟着旧控制器作废）。
      assert.ok(p.reloadControllers.length > 0 && p.reloadControllers.every(c => c !== oldController), 'replacement document on a new controller');
      release(core.BridgeResult.ok('{"owner":"user-a"}'));
      assert.ok(dispatchDone, 'real BridgeHost.dispatch was entered');
      await dispatchDone;
      const replies = p.executions.filter(x => x.script.includes('old-call'));
      assert.strictEqual(replies.length, 0, 'late old-account reply never reaches replacement document');
      p.lifecycle.transport.nativeObject.post(token, JSON.stringify({ v: 1, id: 'old-token', method: 'app.getEnv', params: {} }));
      const handlerCalls = calls;
      assert.strictEqual(handlerCalls, 1, 'old token is rejected before handler');
    });
    hypium.it('P09_async_cookie_completion_is_required_before_reload', 0, async () => {
      const f = fixture(); const p = f.open('cookie-gate');
      assert.strictEqual(typeof p.config.whenAuthSettled, 'function', 'missing production TrustedWebConfig.whenAuthSettled');
      let release;
      f.holdCookies(new Promise(resolve => { release = resolve; }));
      f.logout();
      const mode = await f.cookieStarted;
      assert.ok(mode === 'sync' || mode === 'async', 'real cookie API entered');
      if (mode === 'async') {
        const reloadsWhilePending = p.reloads.length;
        assert.strictEqual(reloadsWhilePending, 0, 'must await async cookie deletion');
      }
      release(); await f.settled();
      eventOnce(p, false); reloadedClean(f, p);
    });
    hypium.it('P10_event_script_completion_is_required_before_reload', 0, async () => {
      const f = fixture(); const p = f.open('event-gate');
      assert.strictEqual(typeof p.config.whenAuthSettled, 'function', 'missing production TrustedWebConfig.whenAuthSettled');
      let release;
      f.holdEvents(new Promise(resolve => { release = resolve; }));
      f.logout();
      try {
        assert.strictEqual(await f.eventStarted, true, 'real event dispatch entered');
        // 端口都只用 Promise：当前事件循环轮次结算后，错误实现的 fire-and-forget 后续已全部跑完；无墙钟等待。
        const turnCompleted = await new Promise(resolve => setImmediate(() => resolve(true)));
        assert.strictEqual(turnCompleted, true);
        const reloadsWhilePending = p.reloads.length;
        assert.strictEqual(reloadsWhilePending, 0, 'old document must receive A before reload');
        // t1：A 执行完之前旧 Web 不得下树（下树 = 旧文档销毁，A 就送不到了）。
        assert.strictEqual(p.disappears, 0, 'old Web must not be torn down before A has executed');
      } finally { release(); }
      await f.settled();
      eventOnce(p, false); reloadedClean(f, p);
    });
    // t6（D10-396）作废 P11_cache_*×4：切号不再清 HTTP 缓存，这个故障注入点已不存在；「不调用缓存清理」由 reloadedClean /
    // externalUnchanged / 各套 globalCalls 守卫。
    for (const kind of ['cookie', 'local']) {
      for (const permanent of [false, true]) {
        for (const nth of [1, 2]) {
          hypium.it('P11_' + kind + '_' + (permanent ? 'persistent' : 'once') + '_at_' + nth, 0, async () => {
            const f = fixture(); const p = f.open('storage-failure');
            assert.strictEqual(typeof p.config.whenAuthSettled, 'function', 'missing production TrustedWebConfig.whenAuthSettled');
            const fault = { kind, nth, permanent, calls: 0, failed: 0 };
            f.failClear(fault);
            for (let step = 1; step <= nth; step++) {
              p.cookie = 'old-cookie'; p.local.set('owner', 'old-user'); p.sessionStorage.set('owner', 'old-user');
              p.indexedDB.set('owner', 'old-user'); p.cache = 'old-cache';
              const before = p.reloads.length;
              await f.login('user-step-' + step);
              let completed;
              try { completed = await p.config.whenAuthSettled(); } catch (_error) { completed = false; }
              assert.strictEqual(typeof completed, 'boolean', 'failed attempt still has an observable completion');
              if (step < nth) assert.strictEqual(completed, true, 'before fault boundary');
              if (step === nth) assert.ok(fault.failed > 0, 'fault actually injected at real storage API');
              if (step === nth && permanent) assert.strictEqual(p.reloads.length, before, 'failed clear must not reload');
            }
            f.failClear(null);
            await f.login('user-recovered'); await f.settled();
            assert.ok(p.reloads.length > 0, 'next real identity change can recover');
            for (const reload of p.reloads) {
              assert.deepStrictEqual([reload.cookie, reload.local, reload.session, reload.indexedDB, reload.cache],
                ['', [], [], [], 'old-cache'], 'every reload sees only cleared storage, including recovery (HTTP cache kept, D10-396)');
            }
            // 恢复后再失败：不把第一次成功记成永久已清理。
            const repeatedFault = { kind, nth: 1, permanent: true, calls: 0, failed: 0 };
            f.failClear(repeatedFault);
            p.cookie = 'new-dirty-cookie'; p.local.set('owner', 'new-dirty-user'); p.cache = 'new-dirty-cache';
            const afterRecovery = p.reloads.length;
            await f.login('user-fails-again');
            let failedCompleted;
            try { failedCompleted = await p.config.whenAuthSettled(); } catch (_error) { failedCompleted = false; }
            assert.strictEqual(failedCompleted, false);
            assert.ok(repeatedFault.failed > 0, 'recovered binding still attempts later cleanup');
            const afterFailure = p.reloads.length;
            assert.strictEqual(afterFailure, afterRecovery);
            f.externalUnchanged();
          });
        }
      }
    }
    hypium.it('P12_rotated_token_is_not_delivered_to_departing_document_on_auth_change', 0, async () => {
      const f = fixture(); const p = f.open('rotating');
      const transport = p.lifecycle.transport;
      const oldToken = transport.session.currentToken();
      transport.navigationStarted('https://h5.example.test/next-document');
      const pendingToken = transport.session.currentToken();
      assert.notStrictEqual(pendingToken, oldToken);
      const before = p.executions.length;
      f.logout(); await f.settled();
      const departing = p.executions.slice(before).filter(x => x.document === 1);
      assert.ok(!departing.some(x => x.script.includes('auth.changed') || x.script.includes(pendingToken)),
        'navigation has rotated the token but old document must receive neither the auth event nor new token');
      f.externalUnchanged();
    });
    hypium.it('P07_no_delivered_token_does_not_send_to_departing_document', 0, async () => {
      const f = fixture(); const p = f.open('not-started', false);
      f.logout(); await f.settled();
      // 冷文档没有令牌，不能用新令牌向它发事件；可在新文档开始后补投。
      const oldDocumentEvents = p.executions.filter(x => x.document === 1 && x.script.includes('auth.changed'));
      assert.strictEqual(oldDocumentEvents.length, 0, 'never deliver auth event to a document without its own token');
      f.externalUnchanged();
    });
  });
};
