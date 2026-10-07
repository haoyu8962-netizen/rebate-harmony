// APP-04 鸿蒙第 1 轮评审（harmony-review-r1.md）的回归测试：每条都复现原场景，撤掉修复后对应用例失败。
// R1-01 主框架令牌（同地址 iframe、sandbox iframe）；R1-03 桥白名单只来自验签通过的 bridge_origins；R1-04 异步等待后复核；
// R1-05 只认原生识别的有效点击；R1-06 BELOW_MIN 只申请 read_only；R1-07 授权页隔离；R1-08 商品回流意图；R1-11 系统返回；
// R1-12 nav_host 抽样。R1-10 在 RouterBehavior.test（external_hosts_only_limit_deeplink_entry_r1_10）；R1-02、R1-09、R1-11 的
// 接线另由 verify.sh 的 release-scan 与 lint 违反样例（HM-LINT-7、HM-LINT-8）覆盖。APP-03b 共性 27 在本文件末尾。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiRequest, ApiResult, AuthPageRules, BridgeCall, BridgeCaller, BridgeFrames, BridgeGesture,
  BridgeHandlers, BridgeHost, BridgeJson, BridgeOrigins, BridgeOriginsVerifier, BridgePageSession, BridgeResult,
  BridgeTouchKind, ConfigLayers, ExternalNavDecision, ExternalNavFrame, ExternalNavHooks, ExternalNavOutcome,
  ExternalNavPolicy, ExternalNoticeKey, ExternalPageNavigator, ExternalUnionOutcome, PendingContractBridgeOriginsVerifier,
  RegisteredDomain, TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState, WebBackPolicy
} from '../../Index';
import { apiResult, FakeState, flush, MAIN_TAP, ManualClock, req, wire } from './BridgeHost.test';
import { RegistryRig, SIGN_SECRET, registered } from './ClientCoreIntegration.test';
import { Deferred, envelope } from './NetworkTestRig';

const PAGE_URL: string = 'https://h5.example.test/rules/index.html';
const TOKEN_A: string = '0123456789abcdef0123456789abcdef';
const TOKEN_B: string = 'fedcba9876543210fedcba9876543210';
const RULES: string = '{"version":"r1","rules":[{"platform":"taobao","category":"union_host","hosts":' +
  '["taobao.example.test"],"path_patterns":[]},{"platform":"taobao","category":"product","hosts":' +
  '["item.taobao.example.test"],"path_patterns":["^/item$"]}]}';

class TokenSource {
  values: string[];

  constructor(values: string[]) {
    this.values = values;
  }

  next(): string {
    return this.values.length > 1 ? this.values.shift() as string : this.values[0];
  }
}

function sessionWith(values: string[]): BridgePageSession {
  const source: TokenSource = new TokenSource(values);
  return new BridgePageSession((): string => source.next());
}

/** 按层的配置替身。 */
class FakeLayers implements ConfigLayers {
  readonly values: Map<string, string> = new Map<string, string>();

  set(source: string, key: string, json: string): FakeLayers {
    this.values.set(source + '/' + key, json);
    return this;
  }

  layerValue(source: string, key: string): string | null {
    return this.values.get(source + '/' + key) ?? null;
  }
}

/** 只认带 "signed":true 的层（测试用的验签替身）。 */
class StubVerifier implements BridgeOriginsVerifier {
  verifySigned(valueJson: string): string[] | null {
    const v: Record<string, Object> = JSON.parse(valueJson) as Record<string, Object>;
    return v['signed'] === true ? v['origins'] as string[] : null;
  }

  trustBundled(valueJson: string): string[] | null {
    const v: Record<string, Object> = JSON.parse(valueJson) as Record<string, Object>;
    const origins: Object | undefined = v['origins'];
    return origins === undefined ? null : origins as string[];
  }
}

class HookLog {
  dispatched: string[] = [];
  union: string[] = [];
  blocked: string[] = [];
  navHosts: string[] = [];
}

function navigatorWith(log: HookLog, intercept: boolean, handled: boolean, bp: number = 0,
  roll: number = 0.5): ExternalPageNavigator {
  const hooks: ExternalNavHooks = new ExternalNavHooks();
  hooks.productIntercept = (): boolean => intercept;
  hooks.dispatchProduct = (url: string): boolean => {
    log.dispatched.push(url);
    return handled;
  };
  hooks.unionHost = (decision: ExternalNavDecision, frame: string, outcome: string): void => {
    log.union.push((decision.rule === null ? '-' : decision.rule.category) + ' ' + frame + ' ' + outcome);
  };
  hooks.blockedNav = (kind: string, frame: string): void => {
    log.blocked.push(kind + ' ' + frame);
  };
  hooks.navHost = (domain: string, frame: string, hit: boolean): void => {
    log.navHosts.push(domain + ' ' + frame + ' ' + hit);
  };
  hooks.sampleBp = (): number => bp;
  hooks.random = (): number => roll;
  return new ExternalPageNavigator(new ExternalNavPolicy(RULES), (): string | null => RULES, hooks);
}

function outcomeText(o: ExternalNavOutcome): string {
  return (o.cancel ? 'cancel' : 'load') + ' ' + (o.notice ?? '-');
}

function tap(g: BridgeGesture, at: number): void {
  g.touch(BridgeTouchKind.DOWN, 50, 50, 1, at);
  g.touch(BridgeTouchKind.UP, 51, 50, 1, at + 80);
}

class PromiseHolder {
  value: Promise<boolean> | null = null;
}

export default function bridgeReviewR1Test() {
  describe('BridgeReviewR1', () => {
    it('r1_01_same_url_iframe_without_main_frame_token_is_subframe', 0, async () => {
      const session: BridgePageSession = sessionWith([TOKEN_A]);
      session.rotate();
      // 与主框架同地址、只差片段的 iframe：URL 一样，但拿不到令牌（直接调代理对象只能传空串或猜的值）。
      for (const frameUrl of [PAGE_URL, PAGE_URL + '#frame']) {
        expect(BridgeFrames.callerOf(frameUrl, '', session, true).isMainFrame).assertFalse();
      }
      expect(BridgeFrames.callerOf(PAGE_URL, TOKEN_A, session, true).isMainFrame).assertTrue();
      // 宿主：iframe 的 clipboard.write（有点击）被 90403 拒绝，写入一次都没发生；主框架带令牌照常。
      let writes: number = 0;
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.pageGeneration = (): number => session.generation;
      host.register('clipboard.write', BridgeHandlers.clipboardWrite((_t: string): Promise<boolean> => {
        writes++;
        return Promise.resolve(true);
      }));
      const frame: BridgeCaller = BridgeFrames.callerOf(PAGE_URL, '', session, true);
      expect(wire(await host.handle(req('a', 'clipboard.write', '{"text":"x"}'), frame)).code).assertEqual(90403);
      expect(writes).assertEqual(0);
      const main: BridgeCaller = BridgeFrames.callerOf(PAGE_URL, TOKEN_A, session, true);
      expect(wire(await host.handle(req('b', 'clipboard.write', '{"text":"x"}'), main)).code).assertEqual(0);
      expect(writes).assertEqual(1);
    });

    it('r1_01_sandbox_iframe_guessed_or_stale_token_is_refused', 0, () => {
      const session: BridgePageSession = sessionWith([TOKEN_A, TOKEN_B]);
      session.rotate();
      // sandbox iframe（opaque origin，读不到父页面）只能猜。
      expect(BridgeFrames.callerOf(PAGE_URL, TOKEN_B, session, true).isMainFrame).assertFalse();
      expect(BridgeFrames.callerOf(PAGE_URL, 'null', session, true).isMainFrame).assertFalse();
      // 新页面世代：上一页的令牌立刻失效。
      session.rotate();
      expect(BridgeFrames.callerOf(PAGE_URL, TOKEN_A, session, true).isMainFrame).assertFalse();
      expect(BridgeFrames.callerOf(PAGE_URL, TOKEN_B, session, true).isMainFrame).assertTrue();
      // 容器销毁后谁都不是主框架；随机源给不出够长的值时不发令牌（全拒）。
      session.invalidate();
      expect(BridgeFrames.callerOf(PAGE_URL, TOKEN_B, session, true).isMainFrame).assertFalse();
      expect(BridgeFrames.callerOf(PAGE_URL, '', session, true).isMainFrame).assertFalse();
      const weak: BridgePageSession = sessionWith(['short']);
      expect(weak.rotate()).assertEqual('');
      expect(BridgeFrames.callerOf(PAGE_URL, '', weak, true).isMainFrame).assertFalse();
      expect(BridgeFrames.callerOf(PAGE_URL, 'short', weak, true).isMainFrame).assertFalse();
      // origin 仍取调用方 frame 的 URL。
      expect(BridgeFrames.callerOf('https://evil.example.test/x', TOKEN_B, sessionWith([TOKEN_B]), true).origin)
        .assertEqual('https://evil.example.test');
    });

    it('r1_04_consent_withdrawn_during_update_wait_cancels_queued_clipboard_write', 0, async () => {
      const state: FakeState = new FakeState();
      const clock: ManualClock = new ManualClock();
      state.status = UpdateCheckStatus.checking(clock.t);
      const host: BridgeHost = new BridgeHost(state, clock);
      let writes: number = 0;
      host.register('clipboard.write', BridgeHandlers.clipboardWrite((_t: string): Promise<boolean> => {
        writes++;
        return Promise.resolve(true);
      }));
      const pending: Promise<string | null> = host.handle(req('a', 'clipboard.write', '{"text":"x"}'), MAIN_TAP);
      await clock.advance(1000);
      // 等待期间撤回同意进入基本模式（同意周期变了），强更检查变成未知。
      state.privacyRaw = 'basic_mode';
      state.bindingValue = 'binding-after-withdrawal';
      state.status = UpdateCheckStatus.finished(UpdateState.UNKNOWN);
      await clock.advance(200);
      expect(wire(await pending).code === 0).assertFalse();
      expect(writes).assertEqual(0);
    });

    it('r1_04_environment_or_session_change_and_page_leave_void_pending_calls', 0, async () => {
      const state: FakeState = new FakeState();
      const clock: ManualClock = new ManualClock();
      state.status = UpdateCheckStatus.checking(clock.t);
      const session: BridgePageSession = sessionWith([TOKEN_A, TOKEN_B]);
      session.rotate();
      const host: BridgeHost = new BridgeHost(state, clock);
      host.pageGeneration = (): number => session.generation;
      let writes: number = 0;
      host.register('clipboard.write', BridgeHandlers.clipboardWrite((_t: string): Promise<boolean> => {
        writes++;
        return Promise.resolve(true);
      }));
      const caller: BridgeCaller = BridgeFrames.callerOf(PAGE_URL, TOKEN_A, session, true);
      // 环境切换 / 换了会话（隐私仍是已同意）：作废，90500。
      const first: Promise<string | null> = host.handle(req('a', 'clipboard.write', '{"text":"x"}'), caller);
      await clock.advance(500);
      state.bindingValue = 'binding-other-session';
      state.status = UpdateCheckStatus.finished(UpdateState.OK);
      await clock.advance(200);
      expect(wire(await first).code).assertEqual(90500);
      expect(writes).assertEqual(0);
      // 页面离开（新页面世代）：作废且不回复，结果不交给下一个页面。
      state.status = UpdateCheckStatus.checking(clock.t);
      const second: Promise<string | null> = host.handle(req('b', 'clipboard.write', '{"text":"x"}'),
        BridgeFrames.callerOf(PAGE_URL, TOKEN_A, session, true));
      await clock.advance(500);
      session.rotate();
      state.status = UpdateCheckStatus.finished(UpdateState.OK);
      await clock.advance(200);
      expect(await second).assertNull();
      expect(writes).assertEqual(0);
      // 能力实现拿到的 call.valid 跟随同一绑定。
      let seen: BridgeCall | null = null;
      host.register('app.getEnv', (c: BridgeCall): Promise<BridgeResult> => {
        seen = c;
        return Promise.resolve(BridgeResult.ok());
      });
      expect(wire(await host.handle(req('c', 'app.getEnv'),
        BridgeFrames.callerOf(PAGE_URL, TOKEN_B, session, false))).code).assertEqual(0);
      const call: BridgeCall | null = seen;
      expect(call !== null && (call as BridgeCall).valid()).assertTrue();
      state.bindingValue = 'changed-again';
      expect(call !== null && (call as BridgeCall).valid()).assertFalse();
    });

    it('r1_05_only_native_taps_count_as_gesture', 0, () => {
      const g: BridgeGesture = new BridgeGesture();
      // 只按下（按住、开始滚动）：不算。
      g.touch(BridgeTouchKind.DOWN, 50, 50, 1, 1000);
      expect(g.recent(1100)).assertFalse();
      // 滑动后抬起：不算。
      g.touch(BridgeTouchKind.MOVE, 50, 90, 1, 1050);
      g.touch(BridgeTouchKind.UP, 50, 90, 1, 1100);
      expect(g.recent(1150)).assertFalse();
      // 长按：不算。
      g.touch(BridgeTouchKind.DOWN, 50, 50, 1, 2000);
      g.touch(BridgeTouchKind.UP, 50, 50, 1, 2600);
      expect(g.recent(2650)).assertFalse();
      // 取消：不算。
      g.touch(BridgeTouchKind.DOWN, 50, 50, 1, 3000);
      g.touch(BridgeTouchKind.CANCEL, 50, 50, 1, 3050);
      g.touch(BridgeTouchKind.UP, 50, 50, 1, 3080);
      expect(g.recent(3100)).assertFalse();
      // 双指：不算。
      g.touch(BridgeTouchKind.DOWN, 50, 50, 1, 4000);
      g.touch(BridgeTouchKind.DOWN, 80, 50, 2, 4010);
      g.touch(BridgeTouchKind.UP, 50, 50, 2, 4080);
      expect(g.recent(4100)).assertFalse();
      // 有效点击：1 秒内算；页面切换后清除。
      tap(g, 5000);
      expect(g.recent(5500)).assertTrue();
      expect(g.recent(6081)).assertFalse();
      tap(g, 7000);
      g.clear();
      expect(g.recent(7100)).assertFalse();
    });

    it('r1_06_below_min_and_unknown_request_read_only_h5_token', 0, async () => {
      const state: FakeState = new FakeState();
      state.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      state.forcePage = true;
      const bodies: string[] = [];
      const api = (r: ApiRequest): Promise<ApiResult> => {
        bodies.push(r.body ?? '');
        const d: BridgeJson = {};
        d['token'] = 'tkn';
        d['expire_at'] = '2026-10-02T10:00:00+08:00';
        d['scope'] = 'read_only';
        return Promise.resolve(apiResult(ApiOutcome.SUCCESS, 0, d, 200));
      };
      const host: BridgeHost = new BridgeHost(state, new ManualClock());
      host.register('auth.getH5Token', BridgeHandlers.h5Token(api));
      // 强更页进入的只读容器（BELOW_MIN）：只能申请 read_only。
      expect(wire(await host.handle(req('a', 'auth.getH5Token'), MAIN_TAP)).code).assertEqual(0);
      expect(JSON.stringify(bodies)).assertEqual('["{\\"scope\\":\\"read_only\\"}"]');
      expect(BridgeHandlers.h5TokenScope(UpdateState.OK)).assertEqual('standard');
      expect(BridgeHandlers.h5TokenScope(UpdateState.BELOW_RECOMMENDED)).assertEqual('standard');
      expect(BridgeHandlers.h5TokenScope(UpdateState.UNKNOWN)).assertEqual('read_only');
      expect(BridgeHandlers.h5TokenScope(UpdateState.BELOW_MIN)).assertEqual('read_only');
    });

    it('r1_03_whitelist_comes_only_from_verified_bridge_origins', 0, () => {
      // h5_base_url 合法、bridge_origins 为空或没有有效签名：白名单为空，不用 h5_base_url 代替。
      const unsigned: FakeLayers = new FakeLayers()
        .set('current', 'h5_base_url', '"https://h5.example.test/"')
        .set('current', 'bridge_origins', '{}')
        .set('lkg', 'bridge_origins', '{"origins":["https://old.example.test"]}')
        .set('bundled', 'bridge_origins', '{}');
      expect(JSON.stringify(BridgeOrigins.fromConfig(unsigned, new StubVerifier()))).assertEqual('[]');
      expect(JSON.stringify(BridgeOrigins.fromConfig(unsigned, new PendingContractBridgeOriginsVerifier())))
        .assertEqual('[]');
      expect(JSON.stringify(BridgeOrigins.fromConfig(null, new StubVerifier()))).assertEqual('[]');
      // 顺序：当前验签通过 → LKG 验签通过 → 包内；不跨层合并，只留 https。
      const layered: FakeLayers = new FakeLayers()
        .set('current', 'bridge_origins', '{"signed":false,"origins":["https://cur.example.test"]}')
        .set('lkg', 'bridge_origins', '{"signed":true,"origins":["https://LKG.example.test:443","http://plain.example.test"]}')
        .set('bundled', 'bridge_origins', '{"origins":["https://bundled.example.test"]}');
      expect(JSON.stringify(BridgeOrigins.fromConfig(layered, new StubVerifier())))
        .assertEqual('["https://lkg.example.test"]');
      layered.set('current', 'bridge_origins', '{"signed":true,"origins":["https://cur.example.test"]}');
      expect(JSON.stringify(BridgeOrigins.fromConfig(layered, new StubVerifier())))
        .assertEqual('["https://cur.example.test"]');
      const bundledOnly: FakeLayers = new FakeLayers()
        .set('bundled', 'bridge_origins', '{"origins":["https://bundled.example.test"]}');
      expect(JSON.stringify(BridgeOrigins.fromConfig(bundledOnly, new StubVerifier())))
        .assertEqual('["https://bundled.example.test"]');
      // 契约未定（N-22）：生产验签器对任何层都给不出白名单。
      expect(JSON.stringify(BridgeOrigins.fromConfig(layered, new PendingContractBridgeOriginsVerifier())))
        .assertEqual('[]');
    });

    it('r1_07_auth_pages_are_isolated_on_initial_and_every_navigation', 0, () => {
      const log: HookLog = new HookLog();
      const nav: ExternalPageNavigator = navigatorWith(log, true, false);
      const apple: string = 'https://appleid.apple.com/auth/authorize?client_id=c&redirect_uri=https%3A%2F%2Fa.test%2F';
      const wechat: string = 'https://open.weixin.qq.com/connect/qrconnect?appid=a&redirect_uri=https%3A%2F%2Fa.test';
      const huawei: string = 'https://oauth-login.cloud.huawei.com/oauth2/v3/authorize?response_type=code';
      // 原场景：这些地址不命中联盟规则，单看导航策略会放行。
      expect(new ExternalNavPolicy(RULES).decide(apple, true, false, RULES).actionRaw).assertEqual('load');
      for (const url of [apple, wechat, huawei]) {
        for (const frame of [ExternalNavFrame.INITIAL, ExternalNavFrame.MAIN, ExternalNavFrame.SUBFRAME,
          ExternalNavFrame.NEW_WINDOW]) {
          expect(outcomeText(nav.navigate(url, frame))).assertEqual('cancel ' + ExternalNoticeKey.UNION_HOST_BLOCKED);
        }
      }
      expect(AuthPageRules.isAuthPage('https://brand.example.com/accounts/signin')).assertTrue();
      expect(AuthPageRules.isAuthPage('https://sso.example.com/')).assertTrue();
      // 普通品牌页照常加载。
      expect(outcomeText(nav.navigate('https://brand.example.com/story/2026', ExternalNavFrame.MAIN)))
        .assertEqual('load -');
      expect(AuthPageRules.isAuthPage('https://example.com/?next=https://taobao.example.test/')).assertFalse();
    });

    it('r1_08_product_page_dispatches_router_intent_or_shows_failure', 0, () => {
      const product: string = 'https://item.taobao.example.test/item?id=42#section';
      // 能交识别、Router 现在处理不了：取消原导航，意图带去片段 URL，给出 product_unresolved 提示。
      const log: HookLog = new HookLog();
      expect(outcomeText(navigatorWith(log, true, false).navigate(product, ExternalNavFrame.MAIN)))
        .assertEqual('cancel ' + ExternalNoticeKey.PRODUCT_UNRESOLVED);
      expect(JSON.stringify(log.dispatched)).assertEqual('["https://item.taobao.example.test/item?id=42"]');
      expect(JSON.stringify(log.union)).assertEqual('["product main ' + ExternalUnionOutcome.PARSE_FAILED + '"]');
      // Router 接手：不出提示。
      const handled: HookLog = new HookLog();
      expect(outcomeText(navigatorWith(handled, true, true).navigate(product, ExternalNavFrame.INITIAL)))
        .assertEqual('cancel -');
      expect(JSON.stringify(handled.union)).assertEqual('["product initial ' + ExternalUnionOutcome.PARSE_OK + '"]');
      // 基本模式或开关关：按 (b) 拦下，不发意图，也不加载。
      const off: HookLog = new HookLog();
      expect(outcomeText(navigatorWith(off, false, true).navigate(product, ExternalNavFrame.MAIN)))
        .assertEqual('cancel ' + ExternalNoticeKey.UNION_HOST_BLOCKED);
      expect(off.dispatched.length).assertEqual(0);
    });

    it('r1_11_system_back_goes_back_in_web_history_first', 0, () => {
      expect(WebBackPolicy.systemBack(true, false)).assertEqual(WebBackPolicy.WEB_BACK);
      expect(WebBackPolicy.systemBack(false, false)).assertEqual(WebBackPolicy.CLOSE);
      expect(WebBackPolicy.systemBack(true, true)).assertEqual(WebBackPolicy.CLOSE);
    });

    it('r1_12_nav_host_is_sampled_at_the_unified_entry_without_path_or_query', 0, () => {
      const log: HookLog = new HookLog();
      // 采样率 100bp（1%），抽中（0.005 * 10000 = 50 < 100）。
      const nav: ExternalPageNavigator = navigatorWith(log, true, false, 100, 0.005);
      nav.navigate('https://www.newmall.example.com/a/b?uid=1#x', ExternalNavFrame.MAIN);
      nav.navigate('https://shop.taobao.example.test/', ExternalNavFrame.SUBFRAME);
      nav.navigate('https://cdn.brand.example.com.cn/x', ExternalNavFrame.INITIAL);
      nav.navigate('https://another.example.org/', ExternalNavFrame.NEW_WINDOW);
      nav.navigate('intent://x#Intent;end', ExternalNavFrame.MAIN);
      expect(JSON.stringify(log.navHosts)).assertEqual('["example.com main false","example.test subframe true",' +
        '"example.com.cn initial false","example.org new_window false"]');
      // 没抽中、采样率为 0：不报。
      const quiet: HookLog = new HookLog();
      navigatorWith(quiet, true, false, 100, 0.02).navigate('https://www.example.com/', ExternalNavFrame.MAIN);
      navigatorWith(quiet, true, false, 0, 0).navigate('https://www.example.com/', ExternalNavFrame.MAIN);
      expect(quiet.navHosts.length).assertEqual(0);
      expect(RegisteredDomain.of('10.0.0.1')).assertEqual('10.0.0.1');
      expect(RegisteredDomain.of('example.com')).assertEqual('example.com');
    });

    it('app03b_item27_backoff_registration_is_the_recovery_for_the_rejected_credential', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      const registrations: Deferred[] = [new Deferred(), new Deferred()];
      let index: number = 0;
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/devices') >= 0) {
          const d: Deferred = registrations[Math.min(index, registrations.length - 1)];
          index++;
          return d.promise;
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      // 10402 窗口失败：交给退避一次。
      const failedWindow: Promise<boolean> = rr.registry.reregister('dev-old');
      await flush();
      registrations[0].resolve(envelope(50001, '{}'));
      expect(await failedWindow).assertFalse();
      expect(rr.lost).assertEqual(1);
      // 退避注册开始（在途）。
      const backoff: Promise<boolean> = rr.registry.register();
      await flush();
      expect(rr.devicesSent().length).assertEqual(2);
      // 还没醒来的同一凭据 10402：复用退避这次的结果，不再复用窗口的失败，也不另发注册。
      const holder: PromiseHolder = new PromiseHolder();
      holder.value = rr.registry.reregister('dev-old');
      registrations[1].resolve(registered('dev-new'));
      expect(await backoff).assertTrue();
      const late: Promise<boolean> | null = holder.value;
      expect(late !== null).assertTrue();
      if (late !== null) {
        expect(await late).assertTrue();
      }
      // 凭据已被替换：再晚到的同一凭据 10402 直接重放。
      expect(await rr.registry.reregister('dev-old')).assertTrue();
      expect(rr.devicesSent().length).assertEqual(2);
      expect(rr.lost).assertEqual(1);
    });
  });
}
