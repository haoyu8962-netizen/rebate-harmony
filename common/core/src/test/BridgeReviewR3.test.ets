// APP-04 鸿蒙第 3 轮评审（harmony-review-r3.md）的回归测试：每条都复现原场景，撤掉修复后对应用例失败。
// R3-01 桥发出的 ApiRequest 绑定调用有效性（刷新等待期间关页面或导航，请求不再发出）；R3-02 ui.setNavBar 全部参数生效、
// 系统栏接口失败回 90500；R3-03 ExternalPage 的 title、nav_style 从 Router 一路交给容器；R3-04 外部页视频全屏的状态模型。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiRequest, ApiResult, BridgeCaller, BridgeFrames, BridgeHandlers, BridgeHost, BridgePageSession, ExternalNavStyle,
  ExternalPageOptions, GuardDecision, GuardDecisionKind, GuardState, LocalRejectReason, MemoryPendingBackend, NavBarHandler, NavBarPort,
  NavBarState, PendingActionStore, RouteDestination, RouteNavigator, RouteRequest, Router, SessionTokenSet,
  StatusBarStyle, TransportRequest, TransportResponse, WebFullScreen
} from '../../Index';
import { Routes, RouteSpec } from 'generated';
import { FakeState, flush, MAIN_NO_TAP, ManualClock, req, wire } from './BridgeHost.test';
import { Deferred, envelope, Rig, tokenPair } from './NetworkTestRig';

const PAGE_URL: string = 'https://h5.example.test/rules/index.html';

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

const TOKENS: string[] = ['0123456789abcdef0123456789abcdef', 'fedcba9876543210fedcba9876543210',
  'aaaabbbbccccddddaaaabbbbccccdddd', 'ddddccccbbbbaaaaddddccccbbbbaaaa'];

/** 受限会话（deletion_only）：强更检查 supported 时，任何请求先等受限会话刷新屏障（refresh 由 deferred 控制）。 */
class RefreshWaitRig {
  readonly rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
  readonly refresh: Deferred = new Deferred();
  readonly session: BridgePageSession = sessionWith(TOKENS.slice());
  readonly host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());

  constructor() {
    this.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
      if (request.url.indexOf('/v1/auth/refresh') >= 0) {
        return this.refresh.promise;
      }
      if (request.url.indexOf('/v1/auth/h5-token') >= 0) {
        return Promise.resolve(envelope(0,
          '{"token":"h5-fixture","expire_at":"2026-10-07T12:00:00+08:00","scope":"standard"}'));
      }
      return Promise.resolve(envelope(0, '{"user_id":"u-1","nickname":"n","phone_bound":true}'));
    };
    this.session.rotate();
    this.host.pageGeneration = (): number => this.session.generation;
    const api = (request: ApiRequest): Promise<ApiResult> => this.rig.client.request(request);
    this.host.register('auth.getH5Token', BridgeHandlers.h5Token(api));
    this.host.register('auth.getUser', BridgeHandlers.user(api));
  }

  caller(): BridgeCaller {
    return BridgeFrames.callerOf(PAGE_URL, this.session.currentToken(), this.session, false);
  }

  finishRefresh(): void {
    this.refresh.resolve(envelope(0, tokenPair('fresh-access', 'fresh-refresh', 'full')));
  }
}

/** ui.setNavBar 的容器替身：记下换上的外观与系统栏调用。 */
class FakeNavBarPort implements NavBarPort {
  state: NavBarState = new NavBarState();
  shown: number = 0;
  statusBarCalls: string[] = [];
  statusBarResult: boolean = true;

  current(): NavBarState {
    return this.state;
  }

  show(next: NavBarState): void {
    this.state = next;
    this.shown++;
  }

  statusBar(style: string): Promise<boolean> {
    this.statusBarCalls.push(style);
    return Promise.resolve(this.statusBarResult);
  }
}

function navBarHost(port: FakeNavBarPort): BridgeHost {
  const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
  host.register('ui.setNavBar', NavBarHandler.of(port));
  return host;
}


class KeepingNavigator implements RouteNavigator {
  pushed: RouteDestination[] = [];

  push(destination: RouteDestination): void {
    this.pushed.push(destination);
  }

  reset(destinations: RouteDestination[]): void {
    this.pushed = destinations.slice();
  }

  requestConsent(): void {
  }
}

function routerWith(nav: KeepingNavigator): Router {
  const store: PendingActionStore = new PendingActionStore(new MemoryPendingBackend(), (): number => 1000000);
  return new Router(store, (): GuardState => new GuardState('consented', 'ok', 'logged_in', true, '1.0.0', false), nav,
    (name: string): RouteSpec | undefined => Routes.spec(name));
}

function externalParams(entries: [string, Object][]): Record<string, Object> {
  const out: Record<string, Object> = {};
  for (const e of entries) {
    out[e[0]] = e[1];
  }
  return out;
}

export default function bridgeReviewR3Test() {
  describe('BridgeReviewR3', () => {
    // ---------------------------------------------------------------- R3-01 / lessons 22
    it('r3_01_h5_token_waiting_for_refresh_is_not_sent_after_page_close', 0, async () => {
      const r: RefreshWaitRig = new RefreshWaitRig();
      const pending: Promise<string | null> = r.host.handle(req('a', 'auth.getH5Token'), r.caller());
      await flush();
      // 请求在等受限会话刷新：还没发出。
      expect(r.rig.client.refreshCalls).assertEqual(1);
      expect(r.rig.server.count('/v1/auth/h5-token')).assertEqual(0);
      // 等待期间页面关闭（容器销毁，令牌与世代作废）；之后刷新成功。
      r.session.invalidate();
      r.finishRefresh();
      expect(await pending).assertNull();
      await flush();
      expect(r.rig.server.count('/v1/auth/h5-token')).assertEqual(0);
      // 对照：没有离开的页面，刷新后照常发出。
      r.session.rotate();
      const reply: string | null = await r.host.handle(req('b', 'auth.getH5Token'), r.caller());
      expect(wire(reply).code).assertEqual(0);
      expect(r.rig.server.count('/v1/auth/h5-token')).assertEqual(1);
    });

    it('r3_01_get_user_waiting_for_refresh_is_not_sent_after_navigation', 0, async () => {
      const r: RefreshWaitRig = new RefreshWaitRig();
      const pending: Promise<string | null> = r.host.handle(req('a', 'auth.getUser'), r.caller());
      await flush();
      expect(r.rig.server.count('/v1/me')).assertEqual(0);
      // 等待期间主框架导航到新页面（onPageBegin → 新页面世代）。
      r.session.rotate();
      r.finishRefresh();
      expect(await pending).assertNull();
      await flush();
      expect(r.rig.server.count('/v1/me')).assertEqual(0);
    });

    it('r3_01_every_bridge_api_request_carries_call_validity_as_owner', 0, async () => {
      const session: BridgePageSession = sessionWith(TOKENS.slice());
      session.rotate();
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.pageGeneration = (): number => session.generation;
      const seen: ApiRequest[] = [];
      const api = (request: ApiRequest): Promise<ApiResult> => {
        seen.push(request);
        return Promise.resolve(ApiResult.rejected(LocalRejectReason.CANCELLED));
      };
      host.register('auth.getH5Token', BridgeHandlers.h5Token(api));
      host.register('auth.getUser', BridgeHandlers.user(api));
      await host.handle(req('a', 'auth.getH5Token'), BridgeFrames.callerOf(PAGE_URL, session.currentToken(), session,
        false));
      await host.handle(req('b', 'auth.getUser'), BridgeFrames.callerOf(PAGE_URL, session.currentToken(), session, false));
      expect(seen.length).assertEqual(2);
      for (const request of seen) {
        const owner: (() => boolean) | null = request.owner;
        expect(owner !== null).assertTrue();
        expect(owner !== null && owner()).assertTrue();
      }
      session.rotate();
      for (const request of seen) {
        const owner: (() => boolean) | null = request.owner;
        expect(owner !== null && owner()).assertFalse();
      }
    });

    // ---------------------------------------------------------------- R3-02 / lessons 23
    it('r3_02_every_set_nav_bar_param_takes_effect_in_container_state', 0, async () => {
      const port: FakeNavBarPort = new FakeNavBarPort();
      const host: BridgeHost = navBarHost(port);
      const reply: string | null = await host.handle(req('a', 'ui.setNavBar',
        '{"visible":true,"title":"T","bg_gradient":["#FF0000","#00FF00CC","#0000FF"],' +
          '"bg_image":"https://img.example.test/bar.png","text_color":"#FFFFFF","status_bar_style":"light",' +
          '"immersive":true,"hide_close":true,"hide_bottom_safe_area":true,"bounce":true}'), MAIN_NO_TAP);
      expect(wire(reply).code).assertEqual(0);
      const s: NavBarState = port.state;
      expect(port.shown).assertEqual(1);
      expect(s.title).assertEqual('T');
      expect(JSON.stringify(s.bgGradient)).assertEqual('["#FF0000","#00FF00CC","#0000FF"]');
      expect(s.bgImage).assertEqual('https://img.example.test/bar.png');
      expect(s.textColor).assertEqual('#FFFFFF');
      expect(s.statusBarStyle).assertEqual(StatusBarStyle.LIGHT);
      expect(JSON.stringify(port.statusBarCalls)).assertEqual('["light"]');
      expect(StatusBarStyle.contentColor(s.statusBarStyle)).assertEqual('#FFFFFF');
      expect(s.immersive && s.navBarOverlaysWeb() && s.webExpandsTop()).assertTrue();
      expect(s.hideClose).assertTrue();
      expect(s.hideBottomSafeArea && s.webExpandsBottom()).assertTrue();
      expect(s.bounce).assertTrue();
      expect(s.hasBackground()).assertTrue();
      // 背景是一组：只给 bg_color 时渐变与背景图清空；其余参数不变。
      expect(wire(await host.handle(req('b', 'ui.setNavBar', '{"bg_color":"#112233","status_bar_style":"dark",' +
        '"immersive":false,"hide_bottom_safe_area":false,"bounce":false,"visible":false}'), MAIN_NO_TAP)).code).assertEqual(0);
      const t: NavBarState = port.state;
      expect(t.bgColor).assertEqual('#112233');
      expect(t.bgGradient.length).assertEqual(0);
      expect(t.bgImage).assertEqual('');
      expect(t.title).assertEqual('T');
      expect(t.statusBarStyle).assertEqual(StatusBarStyle.DARK);
      expect(StatusBarStyle.contentColor(t.statusBarStyle)).assertEqual('#000000');
      expect(t.immersive || t.webExpandsTop() || t.webExpandsBottom() || t.bounce || t.visible).assertFalse();
      expect(t.navBarOverlaysWeb()).assertFalse();
      // 上一次的外观对象没有被就地改动（容器整体换新值才会重画）。
      expect(s.bgGradient.length).assertEqual(3);
    });

    it('r3_02_status_bar_failure_answers_90500_and_changes_nothing', 0, async () => {
      const port: FakeNavBarPort = new FakeNavBarPort();
      port.statusBarResult = false;
      const host: BridgeHost = navBarHost(port);
      const reply: string | null = await host.handle(req('a', 'ui.setNavBar',
        '{"title":"X","status_bar_style":"dark","bounce":true}'), MAIN_NO_TAP);
      expect(wire(reply).code).assertEqual(90500);
      expect(port.shown).assertEqual(0);
      expect(port.state.title).assertEqual('');
      expect(port.state.bounce).assertFalse();
      // 不带 status_bar_style 的调用不碰系统栏。
      port.statusBarCalls = [];
      expect(wire(await host.handle(req('b', 'ui.setNavBar', '{"title":"Y"}'), MAIN_NO_TAP)).code).assertEqual(0);
      expect(port.statusBarCalls.length).assertEqual(0);
      expect(port.state.title).assertEqual('Y');
    });

    // ---------------------------------------------------------------- R3-03 / lessons 24
    it('r3_03_external_page_title_and_nav_style_reach_container_options', 0, () => {
      const nav: KeepingNavigator = new KeepingNavigator();
      const router: Router = routerWith(nav);
      const decision: GuardDecision = router.open(new RouteRequest('ExternalPage', externalParams([
        ['url', 'https://help.example.com/a'], ['title', '帮助说明'], ['nav_style', 'dark']]), 'in_app'));
      expect(decision.kind).assertEqual(GuardDecisionKind.OPEN);
      expect(nav.pushed.length).assertEqual(1);
      // RootPage 把 NavPathStack 交来的参数原样交给 ExternalPageOptions.fromDestination，再整体进 ExternalWebConfig。
      const options: ExternalPageOptions = ExternalPageOptions.fromDestination(nav.pushed[0]);
      expect(options.url).assertEqual('https://help.example.com/a');
      expect(options.title).assertEqual('帮助说明');
      expect(options.navStyle).assertEqual(ExternalNavStyle.DARK);
      // 缺省：没有副标题、light。
      router.open(new RouteRequest('ExternalPage', externalParams([['url', 'https://help.example.com/b']]), 'in_app'));
      const plain: ExternalPageOptions = ExternalPageOptions.fromDestination(nav.pushed[1]);
      expect(plain.title).assertEqual('');
      expect(plain.navStyle).assertEqual(ExternalNavStyle.LIGHT);
      expect(ExternalPageOptions.of(externalParams([['url', 'https://a.example.com/'], ['nav_style', 'light']])).navStyle)
        .assertEqual(ExternalNavStyle.LIGHT);
      // 不是 Router 放进来的参数：什么都不取。
      expect(ExternalPageOptions.fromDestination(externalParams([['url', 'https://a.example.com/']])).url).assertEqual('');
    });

    // ---------------------------------------------------------------- R3-04 / lessons 25
    it('r3_04_video_full_screen_hides_title_bar_and_restores_on_exit', 0, () => {
      const windowCalls: boolean[] = [];
      const changes: boolean[] = [];
      const fs: WebFullScreen = new WebFullScreen((on: boolean): void => {
        windowCalls.push(on);
      });
      fs.onChange = (active: boolean): void => {
        changes.push(active);
      };
      expect(fs.titleBarVisible()).assertTrue();
      expect(fs.back()).assertFalse();
      // onFullScreenEnter：标题栏隐藏、网页铺满、窗口全屏。
      let exits: number = 0;
      fs.enter((): void => {
        exits++;
      });
      expect(fs.active).assertTrue();
      expect(fs.titleBarVisible()).assertFalse();
      expect(fs.webExpandsAllEdges()).assertTrue();
      // 重复进入不重复调窗口。
      fs.enter((): void => {
        exits++;
      });
      expect(JSON.stringify(windowCalls)).assertEqual('[true]');
      // onFullScreenExit：恢复。
      fs.exited();
      expect(fs.titleBarVisible()).assertTrue();
      expect(fs.webExpandsAllEdges()).assertFalse();
      expect(JSON.stringify(windowCalls)).assertEqual('[true,false]');
      fs.exited();
      expect(JSON.stringify(windowCalls)).assertEqual('[true,false]');
      // 全屏中系统返回：先请网页退出全屏并消费返回事件，标题栏恢复。
      fs.enter((): void => {
        exits++;
      });
      expect(fs.back()).assertTrue();
      expect(exits).assertEqual(1);
      expect(fs.titleBarVisible()).assertTrue();
      expect(JSON.stringify(windowCalls)).assertEqual('[true,false,true,false]');
      expect(JSON.stringify(changes)).assertEqual('[true,false,true,false]');
      // 窗口接口抛错不影响标题栏状态。
      const broken: WebFullScreen = new WebFullScreen((_on: boolean): void => {
        throw new Error('window unavailable');
      });
      broken.enter((): void => {
      });
      expect(broken.titleBarVisible()).assertFalse();
      broken.exited();
      expect(broken.titleBarVisible()).assertTrue();
    });
  });
}
