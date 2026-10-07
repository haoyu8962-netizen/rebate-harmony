// APP-04 鸿蒙第 2 轮评审（harmony-review-r2.md）的回归测试：每条都复现原场景，撤掉修复后对应用例失败。
// R2-01 同源子框架（可信容器取消指向可信 bridge origin 的子框架文档）；R2-02 权限申请内部等待后复核调用有效性；
// R2-03 会话世代进入调用绑定；R2-04 可信容器的授权页隔离；R2-05 URL 点段按浏览器口径规范化；R2-06 坏规则表整表回落、
// union_host 整域阻断；R2-08 新窗口类型保留到埋点；R2-09 平台页面被拦提供「去搜索」。
// R2-07（启动脚本的重复在途 id）在 tools/ci/bridge-bootstrap-test.js（verify.sh 用 node 执行随包脚本原文）。
import { describe, it, expect } from '@ohos/hypium';
import { ClientEvent, ClientEventValue, Routes, RouteSpec } from 'generated';
import {
  BridgeBinding, BridgeCaller, BridgeCode, BridgeContext, BridgeDecision, BridgeFrames, BridgeHandlers, BridgeHost,
  BridgePageSession, BridgeProtocol, ConfigResolver, EntryGuard, ExternalNavDecision, ExternalNavEvents,
  ExternalNavFrame, ExternalNavHooks, ExternalNavOutcome, ExternalNavPolicy, ExternalNoticeKey, ExternalPageNavigator,
  GuardDecision, GuardDecisionKind, GuardState, LinkRuleTable, NormalizedHttpsUrl, PermissionRequester,
  PermissionResult, RouteLookup, RouteRequest, RouteSource, RouteTargetAllowlist, SessionTokenSet, StandardUrl,
  TrustedNavAction, TrustedNavDecision, TrustedNavPolicy, UpdateCheckStatus, UpdateState
} from '../../Index';
import { FakeState, flush, MAIN_TAP, ManualClock, ORIGIN, req, wire } from './BridgeHost.test';
import { Rig } from './NetworkTestRig';

const PAGE_URL: string = 'https://h5.example.test/rules/index.html';
const TOKEN_A: string = '0123456789abcdef0123456789abcdef';
const TRUSTED: string[] = [ORIGIN];
/** 联盟整域 + 推广路径规则（推广：go.example.test 的 ^/promo）。 */
const PROMO_RULES: string = '{"version":"r2","rules":[' +
  '{"platform":"taobao","category":"union_host","hosts":["taobao.example.test"],"path_patterns":[]},' +
  '{"platform":"taobao","category":"promo","hosts":["go.example.test"],"path_patterns":["^/promo"]},' +
  '{"platform":"taobao","category":"product","hosts":["item.taobao.example.test"],"path_patterns":["^/item$"]}]}';
/** 包内表：覆盖 taobao、jd。 */
const BUNDLED_RULES: string = '{"version":"bundled","rules":[' +
  '{"platform":"taobao","category":"union_host","hosts":["taobao.example.test"],"path_patterns":[]},' +
  '{"platform":"jd","category":"union_host","hosts":["jd.example.test"],"path_patterns":[]}]}';
/** 当前表：taobao 的 union_host 规则带编译不了的路径正则，另有有效的 jd 规则（R2-06 原场景）。 */
const BAD_REGEX_RULES: string = '{"version":"bad","rules":[' +
  '{"platform":"taobao","category":"union_host","hosts":["taobao.example.test"],"path_patterns":["["]},' +
  '{"platform":"jd","category":"union_host","hosts":["jd.example.test"],"path_patterns":[]}]}';

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

class HookLog {
  union: string[] = [];
  blocked: string[] = [];
  navHosts: string[] = [];
  events: ClientEvent[] = [];
}

function navigatorWith(log: HookLog, patterns: string, bp: number = 10000): ExternalPageNavigator {
  const hooks: ExternalNavHooks = new ExternalNavHooks();
  hooks.productIntercept = (): boolean => false;
  hooks.unionHost = (decision: ExternalNavDecision, frame: string, outcome: string): void => {
    log.union.push((decision.rule === null ? '-' : decision.rule.category) + ' ' + frame + ' ' + outcome);
    const event: ClientEvent | null = ExternalNavEvents.unionHost('ExternalPage', decision, frame, outcome);
    if (event !== null) {
      log.events.push(event);
    }
  };
  hooks.blockedNav = (kind: string, frame: string): void => {
    log.blocked.push(kind + ' ' + frame);
    log.events.push(ExternalNavEvents.blockedNav('ExternalPage', kind, frame));
  };
  hooks.navHost = (domain: string, frame: string, hit: boolean): void => {
    log.navHosts.push(domain + ' ' + frame + ' ' + hit);
    log.events.push(ExternalNavEvents.navHost('ExternalPage', domain, frame, hit));
  };
  hooks.sampleBp = (): number => bp;
  hooks.random = (): number => 0;
  return new ExternalPageNavigator(new ExternalNavPolicy(patterns), (): string | null => patterns, hooks);
}

function field(event: ClientEvent, name: string): string {
  const value: ClientEventValue | undefined = event.fields.get(name);
  return value === undefined ? '-' : String(value);
}

/** 用途说明：由测试决定何时点【继续】。 */
class RationaleGate {
  shown: number = 0;
  private release: () => void = () => {
  };

  show(): Promise<void> {
    this.shown++;
    return new Promise<void>((resolve: () => void) => {
      this.release = resolve;
    });
  }

  tapContinue(): void {
    this.release();
  }
}

class PermissionRig {
  readonly gate: RationaleGate = new RationaleGate();
  systemCalls: number = 0;
  readonly requester: PermissionRequester;

  constructor() {
    this.requester = new PermissionRequester((): string | null => null, (_v: string | null): void => {
    }, (): number => 1000000, 'harmony', (_p: string): string => 'not_asked',
      (_purpose: string, _continue: string | null): Promise<void> => this.gate.show(),
      (_p: string): Promise<string> => {
        this.systemCalls++;
        return Promise.resolve('granted');
      }, (_m: string | null, _b: string): void => {
      });
  }
}

function guestState(): GuardState {
  return new GuardState('consented', 'ok', 'guest', true, '1.0.0', false, false, false, RouteTargetAllowlist.EMPTY);
}

export default function bridgeReviewR2Test() {
  describe('BridgeReviewR2', () => {
    it('r2_01_same_origin_subframe_cannot_borrow_main_frame_bridge_because_trusted_container_cancels_it', 0, () => {
      // 原场景：同源 iframe 经 parent.__REBATE_BRIDGE__ 调用，父页面闭包附上有效令牌，原生只能看到「主框架」。
      const session: BridgePageSession = sessionWith([TOKEN_A]);
      session.rotate();
      const borrowed: BridgeCaller = BridgeFrames.callerOf(PAGE_URL, TOKEN_A, session, true);
      expect(borrowed.isMainFrame).assertTrue();
      // 所以修复在容器：指向可信 bridge origin 的子框架文档一律取消，同源 iframe 根本载入不了独立内容。
      const sameOrigin: string[] = [
        PAGE_URL, PAGE_URL + '#frame', 'https://h5.example.test/other/child.html', 'https://H5.EXAMPLE.TEST/x',
        'https://h5.example.test:443/x', 'https://h5.example.test./x', 'https://h5.example%2Etest/x',
        'https://h5%2eexample.test/x', 'https:h5.example.test/x', 'https:\\\\h5.example.test\\x',
        ' https://h5.example.test/x', 'https://h5.exa\tmple.test/x', 'https://h5.example.test:/x'
      ];
      for (const url of sameOrigin) {
        const d: TrustedNavDecision = TrustedNavPolicy.decide(url, false, TRUSTED);
        expect(url + ' ' + d.action).assertEqual(url + ' ' + TrustedNavAction.CANCEL);
      }
      // 带用户信息、解析不了的 https 子框架也取消（保守）。
      expect(TrustedNavPolicy.decide('https://user@h5.example.test/x', false, TRUSTED).cancel).assertTrue();
      // about:blank / about:srcdoc 的内容由父页面写入，同一主体，照常；跨源 https 子框架照常（调用桥仍按子框架拒绝）。
      expect(TrustedNavPolicy.decide('about:blank', false, TRUSTED).action).assertEqual(TrustedNavAction.LOAD);
      expect(TrustedNavPolicy.decide('about:srcdoc', false, TRUSTED).action).assertEqual(TrustedNavAction.LOAD);
      expect(TrustedNavPolicy.decide('https://video.example.org/embed', false, TRUSTED).action)
        .assertEqual(TrustedNavAction.LOAD);
      expect(TrustedNavPolicy.decide('https://h5.example.test:8443/x', false, TRUSTED).action)
        .assertEqual(TrustedNavAction.LOAD);
      // 主框架令牌机制保留：主框架照常加载可信页。
      expect(TrustedNavPolicy.decide(PAGE_URL, true, TRUSTED).action).assertEqual(TrustedNavAction.LOAD);
      // 补充防线：带 Sec-Fetch-Dest=iframe 的非主框架请求按同一判定拦；子资源（image、script）不拦。
      expect(TrustedNavPolicy.subframeDocumentBlocked(PAGE_URL, false, 'iframe', TRUSTED)).assertTrue();
      expect(TrustedNavPolicy.subframeDocumentBlocked(PAGE_URL, false, 'FRAME', TRUSTED)).assertTrue();
      expect(TrustedNavPolicy.subframeDocumentBlocked(PAGE_URL, false, 'image', TRUSTED)).assertFalse();
      expect(TrustedNavPolicy.subframeDocumentBlocked(PAGE_URL, false, null, TRUSTED)).assertFalse();
      expect(TrustedNavPolicy.subframeDocumentBlocked(PAGE_URL, true, 'iframe', TRUSTED)).assertFalse();
      expect(TrustedNavPolicy.subframeDocumentBlocked('https://video.example.org/e', false, 'iframe', TRUSTED))
        .assertFalse();
    });

    it('r2_02_permission_request_rechecks_validity_after_rationale_and_in_queue', 0, async () => {
      // 原场景：已同意时 perm.request 进入用途说明；等待期间撤回同意，再点继续 → 不得调用系统权限接口。
      const rig: PermissionRig = new PermissionRig();
      const state: FakeState = new FakeState();
      const host: BridgeHost = new BridgeHost(state, new ManualClock());
      host.register('perm.request', BridgeHandlers.permission((type: string, valid: () => boolean): Promise<boolean> =>
      rig.requester.request(type, false, valid).then((r: PermissionResult): boolean => r.granted)));
      const pending: Promise<string | null> = host.handle(req('p', 'perm.request', '{"type":"push"}'), MAIN_TAP);
      await flush();
      expect(rig.gate.shown).assertEqual(1);
      state.privacyRaw = 'basic_mode';
      state.bindingValue = 'binding-after-withdrawal';
      rig.gate.tapContinue();
      const reply = wire(await pending);
      expect(rig.systemCalls).assertEqual(0);
      expect(reply.code === 0).assertFalse();
      // 排队中失效：前一个申请还在说明页时，后一个申请的调用方已失效 → 出队时取消，连说明都不弹。
      const second: PermissionRig = new PermissionRig();
      let alive: boolean = true;
      const first: Promise<PermissionResult> = second.requester.request('push');
      const queued: Promise<PermissionResult> = second.requester.request('photos', false, (): boolean => alive);
      await flush();
      alive = false;
      second.gate.tapContinue();
      expect((await first).granted).assertTrue();
      expect((await queued).resultRaw).assertEqual('unavailable');
      expect(second.gate.shown).assertEqual(1);
      expect(second.systemCalls).assertEqual(1);
      // 有效性读不出（抛错）按失效。
      const third: PermissionRig = new PermissionRig();
      const broken: Promise<PermissionResult> = third.requester.request('push', false, (): boolean => {
        throw new Error('gone');
      });
      expect((await broken).resultRaw).assertEqual('unavailable');
      expect(third.systemCalls).assertEqual(0);
    });

    it('r2_03_relogin_of_same_account_is_a_new_session_generation_in_binding', 0, async () => {
      const rig: Rig = new Rig();
      const bindingOf = (): string => BridgeBinding.of('consented', 1, 7, rig.client.sessionGenerationId(),
        rig.client.sessionAccount());
      const before: string = bindingOf();
      expect(rig.client.sessionAccount()).assertEqual('user-1');
      // 账号 A 退出后重新登录 A：账号相同，世代不同。
      rig.tokens.clear();
      rig.client.onSessionChanged();
      rig.tokens.save(new SessionTokenSet('again-access', 'again-refresh', 'full', 'user-1'));
      rig.client.onSessionChanged();
      expect(rig.client.sessionAccount()).assertEqual('user-1');
      expect(bindingOf() === before).assertFalse();
      expect(bindingOf().indexOf('again-access') < 0 && bindingOf().indexOf('refresh') < 0).assertTrue();
      // 宿主原场景：调用等待强更检查期间，同账号退出又登录 → 旧调用不在新会话下执行。
      const state: FakeState = new FakeState();
      const clock: ManualClock = new ManualClock();
      state.status = UpdateCheckStatus.checking(clock.t);
      state.bindingValue = bindingOf();
      const host: BridgeHost = new BridgeHost(state, clock);
      let writes: number = 0;
      host.register('clipboard.write', BridgeHandlers.clipboardWrite((_t: string): Promise<boolean> => {
        writes++;
        return Promise.resolve(true);
      }));
      const call: Promise<string | null> = host.handle(req('c', 'clipboard.write', '{"text":"x"}'), MAIN_TAP);
      await clock.advance(500);
      rig.tokens.clear();
      rig.client.onSessionChanged();
      rig.tokens.save(new SessionTokenSet('third-access', 'third-refresh', 'full', 'user-1'));
      rig.client.onSessionChanged();
      state.bindingValue = bindingOf();
      state.status = UpdateCheckStatus.finished(UpdateState.OK);
      await clock.advance(200);
      expect(wire(await call).code).assertEqual(BridgeCode.NATIVE_ERROR);
      expect(writes).assertEqual(0);
    });

    it('r2_04_trusted_container_isolates_auth_pages_in_subframes_main_frame_and_initial_url', 0, () => {
      const apple: string = 'https://appleid.apple.com/auth/authorize?client_id=example';
      // 原场景：可信 H5 内嵌授权页，子框架只看 https 就放行。
      expect(TrustedNavPolicy.decide(apple, false, TRUSTED).action).assertEqual(TrustedNavAction.CANCEL);
      expect(TrustedNavPolicy.decide(apple, false, TRUSTED).reason).assertEqual('auth_page');
      expect(TrustedNavPolicy.decide('https://open.weixin.qq.com/connect/qrconnect?appid=x', false, TRUSTED).cancel)
        .assertTrue();
      // 主框架去授权页：不交给外部容器，直接取消。
      expect(TrustedNavPolicy.decide(apple, true, TRUSTED).action).assertEqual(TrustedNavAction.CANCEL);
      expect(TrustedNavPolicy.decide('https://example.com/about', true, TRUSTED).action)
        .assertEqual(TrustedNavAction.EXTERNAL);
      // 第一个 URL：授权页不进容器；可信页照常。
      expect(TrustedNavPolicy.initial(apple, TRUSTED).cancel).assertTrue();
      expect(TrustedNavPolicy.initial(PAGE_URL, TRUSTED).cancel).assertFalse();
      expect(TrustedNavPolicy.initial('https://example.com/', TRUSTED).cancel).assertTrue();
    });

    it('r2_05_dot_segments_encoded_dots_and_backslashes_are_normalized_like_a_browser', 0, () => {
      const variants: string[] = [
        'https://go.example.test/a/../promo/123',
        'https://go.example.test/a/%2e%2e/promo/123',
        'https://go.example.test/a/%2E%2e/promo/123',
        'https://go.example.test/a/.%2e/promo/123',
        'https://go.example.test/a/%2e./promo/123',
        'https://go.example.test/./promo/123',
        'https://go.example.test/%2e/promo/123',
        'https://go.example.test/a\\..\\promo\\123',
        'https://go.example.test\\a\\..\\promo/123',
        'https://go.example.test/a/b/../../promo',
        'https://go.example.test/../../promo',
        'https://go.example.test/x%2F..%2Fpromo/1'
      ];
      const protocol: BridgeProtocol = new BridgeProtocol(TRUSTED, PROMO_RULES, []);
      const policy: ExternalNavPolicy = new ExternalNavPolicy(PROMO_RULES);
      for (const url of variants) {
        const params: string = '{"url":' + JSON.stringify(url) + '}';
        const d: BridgeDecision = protocol.decide(new BridgeContext('ext.openBrowser', ORIGIN, true, true, 'consented',
          true, params));
        expect(url + ' ' + d.allow + ' ' + d.errorCode).assertEqual(url + ' false 90403');
        expect(url + ' ' + policy.canOpenInBrowser(url, PROMO_RULES)).assertEqual(url + ' false');
      }
      // 规范化结果与浏览器一致。
      expect(StandardUrl.normalizePath('/a/../promo/123')).assertEqual('/promo/123');
      expect(StandardUrl.normalizePath('/a/%2e%2E/b/./c/%2e')).assertEqual('/b/c/');
      expect(StandardUrl.normalizePath('\\a\\..\\b')).assertEqual('/b');
      expect(StandardUrl.normalizePath('/..')).assertEqual('/');
      expect(StandardUrl.normalizePath('')).assertEqual('/');
      const parsed: NormalizedHttpsUrl | null = NormalizedHttpsUrl.parse('https://Go.Example.Test.:443/a/%2e%2e/%70romo');
      expect(parsed !== null && parsed.host === 'go.example.test' && parsed.port === null
        && parsed.path === '/promo').assertTrue();
      // 导航判定同一口径：带编码点段的商品页按规范化后的 /item 识别为商品页。
      expect(policy.decide('https://item.taobao.example.test/x/%2e%2e/item', true, false, PROMO_RULES).actionRaw)
        .assertEqual('to_native_product');
      // 不命中的普通地址照常放行。
      expect(policy.canOpenInBrowser('https://example.com/a/../b', PROMO_RULES)).assertTrue();
    });

    it('r2_06_bad_rule_table_falls_back_whole_and_union_host_blocks_whole_domain', 0, () => {
      // 原场景：当前表的 taobao 规则带坏正则、另有有效规则 → 不能被接受。
      expect(LinkRuleTable.parse(BAD_REGEX_RULES)).assertNull();
      const policy: ExternalNavPolicy = new ExternalNavPolicy(BUNDLED_RULES);
      expect(policy.decide('https://taobao.example.test/cart', true, false, BAD_REGEX_RULES).actionRaw)
        .assertEqual('block');
      // 取层：坏的当前表跳过，回落到 LKG；LKG 也坏时回落到包内。
      const current: string = '{"link_patterns":' + BAD_REGEX_RULES + '}';
      const lkg: string = '{"link_patterns":' + PROMO_RULES + '}';
      const bundled: string = '{"link_patterns":' + BUNDLED_RULES + '}';
      expect(ConfigResolver.linkPatterns(current, lkg, bundled)).assertEqual(JSON.stringify(JSON.parse(PROMO_RULES)));
      expect(ConfigResolver.linkPatterns(current, current, bundled))
        .assertEqual(JSON.stringify(JSON.parse(BUNDLED_RULES)));
      // 两者都不可用：拒绝加载（所有 https 拦下）。
      const nothing: ExternalNavPolicy = new ExternalNavPolicy(BAD_REGEX_RULES);
      expect(nothing.decide('https://example.com/', true, false, BAD_REGEX_RULES).actionRaw).assertEqual('block');
      // 其他不合格：未知类别、空主机、多余字段、空路径模式。
      const bad: string[] = [
        '{"version":"x","rules":[{"platform":"taobao","category":"shop","hosts":["a.test"],"path_patterns":[]}]}',
        '{"version":"x","rules":[{"platform":"taobao","category":"union_host","hosts":[""],"path_patterns":[]}]}',
        '{"version":"x","rules":[{"platform":"taobao","category":"union_host","hosts":["a.test"],' +
          '"path_patterns":[],"x":1}]}',
        '{"version":"x","rules":[{"platform":"taobao","category":"product","hosts":["a.test"],"path_patterns":[""]}]}',
        '{"version":"x","rules":[{"category":"union_host","hosts":["a.test"],"path_patterns":[]}]}'
      ];
      for (const table of bad) {
        expect(LinkRuleTable.parse(table)).assertNull();
      }
      // union_host 按注册域整域阻断：即使规则带路径模式，也不因路径不命中而放行。
      const withPath: string = '{"version":"p","rules":[{"platform":"taobao","category":"union_host",' +
        '"hosts":["taobao.example.test"],"path_patterns":["^/help$"]}]}';
      expect(policy.decide('https://taobao.example.test/cart', true, false, withPath).actionRaw).assertEqual('block');
      expect(policy.decide('https://m.taobao.example.test/', true, false, withPath).actionRaw).assertEqual('block');
    });

    it('r2_08_new_window_requests_keep_new_window_type_into_generated_events', 0, () => {
      const log: HookLog = new HookLog();
      const navigator: ExternalPageNavigator = navigatorWith(log, PROMO_RULES);
      // 原场景：window.open / target=_blank 打开平台页面，埋点必须记 new_window，不能记成主框架。
      const blocked: ExternalNavOutcome = navigator.newWindow('https://taobao.example.test/cart');
      expect(blocked.cancel).assertTrue();
      expect(log.union).assertDeepEquals(['union_host new_window block']);
      expect(log.navHosts).assertDeepEquals(['example.test new_window true']);
      const frames: string[] = log.events.map((e: ClientEvent): string => e.name + ':' + field(e, 'frame'));
      expect(frames.indexOf('external_page_union_host:new_window') >= 0).assertTrue();
      expect(frames.indexOf('external_page_nav_host:new_window') >= 0).assertTrue();
      // 非 https 的新窗口：blocked_nav 也记 new_window。
      expect(navigator.newWindow('example-app://buy/42').cancel).assertTrue();
      expect(log.blocked).assertDeepEquals(['app_scheme new_window']);
      const last: ClientEvent = log.events[log.events.length - 1];
      expect(last.name + ':' + field(last, 'frame')).assertEqual('external_page_blocked_nav:new_window');
      // 放行的新窗口目标在当前容器加载：随后同一地址的主框架回调不重复判定、不重复抽样；其余主框架导航照常记 main。
      const before: number = log.navHosts.length;
      expect(navigator.newWindow('https://example.com/about').cancel).assertFalse();
      expect(log.navHosts.length).assertEqual(before + 1);
      expect(navigator.mainFrame('https://example.com/about').cancel).assertFalse();
      expect(log.navHosts.length).assertEqual(before + 1);
      expect(navigator.mainFrame('https://example.com/next').cancel).assertFalse();
      expect(log.navHosts[log.navHosts.length - 1]).assertEqual('example.com main false');
      // 生成事件的框架映射四种取值逐一对应。
      for (const frame of [ExternalNavFrame.INITIAL, ExternalNavFrame.MAIN, ExternalNavFrame.SUBFRAME,
        ExternalNavFrame.NEW_WINDOW]) {
        expect(field(ExternalNavEvents.blockedNav('ExternalPage', 'http', frame), 'frame')).assertEqual(frame);
        expect(field(ExternalNavEvents.navHost('ExternalPage', 'a.test', frame, false), 'frame')).assertEqual(frame);
      }
    });

    it('r2_09_blocked_platform_pages_offer_go_search_via_router', 0, () => {
      const log: HookLog = new HookLog();
      const navigator: ExternalPageNavigator = navigatorWith(log, PROMO_RULES);
      // 原场景：页内点击平台店铺、购物车 → 只有提示没有操作；初始地址被拦也没有去向。
      const inPage: ExternalNavOutcome = navigator.navigate('https://shop.taobao.example.test/cart', ExternalNavFrame.MAIN);
      expect(inPage.cancel && inPage.notice === ExternalNoticeKey.UNION_HOST_BLOCKED).assertTrue();
      expect(inPage.offerSearch).assertTrue();
      expect(navigator.navigate('https://taobao.example.test/', ExternalNavFrame.INITIAL).offerSearch).assertTrue();
      expect(navigator.newWindow('https://taobao.example.test/shop').offerSearch).assertTrue();
      // 商品页不能交识别时按 (b) 拦下，也提供去搜索；非 https 取消、放行不提供。
      expect(navigator.navigate('https://item.taobao.example.test/item', ExternalNavFrame.MAIN).offerSearch)
        .assertTrue();
      expect(navigator.navigate('http://example.com/', ExternalNavFrame.MAIN).offerSearch).assertFalse();
      expect(navigator.navigate('https://example.com/', ExternalNavFrame.MAIN).offerSearch).assertFalse();
      expect(new ExternalNavOutcome(true, ExternalNoticeKey.PRODUCT_UNRESOLVED).offerSearch).assertFalse();
      // 去向：Router 打开 Search（App 内来源，游客可进，无必填参数）。
      const routes: RouteLookup = (name: string): RouteSpec | undefined => Routes.spec(name);
      const decision: GuardDecision = EntryGuard.decide(RouteRequest.of('Search', RouteSource.IN_APP), guestState(),
        routes);
      expect(decision.kind).assertEqual(GuardDecisionKind.OPEN);
    });
  });
}

