// F-X-24 B12：由 bridge-disabled-methods-test.js 注册。执行真实原生订阅、生命周期、传输与启动脚本。
// SDK AST 只抽取不能在 Node 初始化的 UI 文件中的声明 / 生命周期原文，不重写推送逻辑。
// 假控制器只记脚本并投递到当前 VM 主框架；UI 绘制 / 系统 API 的真机行为仍需设备验收。
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

module.exports = function registerNativePushTests({ root, ts, tsDir, hypium, pageFor }) {
  // 与仓库 hm10-scan.js 相同的 SDK 解析选项，支持 ArkUI 组件尾随闭包。
  const loader = path.resolve(tsDir, '../..');
  const config = ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile).config;
  assert.ok(config && config.compilerOptions.ets, 'SDK ETS parser configuration required');
  const options = { ets: config.compilerOptions.ets, etsLoaderPath: loader };
  function sourceFile(relative) {
    const filename = path.join(root, relative);
    const ast = ts.createSourceFile(filename, fs.readFileSync(filename, 'utf8'),
      ts.ScriptTarget.ES2021, true, ts.ScriptKind.ETS, options);
    assert.strictEqual(ast.parseDiagnostics.length, 0, relative + ' must parse');
    return ast;
  }

  function named(nodes, name) {
    const matches = nodes.filter(node => node.name && node.name.getText() === name);
    assert.strictEqual(matches.length, 1, 'exactly one product declaration: ' + name);
    return matches[0];
  }

  const web = sourceFile('features/web/src/main/ets/TrustedWebView.ets');
  const app = sourceFile('entry/src/main/ets/web/AppBridge.ets');
  const view = named(web.statements, 'TrustedWebView');
  const appBridge = named(app.statements, 'AppBridge');
  const declarations = ['BridgeEnvInfo', 'TrustedWebConfig', 'BridgeNativeObject', 'randomToken',
    'monotonicMillis', 'BridgeTransport'].map(name => named(web.statements, name).getText(web));
  // 只绕开 ArkUI 的 struct 绘制 / 装饰器；两个生命周期与 trustedConfig 方法体逐字来自产品。
  declarations.push('export class Lifecycle {\n' + ['aboutToAppear', 'aboutToDisappear']
    .map(name => named(view.members, name).getText(web)).join('\n') + '\n}');
  declarations.push('export class AppBridge {\n' +
    named(appBridge.members, 'trustedConfig').getText(app) + '\n}');
  const compiled = ts.transpileModule(declarations.join('\n'), {
    fileName: 'Fx24NativeProductSlice.ts',
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const core = require(path.join(root, 'common/core/Index.ets'));
  const { FakeState } = require(path.join(root, 'common/core/src/test/BridgeHost.test.ets'));
  const { ConfigReply } = require(path.join(root, 'common/core/src/main/ets/clientcore/ConfigStore.ets'));

  function nativePage(start = true) {
    const p = pageFor('[]');
    const scripts = [];
    const controller = {
      url: 'https://h5.example.test/current',
      unavailable: false,
      getUrl() {
        if (this.unavailable) throw new Error('controller not ready');
        return this.url;
      },
      runJavaScript(script) {
        scripts.push({ url: this.url, script });
        vm.runInContext(script, p.context);
        return Promise.resolve('');
      },
      stop() {}
    };
    let tokenSequence = 0;
    const bindings = {
      exports: {},
      util: { generateRandomUUID: () => (++tokenSequence).toString(16).padStart(32, '0') },
      systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 1000000 },
      AppClientCore: { shared: { config: p.config.store } }
    };
    for (const name of ['BridgeCaller', 'BridgeFrames', 'BridgeGesture', 'BridgePageSession',
      'BridgeReplyChannel', 'BridgeHost', 'OriginRules', 'TrustedNavPolicy']) {
      bindings[name] = core[name];
    }
    vm.runInNewContext(compiled, bindings);
    const { AppBridge, Lifecycle, BridgeEnvInfo } = bindings.exports;
    // App 组合的外围依赖；watchMethods 订阅来自整个真实 trustedConfig 方法。
    Object.assign(AppBridge, {
      nextContainerId: () => 'fx24-native-test',
      createHost: () => p.host,
      envInfo: () => new BridgeEnvInfo('1.0.0', '1', 'test', 'test'),
      containers: new Map()
    });
    const config = AppBridge.trustedConfig(controller.url, false, () => {}, new FakeState());
    config.controller = controller;
    config.onDiagnostic = () => {};
    const lifecycle = Object.assign(new Lifecycle(), {
      config, controller, state: {}, transport: null, appListener: null,
      registerUiHandlers() {}, watchApplicationState() {}, restoreStatusBar() {}
    });
    lifecycle.aboutToAppear();
    const transport = lifecycle.transport;
    assert.ok(transport, 'real lifecycle must create BridgeTransport');
    p.window.__couliBridgeNative = lifecycle.nativeObject;
    if (start) transport.pageStarted();
    return { ...p, controller, scripts, lifecycle, transport };
  }

  function capture(script) {
    const methods = [];
    const tokens = [];
    vm.runInNewContext(script, { window: {
      __couliBridgeToken: token => tokens.push(token),
      __couliBridgeMethods: (token, list) => methods.push({ token, list: Array.from(list) })
    } });
    return { methods, tokens };
  }

  function assertUpdate(p, index) {
    const record = p.scripts[index];
    assert.ok(record, 'native must send methods to current page');
    assert.strictEqual(record.url, p.controller.url);
    const sent = capture(record.script);
    assert.strictEqual(sent.methods.length, 1, 'one methods update per script');
    assert.strictEqual(sent.methods[0].token, p.transport.session.currentToken());
    assert.ok(sent.methods[0].token.length >= 16, 'nonempty current native token');
    assert.deepStrictEqual(sent.methods[0].list, p.host.supportedMethods());
    return sent;
  }

  hypium.describe('BridgeNativePush_FX24', () => {
    hypium.it('B12_config_watch_pushes_current_token_and_real_sdk_has_recovers', 0, () => {
      const p = nativePage();
      assert.strictEqual(p.scripts.length, 1);
      assert.ok(p.has('clipboard.write'));
      const bridge = p.window.__REBATE_BRIDGE__;
      p.config.apply('["clipboard.write"]', 'disabled');
      assert.strictEqual(p.scripts.length, 2, 'config watcher must send a native update');
      assertUpdate(p, 1);
      assert.strictEqual(p.has('clipboard.write'), null);
      assert.ok(p.has('app.getEnv'));
      p.config.apply('[]', 'restored');
      assert.strictEqual(p.scripts.length, 3);
      assertUpdate(p, 2);
      assert.ok(p.has('clipboard.write'));
      assert.strictEqual(p.window.__REBATE_BRIDGE__, bridge, 'same open page and SDK instance');
      p.lifecycle.aboutToDisappear();
    });

    hypium.it('B12_unchanged_list_on_successful_config_refresh_sends_nothing', 0, () => {
      const p = nativePage();
      p.config.apply('["clipboard.write"]', 'disabled');
      const before = p.scripts.length;
      // 只更新其他配置（dict_version）；有效禁用名单与 supportedMethods 都不变。
      p.config.apply('["clipboard.write"]', 'other-config-changed');
      assert.strictEqual(p.scripts.length, before, 'unchanged methods must not be sent again');
      assert.strictEqual(p.has('clipboard.write'), null);
      p.lifecycle.aboutToDisappear();
    });

    hypium.it('B12_unchanged_list_on_304_sends_nothing', 0, () => {
      const p = nativePage();
      const before = p.scripts.length;
      p.config.reply(new ConfigReply(ConfigReply.NOT_MODIFIED, null, null));
      assert.strictEqual(p.scripts.length, before, '304 does not change methods');
      assert.ok(p.has('clipboard.write'));
      p.lifecycle.aboutToDisappear();
    });

    hypium.it('B12_failed_refresh_sends_nothing', 0, () => {
      const p = nativePage();
      const before = p.scripts.length;
      p.config.reply(new ConfigReply(ConfigReply.FAILURE, null, null));
      assert.strictEqual(p.scripts.length, before);
      p.lifecycle.aboutToDisappear();
    });

    hypium.it('B12_current_untrusted_page_receives_neither_methods_nor_token', 0, () => {
      const p = nativePage();
      const before = p.scripts.length;
      // 创建时可信，通知时已离开；必须读取当前控制器 URL，不能缓存最初的可信结论。
      p.controller.url = 'https://untrusted.example.test/current';
      p.config.apply('["clipboard.write"]', 'disabled-offsite');
      p.transport.nativeObject.hello();
      p.transport.pageStarted();
      assert.strictEqual(p.scripts.length, before, 'untrusted page must receive no script');
      p.lifecycle.aboutToDisappear();
    });

    hypium.it('B12_no_token_defers_until_page_start_then_sends_latest_methods', 0, () => {
      const p = nativePage(false);
      p.config.apply('["clipboard.write"]', 'disabled-before-page-start');
      assert.strictEqual(p.scripts.length, 0);
      assert.ok(p.has('clipboard.write'), 'injected snapshot is still old');
      p.transport.pageStarted();
      assert.strictEqual(p.scripts.length, 1);
      const sent = assertUpdate(p, 0);
      assert.deepStrictEqual(sent.tokens, [p.transport.session.currentToken()]);
      assert.strictEqual(p.has('clipboard.write'), null);
      p.lifecycle.aboutToDisappear();
    });

    hypium.it('B12_rotated_token_defers_config_push_until_new_page_receives_latest_methods', 0, () => {
      const p = nativePage();
      try {
        assert.strictEqual(p.scripts.length, 1);
        const initial = assertUpdate(p, 0);
        const previousToken = p.transport.session.currentToken();
        assert.deepStrictEqual(initial.tokens, [previousToken], 'current document already received its token');
        assert.ok(p.has('clipboard.write'));
        const before = p.scripts.length;
        const nextUrl = 'https://h5.example.test/other';

        // 放行导航时令牌已换，控制器仍指向旧文档；此时即使名单变化，也不能推新令牌的脚本。
        p.transport.navigationStarted(nextUrl);
        const pendingToken = p.transport.session.currentToken();
        assert.notStrictEqual(pendingToken, previousToken);
        assert.ok(pendingToken.length >= 16);
        assert.strictEqual(p.scripts.length, before, 'navigation has not delivered the new token');
        p.config.apply('["clipboard.write"]', 'disabled-between-navigation-and-page-start');
        const latest = initial.methods[0].list.filter(method => method !== 'clipboard.write');
        assert.deepStrictEqual(p.host.supportedMethods(), latest, 'effective methods really changed');
        assert.strictEqual(p.scripts.length, before, 'new token must not be pushed into the departing document');
        assert.ok(p.has('clipboard.write'), 'departing document still has its old list');

        p.controller.url = nextUrl;
        p.transport.pageStarted();
        assert.strictEqual(p.scripts.length, before + 1, 'page start sends exactly one combined script');
        const sent = assertUpdate(p, before);
        assert.notStrictEqual(sent.methods[0].token, previousToken);
        assert.deepStrictEqual(sent.tokens, [sent.methods[0].token]);
        assert.deepStrictEqual(sent.methods[0].list, latest);
        assert.strictEqual(p.has('clipboard.write'), null);
        assert.ok(p.has('app.getEnv'));
      } finally {
        p.lifecycle.aboutToDisappear();
      }
    });

    hypium.it('B12_same_document_anchor_and_push_state_send_latest_methods_after_config_change', 0, () => {
      for (const kind of ['anchor', 'pushState']) {
        const p = nativePage();
        try {
          const bridge = p.window.__REBATE_BRIDGE__;
          const initial = assertUpdate(p, 0);
          const token = p.transport.session.currentToken();
          p.config.apply('["clipboard.write"]', 'disabled-before-' + kind);
          const latest = initial.methods[0].list.filter(method => method !== 'clipboard.write');
          assert.deepStrictEqual(p.host.supportedMethods(), latest);
          const before = p.scripts.length;
          const target = kind === 'anchor' ? p.controller.url + '#details' :
            'https://h5.example.test/current?tab=details';
          // 锚点经过放行判断；pushState 直接提交同文档记录，两者都没有 pageStarted。
          if (kind === 'anchor') p.transport.navigationStarted(target);
          p.controller.url = target;
          p.transport.sameDocumentCommitted();

          assert.strictEqual(p.scripts.length, before + 1, kind + ' commit must resend the latest list');
          const sent = assertUpdate(p, before);
          assert.deepStrictEqual(sent.tokens, [token], kind + ' keeps the same document token');
          assert.strictEqual(sent.methods[0].token, token);
          assert.deepStrictEqual(sent.methods[0].list, latest);
          assert.strictEqual(p.has('clipboard.write'), null);
          assert.ok(p.has('app.getEnv'));
          assert.strictEqual(p.window.__REBATE_BRIDGE__, bridge, 'same document and SDK instance');
        } finally {
          p.lifecycle.aboutToDisappear();
        }
      }
    });

    hypium.it('B12_next_current_page_gets_new_token_and_latest_list_even_when_unchanged', 0, () => {
      const p = nativePage();
      const previousToken = p.transport.session.currentToken();
      p.controller.url = 'https://h5.example.test/next';
      p.transport.pageStarted();
      assert.strictEqual(p.scripts.length, 2, 'new page still needs its initial methods');
      const sent = assertUpdate(p, 1);
      assert.notStrictEqual(sent.methods[0].token, previousToken);
      assert.deepStrictEqual(sent.tokens, [sent.methods[0].token]);
      p.config.apply('["clipboard.write"]', 'disabled-on-next-page');
      assert.strictEqual(p.scripts.length, 3);
      assertUpdate(p, 2);
      assert.strictEqual(p.has('clipboard.write'), null);
      p.lifecycle.aboutToDisappear();
    });

    hypium.it('B12_unavailable_controller_receives_nothing_then_hello_catches_up', 0, () => {
      const p = nativePage();
      const before = p.scripts.length;
      p.controller.unavailable = true;
      p.config.apply('["clipboard.write"]', 'disabled-controller-not-ready');
      assert.strictEqual(p.scripts.length, before);
      p.controller.unavailable = false;
      p.transport.nativeObject.hello();
      assert.strictEqual(p.scripts.length, before + 1);
      assertUpdate(p, before);
      assert.strictEqual(p.has('clipboard.write'), null);
      p.lifecycle.aboutToDisappear();
    });

    hypium.it('B12_disappear_unsubscribes_config_and_invalidates_token', 0, () => {
      const p = nativePage();
      let notices = 0;
      const sync = p.transport.syncMethods.bind(p.transport);
      p.transport.syncMethods = () => { notices++; sync(); };
      p.config.apply('["clipboard.write"]', 'before-disappear');
      assert.strictEqual(notices, 1, 'subscription was active');
      p.lifecycle.aboutToDisappear();
      assert.strictEqual(p.transport.session.currentToken(), '');
      const before = p.scripts.length;
      p.config.apply('[]', 'after-disappear');
      assert.strictEqual(notices, 1, 'no callback after unsubscribe');
      assert.strictEqual(p.scripts.length, before);
    });
  });
};
