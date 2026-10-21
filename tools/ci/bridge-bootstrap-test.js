#!/usr/bin/env node
// 桥启动脚本的执行测试（APP-04 R2-07）：从 features/web/src/main/ets/BridgeBootstrapScript.ets 取出随包脚本原文，
// 按 bridgeBootstrapScript 的方式填入占位符，在 node 的 vm 沙箱里用假的 window 与原生代理对象执行，验证 H5 侧真实行为。
// Hypium 本机单测跑不了页面脚本（ArkTS 不能执行字符串代码），所以由 verify.sh 用 DevEco 自带的 node 跑本文件。
// 用法：node tools/ci/bridge-bootstrap-test.js [仓库根]；全部通过退出 0，否则 1。
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = process.argv[2] || path.resolve(__dirname, '..', '..');
const source = fs.readFileSync(path.join(root, 'features/web/src/main/ets/BridgeBootstrapScript.ets'), 'utf8');
const match = source.match(/export const BRIDGE_BOOTSTRAP_TEMPLATE: string = `([\s\S]*?)`;/);
if (!match) {
  console.error('找不到 BRIDGE_BOOTSTRAP_TEMPLATE');
  process.exit(1);
}
const DUPLICATE_CODE = 90002;
const DUPLICATE_MSG = 'invalid params';
// 测试用假令牌：运行时按位置拼出 32 位十六进制（升序 0..f 两遍 / 降序 f..0 两遍），不在源码里写字面量。
function fakeHexToken(descending) {
  return Array.from({ length: 32 }, (_, i) => (descending ? 15 - (i % 16) : i % 16).toString(16)).join('');
}
const PAGE_TOKEN = fakeHexToken(false);

function script(methods) {
  return match[1]
    .replace('__COULI_METHODS__', JSON.stringify(methods))
    .replace('__COULI_DUPLICATE_CODE__', JSON.stringify(DUPLICATE_CODE))
    .replace('__COULI_DUPLICATE_MSG__', JSON.stringify(DUPLICATE_MSG));
}

/** 一个装好启动脚本的主框架页面；native.sent 记下原生收到的 (token, 信封)。 */
function page() {
  const sent = [];
  const native = {
    post(token, text) { sent.push({ token, text }); },
    hello() {}
  };
  const window = { __couliBridgeNative: native };
  window.top = window;
  const context = vm.createContext({ window, JSON, Object, Promise, Map, Error });
  vm.runInContext(script(['clipboard.write', 'app.getEnv']), context);
  window.__couliBridgeToken(PAGE_TOKEN);
  return { window, sent, reply: (body) => window.__couliBridgeReceive(JSON.stringify(body)) };
}

const flush = () => new Promise((resolve) => setImmediate(resolve));
const results = [];

async function test(name, run) {
  try {
    await run();
    results.push(['PASS', name]);
  } catch (e) {
    results.push(['FAIL', name + '：' + (e && e.message ? e.message : String(e))]);
  }
}

function assertEqual(actual, expected, what) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) {
    throw new Error(what + ' 期望 ' + b + '，实际 ' + a);
  }
}

(async () => {
  await test('r2_07_duplicate_in_flight_id_answers_90002_without_sending_or_stealing_first', async () => {
    const p = page();
    const bridge = p.window.__REBATE_BRIDGE__;
    const settled = [];
    const first = bridge.postMessage({ v: 1, id: 'dup', method: 'clipboard.write', params: { text: 'a' } });
    first.then((r) => settled.push(['first', r.code]));
    const second = bridge.postMessage({ v: 1, id: 'dup', method: 'clipboard.write', params: { text: 'b' } });
    second.then((r) => settled.push(['second', r.code]));
    await flush();
    // 后一次不发送、立刻得到 90002；前一次仍在途。
    assertEqual(p.sent.length, 1, '原生收到的调用数');
    assertEqual(settled, [['second', DUPLICATE_CODE]], '兑现顺序');
    const secondReply = await second;
    assertEqual([secondReply.id, secondReply.code, secondReply.msg], ['dup', DUPLICATE_CODE, DUPLICATE_MSG], '后一次的响应');
    // 原生对前一次的成功响应交给前一次。
    p.reply({ id: 'dup', code: 0, msg: 'ok', data: {} });
    await flush();
    assertEqual(settled, [['second', DUPLICATE_CODE], ['first', 0]], '兑现顺序');
    // 原生即使对重复 id 回 90002（宿主口径），也不会兑现到已结束的调用上。
    p.reply({ id: 'dup', code: DUPLICATE_CODE, msg: DUPLICATE_MSG });
    await flush();
    assertEqual(settled.length, 2, '兑现次数');
  });

  await test('r2_07_id_reusable_after_reply_and_prototype_names_are_plain_ids', async () => {
    const p = page();
    const bridge = p.window.__REBATE_BRIDGE__;
    for (const id of ['__proto__', 'constructor', 'hasOwnProperty', 'x']) {
      const call = bridge.postMessage({ v: 1, id, method: 'app.getEnv', params: {} });
      await flush();
      p.reply({ id, code: 0, msg: 'ok', data: {} });
      assertEqual((await call).code, 0, id + ' 第一次');
      const again = bridge.postMessage({ v: 1, id, method: 'app.getEnv', params: {} });
      await flush();
      p.reply({ id, code: 0, msg: 'ok', data: {} });
      assertEqual((await again).code, 0, id + ' 应答后可再用');
    }
    assertEqual(p.sent.length, 8, '原生收到的调用数');
  });

  await test('fx24_open_page_methods_change_only_with_current_token_and_can_recover', () => {
    const p = page();
    const bridge = p.window.__REBATE_BRIDGE__;
    const enabled = ['clipboard.write', 'app.getEnv'];
    const disabled = ['app.getEnv'];
    assertEqual(bridge.methods, enabled, '已打开页面的初始列表');

    p.window.__couliBridgeMethods(undefined, disabled);
    assertEqual(bridge.methods, enabled, '没有令牌不能禁用能力');
    p.window.__couliBridgeMethods('wrong-token', disabled);
    assertEqual(bridge.methods, enabled, '错误令牌不能禁用能力');
    p.window.__couliBridgeMethods(PAGE_TOKEN, disabled);
    assertEqual(bridge.methods, ['app.getEnv'], '正确令牌更新同一页面的列表');
    assertEqual(Object.isFrozen(bridge.methods), true, '更新后的列表仍冻结');
    disabled.push('clipboard.write');
    assertEqual(bridge.methods, ['app.getEnv'], '修改传入数组不能改回页面列表');

    // 换过令牌后，旧令牌也不能恢复能力；不重建页面或重新注入脚本。
    const nextToken = fakeHexToken(true);
    p.window.__couliBridgeToken(nextToken);
    p.window.__couliBridgeMethods(PAGE_TOKEN, enabled);
    assertEqual(bridge.methods, ['app.getEnv'], '旧令牌不能恢复能力');
    p.window.__couliBridgeMethods(nextToken, enabled);
    assertEqual(bridge.methods, enabled, '当前令牌恢复被移出禁用名单的能力');
    assertEqual(Object.isFrozen(bridge.methods), true, '恢复后的列表仍冻结');
    assertEqual(p.window.__REBATE_BRIDGE__ === bridge, true, '仍是同一个页面桥对象');
  });

  for (const [state, name] of results) {
    console.log(state + ' ' + name);
  }
  const failed = results.filter((r) => r[0] !== 'PASS').length;
  console.log('bridge-bootstrap-test：' + (results.length - failed) + ' 过 / ' + failed + ' 不过');
  process.exit(failed === 0 && results.length > 0 ? 0 : 1);
})();
