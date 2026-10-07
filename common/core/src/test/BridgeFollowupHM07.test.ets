// F-HM-07（APP-05a 顺带核对）：APP-04 共性清单第 26–39 条在鸿蒙的回归测试（UI 层的第 28、29 条见 notes_for_reviewer）。
// 第 27 条：运行中规则表变空或变坏时，主框架 / 新窗口导航取消并显示降级页（不是「没有匹配」放行、也不是只弹提示）；
// 第 39 条：nav_host_sample_bp 没有下发按 1000，显式 0 关闭。
// 第 42 / 52 条：确认不了系统视频全屏，一律不隐藏标题栏并退出元素全屏（R1-09）；第 43 / 53 条：nav.open 清栈、nav.close 让本容器
// 出栈时，发起的调用先交出成功回复再 teardown、其他在途调用作废（R1-10）；第 51 条：同地址重载也是文档导航（R1-08）；
// 第 54 条：最后一个有效调用方到期时取消共享刷新（R1-11）。
// 第 45 条：桥调用统一截止时间（含强更等待），到点撤销有效性并取消请求；第 49 条：hit 与导航动作分开；
// 编排者裁定：拦不到子框架每一跳时，ExternalWebView 一律取消子框架文档加载。
// 第 40 条：规则表逐条校验（类别、主机名），一条不合格整表作废；第 41 条：共享刷新窗口没有有效调用方时不再续发。
// APP-05a 第 2 轮 R2-04（共性 59）：破坏性导航等回复脚本真正执行完（runJavaScriptExt 的 Promise 兑现）才执行；
// 裁定「看不到每一跳时一律在第一跳取消」：(a) 可信容器网络子框架文档一律取消（共性 56），(b) 外部容器主框架 POST 一律取消（共性 57）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiRequest, ApiResult, BridgeCall, BridgeCaller, BridgePageSession, BridgeReplyChannel, BridgeResult, BridgeRouteOpening,
  TrustedNavAction, TrustedNavDecision, TrustedNavPolicy, UpdateCheckStatus,
  BridgeHandlers, BridgeHost, GuardDecision, GuardDecisionKind, GuardReason,
  UpdateState, WebFullScreen, ExternalNavFrame, ExternalNavHooks, ExternalNavOutcome, ExternalNavPolicy, ExternalNoticeKey,
  ExternalPageNavigator, LinkRuleTable, TransportRequest, TransportResponse
} from '../../Index';
import { Deferred, envelope, flush, Rig, tokenPair } from './NetworkTestRig';
import { FakeState, ManualClock, ORIGIN, req, wire } from './BridgeHost.test';

const RULES: string = '{"version":"hm07","rules":[' +
  '{"platform":"taobao","category":"union_host","hosts":["taobao.example.test"],"path_patterns":[]}]}';
/** 坏表：路径正则编译不了，整表作废。 */
const BAD_RULES: string = '{"version":"bad","rules":[' +
  '{"platform":"taobao","category":"union_host","hosts":["taobao.example.test"],"path_patterns":["["]}]}';
const EMPTY_RULES: string = '{"version":"empty","rules":[]}';

class Patterns {
  current: string | null = RULES;
}

function navigator(patterns: Patterns, bundled: string, sampled: string[]): ExternalPageNavigator {
  const hooks: ExternalNavHooks = new ExternalNavHooks();
  hooks.random = (): number => 0;
  hooks.navHost = (domain: string, frame: string, _hit: boolean): void => {
    sampled.push(domain + ' ' + frame);
  };
  return new ExternalPageNavigator(new ExternalNavPolicy(bundled), (): string | null => patterns.current, hooks);
}

export default function bridgeFollowupHM07Test() {
  describe('BridgeFollowupHM07', () => {
    it('item27_rules_becoming_empty_at_runtime_cancel_and_degrade', 0, () => {
      const patterns: Patterns = new Patterns();
      const nav: ExternalPageNavigator = navigator(patterns, EMPTY_RULES, []);
      const before: ExternalNavOutcome = nav.mainFrame('https://news.example.com/a');
      expect(before.cancel).assertFalse();
      // 运行中规则表变空（包内表也没有可用规则）：主框架导航取消，并要求降级页。
      patterns.current = EMPTY_RULES;
      const emptied: ExternalNavOutcome = nav.mainFrame('https://news.example.com/b');
      expect(emptied.cancel).assertTrue();
      expect(emptied.degraded).assertTrue();
      expect(emptied.notice).assertEqual(ExternalNoticeKey.UNION_HOST_BLOCKED);
      expect(emptied.offerSearch).assertTrue();
      // 变坏（解析不了 / 坏正则）同样处理；新窗口也一样。
      patterns.current = BAD_RULES;
      expect(nav.mainFrame('https://news.example.com/c').degraded).assertTrue();
      patterns.current = 'not json';
      expect(nav.newWindow('https://news.example.com/d').degraded).assertTrue();
      // 子框架：取消该子框架，不把整页降级（原页面保留）。
      const sub: ExternalNavOutcome = nav.navigate('https://news.example.com/e', ExternalNavFrame.SUBFRAME);
      expect(sub.cancel).assertTrue();
      expect(sub.degraded).assertFalse();
    });

    it('item27_bad_runtime_table_falls_back_to_valid_bundled_table', 0, () => {
      const patterns: Patterns = new Patterns();
      patterns.current = BAD_RULES;
      const nav: ExternalPageNavigator = navigator(patterns, RULES, []);
      const ok: ExternalNavOutcome = nav.mainFrame('https://news.example.com/a');
      expect(ok.cancel).assertFalse();
      const blocked: ExternalNavOutcome = nav.mainFrame('https://taobao.example.test/x');
      expect(blocked.cancel).assertTrue();
      expect(blocked.degraded).assertFalse();
    });

    it('item39_nav_host_sample_default_is_1000_and_explicit_zero_disables', 0, () => {
      expect(ExternalNavHooks.DEFAULT_SAMPLE_BP).assertEqual(1000);
      expect(ExternalNavHooks.sampleBpFrom(null)).assertEqual(1000);
      expect(ExternalNavHooks.sampleBpFrom('{}')).assertEqual(1000);
      expect(ExternalNavHooks.sampleBpFrom('not json')).assertEqual(1000);
      expect(ExternalNavHooks.sampleBpFrom('{"nav_host_sample_bp":-1}')).assertEqual(1000);
      expect(ExternalNavHooks.sampleBpFrom('{"nav_host_sample_bp":"100"}')).assertEqual(1000);
      expect(ExternalNavHooks.sampleBpFrom('{"nav_host_sample_bp":0}')).assertEqual(0);
      expect(ExternalNavHooks.sampleBpFrom('{"nav_host_sample_bp":250}')).assertEqual(250);
      // 缺省钩子也按 1000 抽样（不是 0 = 不抽样）。
      expect(new ExternalNavHooks().sampleBp()).assertEqual(1000);
      const sampled: string[] = [];
      const nav: ExternalPageNavigator = navigator(new Patterns(), RULES, sampled);
      nav.mainFrame('https://news.example.com/a');
      expect(JSON.stringify(sampled)).assertEqual('["example.com main"]');
    });

    it('item40_any_invalid_rule_invalidates_the_whole_table', 0, () => {
      expect(LinkRuleTable.parse(RULES) !== null).assertTrue();
      const bad: string[] = [
        '{"platform":"taobao","category":"shop","hosts":["a.example.test"],"path_patterns":[]}',
        '{"platform":"taobao","category":"union_host","hosts":["https://a.example.test"],"path_patterns":[]}',
        '{"platform":"taobao","category":"union_host","hosts":["a.example.test/path"],"path_patterns":[]}',
        '{"platform":"taobao","category":"union_host","hosts":["a.example.test:443"],"path_patterns":[]}'
      ];
      for (const rule of bad) {
        const table: string = '{"version":"x","rules":[' +
          '{"platform":"jd","category":"union_host","hosts":["jd.example.test"],"path_patterns":[]},' + rule + ']}';
        expect(LinkRuleTable.parse(table) === null).assertTrue();
      }
    });

    it('item41_refresh_window_without_live_callers_stops_continuing', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return refresh.promise;
        }
        return Promise.resolve(envelope(10002, '{}'));
      };
      let valid: boolean = true;
      const request: ApiRequest = new ApiRequest('getMe');
      request.owner = (): boolean => valid;
      const call: Promise<ApiResult> = rig.client.request(request);
      await flush();
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      // 唯一的调用方失效（如桥调用所在页面关闭）后，刷新请求收到 10402：不再重新注册、不再重放刷新，也不清会话。
      valid = false;
      refresh.resolve(envelope(10402, '{}'));
      const result: ApiResult = await call;
      await flush();
      expect(result.ok).assertFalse();
      expect(rig.registrar.calls).assertEqual(0);
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      expect(rig.tokens.accessToken()).assertEqual('old-access');
    });

    it('r1_09_element_full_screen_containing_video_keeps_title_bar', 0, () => {
      const windowCalls: boolean[] = [];
      const fs: WebFullScreen = new WebFullScreen((on: boolean): void => {
        windowCalls.push(on);
      });
      let exits: number = 0;
      // 一个包含小视频的 div 请求全屏：videoWidth / videoHeight 大于 0（描述的是元素里的视频，不是全屏元素本身）。
      // 确认不了是系统视频全屏：不隐藏标题栏、窗口不进全屏，立即退出元素全屏（共性 42 / 52 的保守降级）。
      expect(fs.onFullScreenEnter(1280, 720, (): void => {
        exits++;
      })).assertFalse();
      // canvas / div 没有视频：同样处理。
      expect(fs.onFullScreenEnter(undefined, undefined, (): void => {
        exits++;
      })).assertFalse();
      expect(fs.titleBarVisible()).assertTrue();
      expect(fs.webExpandsAllEdges()).assertFalse();
      expect(exits).assertEqual(2);
      expect(windowCalls.length).assertEqual(0);
      // 系统返回不被全屏态吞掉。
      expect(fs.back()).assertFalse();
    });

    it('r1_10_close_and_clear_stack_reply_before_teardown', 0, async () => {
      let page: number = 1;
      const order: string[] = [];
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.pageGeneration = (): number => page;
      // nav.close：关闭本容器（teardown：页面世代变化）。
      host.register('nav.close', BridgeHandlers.closeAfterReply((): void => {
        order.push('teardown');
        page++;
      }));
      // nav.open(Home)：Router 清栈，本容器出栈。
      host.register('nav.open', BridgeHandlers.navOpenAfterReply((_route: string, _params: Record<string, Object>,
        _update: UpdateState): BridgeRouteOpening => new BridgeRouteOpening(
        new GuardDecision(GuardDecisionKind.OPEN, 'Home', GuardReason.ALLOWED), (): void => {
          order.push('navigate');
          page++;
        })));
      const delivered: string[] = [];
      // 传输层入口（TrustedWebView.BridgeTransport.receive 用的就是 dispatch）：交出回复时记下顺序。
      const deliver = (reply: string): Promise<void> => {
        order.push('reply');
        delivered.push(reply);
        return Promise.resolve();
      };
      await host.dispatch(req('c1', 'nav.close'), new BridgeCaller(ORIGIN, true, false, 1), deliver);
      expect(delivered.length).assertEqual(1);
      expect(wire(delivered[0]).code).assertEqual(0);
      await host.dispatch(req('n1', 'nav.open', '{"route":"Home"}'), new BridgeCaller(ORIGIN, true, false, 2), deliver);
      expect(delivered.length).assertEqual(2);
      expect(wire(delivered[1]).code).assertEqual(0);
      // 先回复、再 teardown（共性 43 / 53）。
      expect(JSON.stringify(order)).assertEqual('["reply","teardown","reply","navigate"]');
      // 已出栈页面里别的在途调用照常作废（不回复）。
      await host.dispatch(req('e1', 'app.getEnv'), new BridgeCaller(ORIGIN, true, false, 1), deliver);
      expect(delivered.length).assertEqual(2);
    });

    it('r1_08_same_url_reload_is_a_document_navigation', 0, () => {
      const page: string = 'https://h5.example.test/act/index.html';
      // 同地址重新加载：换文档，放行时就作废旧调用。
      expect(BridgePageSession.startsNewDocument(page, page)).assertTrue();
      expect(BridgePageSession.startsNewDocument(page + '#top', page)).assertTrue();
      expect(BridgePageSession.startsNewDocument(page + '#top', page + '#top')).assertTrue();
      // 换地址：换文档。
      expect(BridgePageSession.startsNewDocument(page, 'https://h5.example.test/act/other.html')).assertTrue();
      expect(BridgePageSession.startsNewDocument('', page)).assertTrue();
      // 只有同一文档内的片段跳转不换文档。
      expect(BridgePageSession.startsNewDocument(page, page + '#rules')).assertFalse();
      expect(BridgePageSession.startsNewDocument(page + '#top', page + '#rules')).assertFalse();
    });

    it('item45_one_deadline_covers_update_wait_and_cancels_owned_requests', 0, async () => {
      const clock: ManualClock = new ManualClock();
      const state: FakeState = new FakeState();
      // 强更检查中：等待本身就消耗截止时间（nav.open 契约超时 10 秒）。
      state.status = UpdateCheckStatus.checking(clock.now());
      const host: BridgeHost = new BridgeHost(state, clock);
      const captured: BridgeCall[] = [];
      const expired: (() => boolean)[] = [];
      host.onCallExpired = (valid: () => boolean): void => {
        expired.push(valid);
      };
      host.register('nav.open', (call: BridgeCall): Promise<BridgeResult> => {
        captured.push(call);
        return new Promise<BridgeResult>((_resolve: (r: BridgeResult) => void) => {
          // 一直不回：模拟卡住的网络请求。
        });
      });
      const caller: BridgeCaller = new BridgeCaller(ORIGIN, true, false);
      const reply: Promise<string | null> = host.handle(req('n1', 'nav.open', '{"route":"Home"}'), caller);
      // 4 秒后强更有了结论，处理函数开始执行；剩余预算只有 6 秒（不是重新计 10 秒）。
      await clock.advance(4000);
      state.status = UpdateCheckStatus.finished(UpdateState.OK);
      await clock.advance(1000);
      expect(captured.length).assertEqual(1);
      expect(captured[0].valid()).assertTrue();
      await clock.advance(5000);
      expect(wire(await reply).code).assertEqual(90003);
      // 到截止时间：调用的有效性立即撤销，并交出守卫去取消它的在途请求。
      expect(captured[0].valid()).assertFalse();
      expect(expired.length).assertEqual(1);
    });

    it('item45_api_client_cancels_requests_of_an_expired_owner', 0, async () => {
      const rig: Rig = new Rig();
      const pending: Deferred = new Deferred();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => pending.promise;
      let valid: boolean = true;
      const owner: () => boolean = (): boolean => valid;
      const request: ApiRequest = new ApiRequest('getMe');
      request.owner = owner;
      const call: Promise<ApiResult> = rig.client.request(request);
      await flush();
      valid = false;
      expect(rig.client.cancelOwned(owner)).assertEqual(1);
      const result: ApiResult = await call;
      expect(result.ok).assertFalse();
      expect(rig.server.cancelled.length).assertEqual(1);
    });

    it('r1_11_expired_sole_caller_cancels_shared_refresh_transport', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return refresh.promise;
        }
        return Promise.resolve(envelope(10002, '{}'));
      };
      let valid: boolean = true;
      const owner: () => boolean = (): boolean => valid;
      const request: ApiRequest = new ApiRequest('getMe');
      request.owner = owner;
      let settled: boolean = false;
      const call: Promise<ApiResult> = rig.client.request(request).then((r: ApiResult): ApiResult => {
        settled = true;
        return r;
      });
      await flush();
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      // 唯一的桥调用到了截止时间：BridgeHost.onCallExpired → ApiClient.cancelOwned(call.valid)。
      valid = false;
      expect(rig.client.cancelOwned(owner)).assertEqual(1);
      expect(rig.server.cancelled.length).assertEqual(1);
      expect(rig.server.cancelled[0].url.indexOf('/v1/auth/refresh') >= 0).assertTrue();
      await flush();
      await flush();
      // 刷新以「没有结论」结束、等待结束，不清会话。
      expect(settled).assertTrue();
      expect((await call).ok).assertFalse();
      expect(rig.tokens.accessToken()).assertEqual('old-access');
    });

    it('r1_11_shared_refresh_kept_while_another_caller_is_valid', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return refresh.promise;
        }
        return Promise.resolve(envelope(10002, '{}'));
      };
      let firstValid: boolean = true;
      const first: () => boolean = (): boolean => firstValid;
      const second: () => boolean = (): boolean => true;
      const a: ApiRequest = new ApiRequest('getMe');
      a.owner = first;
      const b: ApiRequest = new ApiRequest('getMe');
      b.owner = second;
      rig.client.request(a);
      rig.client.request(b);
      await flush();
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      firstValid = false;
      expect(rig.client.cancelOwned(first)).assertEqual(0);
      expect(rig.server.cancelled.length).assertEqual(0);
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
      await flush();
      expect(rig.tokens.accessToken()).assertEqual('new-access');
    });

    it('item49_hit_means_rule_matched_independent_of_action', 0, () => {
      const promo: string = '{"version":"p","rules":[' +
        '{"platform":"taobao","category":"union_host","hosts":["taobao.example.test"],"path_patterns":[]},' +
        '{"platform":"taobao","category":"promo","hosts":["go.example.test"],"path_patterns":["^/promo"]}]}';
      const patterns: Patterns = new Patterns();
      patterns.current = promo;
      const sampled: string[] = [];
      const hooks: ExternalNavHooks = new ExternalNavHooks();
      hooks.random = (): number => 0;
      hooks.sampleBp = (): number => 10000;
      hooks.navHost = (domain: string, frame: string, hit: boolean): void => {
        sampled.push(domain + ' ' + frame + ' ' + hit);
      };
      const nav: ExternalPageNavigator = new ExternalPageNavigator(new ExternalNavPolicy(promo),
        (): string | null => patterns.current, hooks);
      // promo 放行（不拦），hit 仍为 true；不命中任何规则的为 false。
      expect(nav.mainFrame('https://go.example.test/promo/1').cancel).assertFalse();
      nav.mainFrame('https://news.example.com/');
      expect(JSON.stringify(sampled)).assertEqual('["example.test main true","example.com main false"]');
    });

    it('ruling_subframe_documents_are_cancelled_when_every_hop_cannot_be_intercepted', 0, () => {
      const nav: ExternalPageNavigator = navigator(new Patterns(), RULES, []);
      const sub: ExternalNavOutcome = nav.navigate('https://video.example.com/embed/1', ExternalNavFrame.SUBFRAME);
      expect(sub.cancel).assertTrue();
      expect(sub.notice).assertNull();
      expect(sub.degraded).assertFalse();
      expect(nav.navigate('about:blank', ExternalNavFrame.SUBFRAME).cancel).assertFalse();
      expect(nav.navigate('about:srcdoc', ExternalNavFrame.SUBFRAME).cancel).assertFalse();
      // 主框架照常加载。
      expect(nav.mainFrame('https://video.example.com/watch').cancel).assertFalse();
      // onInterceptRequest 补拦：子框架文档请求（Sec-Fetch-Dest）。
      expect(ExternalNavPolicy.isSubframeDocumentRequest(false, 'iframe')).assertTrue();
      expect(ExternalNavPolicy.isSubframeDocumentRequest(false, 'image')).assertFalse();
      expect(ExternalNavPolicy.isSubframeDocumentRequest(true, 'iframe')).assertFalse();
    });
    it('r2_04_destructive_navigation_waits_until_reply_script_has_run', 0, async () => {
      let page: number = 1;
      const order: string[] = [];
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.pageGeneration = (): number => page;
      host.register('nav.close', BridgeHandlers.closeAfterReply((): void => {
        order.push('teardown');
        page++;
      }));
      host.register('nav.open', BridgeHandlers.navOpenAfterReply((_route: string, _params: Record<string, Object>,
        _update: UpdateState): BridgeRouteOpening => new BridgeRouteOpening(
        new GuardDecision(GuardDecisionKind.OPEN, 'Home', GuardReason.ALLOWED), (): void => {
          order.push('navigate');
          page++;
        })));
      // 传输层（TrustedWebView.BridgeTransport.deliver 用的同一个 BridgeReplyChannel）：网页线程繁忙，runJavaScriptExt 的
      // Promise 迟迟不兑现。
      const scripts: string[] = [];
      let finish: () => void = (): void => {
      };
      const channel: BridgeReplyChannel = new BridgeReplyChannel((script: string): Promise<void> => {
        order.push('queued');
        scripts.push(script);
        return new Promise<void>((resolve: () => void): void => {
          finish = (): void => {
            order.push('executed');
            resolve();
          };
        });
      });
      const closing: Promise<void> = host.dispatch(req('c1', 'nav.close'), new BridgeCaller(ORIGIN, true, false, 1),
        (reply: string): Promise<void> => channel.deliver(reply));
      await flush();
      // 回复只是排进了执行队列：容器还不能关。
      expect(JSON.stringify(order)).assertEqual('["queued"]');
      expect(scripts[0].indexOf('window.__couliBridgeReceive(') >= 0).assertTrue();
      finish();
      await closing;
      expect(JSON.stringify(order)).assertEqual('["queued","executed","teardown"]');
      // nav.open(Home) 清栈同样等回复执行完。
      const opening: Promise<void> = host.dispatch(req('n1', 'nav.open', '{"route":"Home"}'),
        new BridgeCaller(ORIGIN, true, false, 2), (reply: string): Promise<void> => channel.deliver(reply));
      await flush();
      expect(order[order.length - 1]).assertEqual('queued');
      finish();
      await opening;
      expect(JSON.stringify(order.slice(3))).assertEqual('["queued","executed","navigate"]');
    });

    it('r2_04_wait_rechecks_page_and_survives_failed_reply_script', 0, async () => {
      let page: number = 1;
      const order: string[] = [];
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.pageGeneration = (): number => page;
      host.register('nav.close', BridgeHandlers.closeAfterReply((): void => {
        order.push('teardown');
        page++;
      }));
      // 回复脚本执行失败（页面已离开等）：F-HM-08（APP-04 共性 62）起不算「已执行」，放弃这次破坏性导航，dispatch 本身不抛出。
      const failing: BridgeReplyChannel = new BridgeReplyChannel((_s: string): Promise<void> =>
      Promise.reject(new Error('page gone')));
      await host.dispatch(req('c0', 'nav.close'), new BridgeCaller(ORIGIN, true, false, 1),
        (reply: string): Promise<void> => failing.deliver(reply));
      expect(JSON.stringify(order)).assertEqual('[]');
      // 脚本执行确认后才关闭。
      const ok: BridgeReplyChannel = new BridgeReplyChannel((_s: string): Promise<void> => Promise.resolve());
      await host.dispatch(req('c1', 'nav.close'), new BridgeCaller(ORIGIN, true, false, 1),
        (reply: string): Promise<void> => ok.deliver(reply));
      expect(JSON.stringify(order)).assertEqual('["teardown"]');
      // 等待期间页面已换（主框架导航走了）：不再执行这次调用的破坏性导航。
      let finish: () => void = (): void => {
      };
      const slow: BridgeReplyChannel = new BridgeReplyChannel((_s: string): Promise<void> =>
      new Promise<void>((resolve: () => void): void => {
        finish = resolve;
      }));
      const closing: Promise<void> = host.dispatch(req('c2', 'nav.close'), new BridgeCaller(ORIGIN, true, false, 2),
        (reply: string): Promise<void> => slow.deliver(reply));
      await flush();
      page++;
      finish();
      await closing;
      expect(JSON.stringify(order)).assertEqual('["teardown"]');
    });

    it('ruling_a_trusted_container_cancels_every_network_subframe_document_at_first_hop', 0, () => {
      const trusted: string[] = [ORIGIN];
      // 跨源 https 子框架：第一跳就取消（之后被 302 到可信源的那一跳不一定回调，不能靠它判定）。
      const cross: TrustedNavDecision = TrustedNavPolicy.decide('https://video.example.org/embed/1', false, trusted);
      expect(cross.action).assertEqual(TrustedNavAction.CANCEL);
      expect(cross.reason).assertEqual('subframe_network_document');
      expect(TrustedNavPolicy.decide('http://video.example.org/embed/1', false, trusted).cancel).assertTrue();
      expect(TrustedNavPolicy.decide(ORIGIN + '/act/frame.html', false, trusted).cancel).assertTrue();
      expect(TrustedNavPolicy.decide('data:text/html,<p>x</p>', false, trusted).cancel).assertTrue();
      // about:blank / about:srcdoc 不受影响。
      expect(TrustedNavPolicy.decide('about:blank', false, trusted).action).assertEqual(TrustedNavAction.LOAD);
      expect(TrustedNavPolicy.decide('about:srcdoc', false, trusted).action).assertEqual(TrustedNavAction.LOAD);
      // onInterceptRequest 的补充防线同口径：跨源子框架文档请求也拦。
      expect(TrustedNavPolicy.subframeDocumentBlocked('https://video.example.org/embed/1', false, 'iframe', trusted))
        .assertTrue();
      expect(TrustedNavPolicy.subframeDocumentBlocked('https://video.example.org/a.png', false, 'image', trusted))
        .assertFalse();
      // 主框架不变：可信页加载，白名单外 https 交外部容器。
      expect(TrustedNavPolicy.decide(ORIGIN + '/act/index.html', true, trusted).action).assertEqual(TrustedNavAction.LOAD);
      expect(TrustedNavPolicy.decide('https://example.com/', true, trusted).action)
        .assertEqual(TrustedNavAction.EXTERNAL);
    });

    it('ruling_b_external_container_cancels_main_frame_post_at_first_hop', 0, () => {
      const sampled: string[] = [];
      const nav: ExternalPageNavigator = navigator(new Patterns(), RULES, sampled);
      // 表单 POST：不论目标是哪里，第一跳取消、不提示、不降级（原页面保留）；不抽样、不进后续判定。
      const post: ExternalNavOutcome = nav.mainFrame('https://shop.example.com/checkout', 'POST');
      expect(post.cancel).assertTrue();
      expect(post.notice).assertNull();
      expect(post.degraded).assertFalse();
      expect(nav.mainFrame('https://shop.example.com/checkout', 'post').cancel).assertTrue();
      expect(nav.mainFrame('https://shop.example.com/checkout', null).cancel).assertTrue();
      expect(sampled.length).assertEqual(0);
      // GET 照常判定。
      expect(nav.mainFrame('https://shop.example.com/checkout', 'GET').cancel).assertFalse();
      expect(nav.mainFrame('https://shop.example.com/list').cancel).assertFalse();
      // 刚按新窗口放行的同一地址，若以 POST 到达也取消。
      expect(nav.newWindow('https://shop.example.com/w').cancel).assertFalse();
      expect(nav.mainFrame('https://shop.example.com/w', 'POST').cancel).assertTrue();
      // onInterceptRequest 的补充防线（主框架 POST 回 204）用同一判定。
      expect(ExternalNavPolicy.mainFrameMethodAllowed('GET')).assertTrue();
      expect(ExternalNavPolicy.mainFrameMethodAllowed('POST')).assertFalse();
      expect(ExternalNavPolicy.mainFrameMethodAllowed('PUT')).assertFalse();
      expect(ExternalNavPolicy.mainFrameMethodAllowed(null)).assertFalse();
    });
  });
}
