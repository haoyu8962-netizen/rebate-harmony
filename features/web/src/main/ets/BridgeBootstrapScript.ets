/**
 * 随 App 版本发布的桥启动脚本（03 §5.2「启动脚本在 document start 注入」；CSB-10：可信容器只注入这一份随包脚本，
 * 不接受运营配置或接口下发的脚本）。只由 TrustedWebView 经 javaScriptOnDocumentStart 注入，scriptRules 只放可信 origin；
 * ExternalWebView 不引用本文件。
 *
 * 定义 window.__REBATE_BRIDGE__ = { version, methods, postMessage, subscribe }（packages/bridge-sdk 的 BridgeTransport）：
 * - methods 是本端按契约声明的方法（BridgeHost.supportedMethods：since.harmony 不为 null；暂未实现的调用回 90001），
 *   H5 的 has() 只认它；
 * - 主框架令牌（R1-01）：只在顶层 frame 定义只读的 window.__couliBridgeToken(token)，原生只经 runJavaScript（主框架）调用它；
 *   令牌留在闭包里，页面读不到。脚本最后调 __couliBridgeNative.hello() 请原生送令牌（代理对象还没就绪时由原生在页面加载
 *   完成时补送）；拿到令牌之前的调用先排队，拿到后按顺序发出；
 * - postMessage 把 (令牌, 信封) 交给原生代理对象 __couliBridgeNative.post（javaScriptProxy），返回的 Promise 由原生用
 *   window.__couliBridgeReceive(响应 JSON) 兑现；事件同一入口，按 event 字段分发给 subscribe 的监听者；
 * - 只在顶层 frame 定义（子框架即使拿到代理对象直接调用，没有令牌，原生按子框架拒绝，见 BridgeFrames）。
 * - 在途 id（R2-07）：pending 用 Map 保存每个合法 id 的 resolve；同一 id 还在途时，后一次调用不发送、不覆盖原 pending，
 *   直接以 90002（信封不合法）兑现，与原生宿主的「重复在途 id」口径一致。
 * 脚本里不放任何令牌、配置或地址；__COULI_METHODS__ 在注入前替换为方法名数组的 JSON，__COULI_DUPLICATE_CODE__ /
 * __COULI_DUPLICATE_MSG__ 替换为 90002 与契约 errors 里的说明。
 */
export const BRIDGE_METHODS_PLACEHOLDER: string = '__COULI_METHODS__';

export const BRIDGE_BOOTSTRAP_TEMPLATE: string = `(function () {
  'use strict';
  if (window.top !== window || window.__REBATE_BRIDGE__) { return; }
  var methods = __COULI_METHODS__;
  var duplicateCode = __COULI_DUPLICATE_CODE__;
  var duplicateMsg = __COULI_DUPLICATE_MSG__;
  var pending = new Map();
  var listeners = [];
  var token = null;
  var queue = [];
  function nativeObj() {
    var n = window.__couliBridgeNative;
    return n && typeof n.post === 'function' ? n : null;
  }
  function send(text) {
    var n = nativeObj();
    if (!n) { return false; }
    n.post(token, text);
    return true;
  }
  function setToken(value) {
    if (typeof value !== 'string' || value.length === 0) { return; }
    token = value;
    var waiting = queue;
    queue = [];
    waiting.forEach(function (text) { send(text); });
  }
  function receive(text) {
    var msg;
    try { msg = JSON.parse(text); } catch (e) { return; }
    if (!msg || typeof msg !== 'object') { return; }
    if (typeof msg.event === 'string') {
      listeners.slice().forEach(function (l) { try { l(msg); } catch (e) {} });
      return;
    }
    if (typeof msg.id === 'string' && pending.has(msg.id)) {
      var resolve = pending.get(msg.id);
      pending.delete(msg.id);
      resolve(msg);
    }
  }
  Object.defineProperty(window, '__couliBridgeReceive', { value: receive, writable: false, configurable: false });
  Object.defineProperty(window, '__couliBridgeToken', { value: setToken, writable: false, configurable: false });
  var bridge = {
    version: 1,
    methods: Object.freeze(methods.slice()),
    postMessage: function (request) {
      return new Promise(function (resolve, reject) {
        var text;
        try { text = JSON.stringify(request); } catch (e) { reject(e); return; }
        if (!nativeObj()) { reject(new Error('bridge unavailable')); return; }
        var id = request && typeof request.id === 'string' ? request.id : null;
        if (id !== null) {
          if (pending.has(id)) {
            resolve({ id: id, code: duplicateCode, msg: duplicateMsg });
            return;
          }
          pending.set(id, resolve);
        }
        if (token === null) { queue.push(text); } else { send(text); }
      });
    },
    subscribe: function (listener) {
      if (typeof listener !== 'function') { return function () {}; }
      listeners.push(listener);
      return function () {
        var i = listeners.indexOf(listener);
        if (i >= 0) { listeners.splice(i, 1); }
      };
    }
  };
  Object.defineProperty(window, '__REBATE_BRIDGE__', { value: Object.freeze(bridge), writable: false, configurable: false });
  try { var n = window.__couliBridgeNative; if (n && typeof n.hello === 'function') { n.hello(); } } catch (e) {}
})();`;

export const BRIDGE_DUPLICATE_CODE_PLACEHOLDER: string = '__COULI_DUPLICATE_CODE__';
export const BRIDGE_DUPLICATE_MSG_PLACEHOLDER: string = '__COULI_DUPLICATE_MSG__';

/** 填入方法名与「重复在途 id」的错误体（90002 与契约 errors 里的 msg）后的脚本。 */
export function bridgeBootstrapScript(methods: string[], duplicateCode: number, duplicateMsg: string): string {
  return BRIDGE_BOOTSTRAP_TEMPLATE.replace(BRIDGE_METHODS_PLACEHOLDER, JSON.stringify(methods))
    .replace(BRIDGE_DUPLICATE_CODE_PLACEHOLDER, JSON.stringify(duplicateCode))
    .replace(BRIDGE_DUPLICATE_MSG_PLACEHOLDER, JSON.stringify(duplicateMsg));
}
