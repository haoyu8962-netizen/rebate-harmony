// APP-11 鸿蒙第 1 轮评审修复的回归测试（harmony-review-r1.md R1-01…R1-16）。接线照 entry：首页页面回调经 Core 的 HomeTicketPort（与
// AppHome.HomeControllerPort 同一个），卡片点击经真实 Router / StackNavigator，公告 api 来源与 previewPage 经真实 ApiClient
// （NetworkTestRig 的本地假服务）；HomePreview 的执行层 HomePreviewSession 只在 staging 源码集，按相对路径引入（rule-gaps H01）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientHomeNoticePort, AppEnvironment, HomeCardView, HomeClearResult, HomeController, HomeDeps, HomeErrorText,
  HomeFixedArea, HomeIdentity, HomeLevel, HomeLkgStore, HomeLocalStore, HomeNoticeCloseTicket, HomeNoticeDisplay,
  HomePopupImageTicket, HomePopupTicket, HomeRenderTicket, HomeSnapshot, HomeTap, MemoryHomeLkgBackend,
  MemoryHomePendingLedger, NoticeFilter, TransportRequest, TransportResponse, HomeContractPort, RouteRequest, RouteSource
} from '../../Index';
import { DefaultTexts } from 'generated';
import {
  HomeDebugSources, HomePreviewDeps, HomePreviewNav, HomePreviewSession, HomePreviewState
} from '../staging/ets/home/HomePreviewSession';
import { HomePreviewPolicy } from '../staging/ets/home/HomePreviewPolicy';
import { Deferred, envelope, Rig } from './NetworkTestRig';
import {
  ACTIVITY, banner, fail, FakeContract, GRID, HomeFixture, notice, ok, page, POPUP, product, settle, T0
} from './HomeIntegration.test';

const FEED: string = '{"id":"feed","type":"feed_infinite","version":1,"data_source":{"kind":"union_material",'
  + '"platforms":["taobao","jd","pdd"]}}';
const API_NOTICE: string = '{"id":"na","type":"notice_bar","version":1,"props":{"mode":"scroll"},"data_source":{"kind":"api"}}';

function articles(): string {
  const one: (id: string) => string = (id: string): string => '{"article_id":"a_' + id + '","category":"notice","title":"t","version":1,'
    + '"published_at":"2026-10-01T00:00:00+08:00","notice":{"item_id":"' + id + '","content_version":1,"text":"测试公告",'
    + '"target":null,"closable":true,"start_at":"2026-10-01T00:00:00+08:00","end_at":null}}';
  return '{"items":[' + one('N1') + ',' + one('N2') + '],"next_cursor":null}';
}

async function drain(n: number = 6): Promise<void> {
  for (let i: number = 0; i < n; i++) {
    await settle();
  }
}

/** 预览的导航替身：按实例 id 记录栈（栈顶在末尾）。 */
class FakePreviewNav implements HomePreviewNav {
  readonly stack: string[];
  readonly own: string;
  readonly calls: string[] = [];

  constructor(stack: string[], own: string) {
    this.stack = stack;
    this.own = own;
  }

  ownId(): string | null {
    return this.own;
  }

  topId(): string | null {
    return this.stack.length > 0 ? this.stack[this.stack.length - 1] : null;
  }

  pop(): void {
    this.calls.push('pop');
    this.stack.pop();
  }

  removeById(id: string): void {
    this.calls.push('remove:' + id);
    const i: number = this.stack.indexOf(id);
    if (i >= 0) {
      this.stack.splice(i, 1);
    }
  }
}

/** 预览会话的装配（与 entry HomePreviewPage 同一接线：真实 ApiClient、真实 Router）。 */
class PreviewRig {
  readonly rig: Rig = new Rig(null);
  readonly home: HomeFixture = new HomeFixture();
  identity: HomeIdentity = new HomeIdentity('test', HomeLevel.MEMBER, 'A', 's1');
  contract: HomeContractPort | null = null;
  states: HomePreviewState[] = [];
  snapshots: HomeSnapshot[] = [];
  forced: number = 0;

  constructor() {
    // 与首页测试同一测试时刻（公告生效区间从 2026-10-01 起）。
    this.rig.nowMillis = T0;
  }

  session(token: string = 'draft'): HomePreviewSession {
    const deps: HomePreviewDeps = new HomePreviewDeps((): HomeIdentity => this.identity, () => this.rig.client, 'home',
      token);
    deps.contract = (): HomeContractPort | null => this.contract;
    deps.clock = (): number => this.rig.nowMillis;
    deps.timer = this.home.timer;
    deps.open = (route: string, params: Record<string, Object>): void => {
      this.home.router.open(RouteReq.inApp(route, params));
    };
    deps.forceUpdate = (): void => {
      this.forced++;
    };
    const s: HomePreviewSession = new HomePreviewSession(deps);
    s.onState = (st: HomePreviewState): void => {
      this.states.push(st);
    };
    s.onSnapshot = (sn: HomeSnapshot): void => {
      this.snapshots.push(sn);
    };
    return s;
  }

  lastSnap(): HomeSnapshot {
    return this.snapshots.length > 0 ? this.snapshots[this.snapshots.length - 1] : new HomeSnapshot();
  }

  lastState(): HomePreviewState {
    return this.states[this.states.length - 1];
  }
}

class RouteReq {
  static inApp(route: string, params: Record<string, Object>): RouteRequest {
    return RouteRequest.of(route, RouteSource.IN_APP, params);
  }
}

function previewDraft(sections: string[]): string {
  return '{"page_key":"home","version":12,"sections":[' + sections.join(',') + ']}';
}

export default function homeFixR1Test() {
  describe('HomeFixR1', () => {
    // ---------------------------------------------------------------- R1-01 公告关闭回调的票据

    it('R1_01_old_close_after_env_switch_cleanup_not_persisted', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(7, [notice('nb', 'N1', 1, true, null)])));
      await settle();
      const close: HomeNoticeCloseTicket = f.card('nb').noticeRows[0].close as HomeNoticeCloseTicket;
      // 回调排队 → 切换环境：作废控制器、清理器清本机记录 → 回调执行。
      c.dispose();
      f.currentCtl = null;
      f.env = 'staging';
      expect(f.local.clear()).assertTrue();
      expect(f.port.closeNotice(close)).assertFalse();
      expect(f.local.closedKeys().length).assertEqual(0);
    });

    it('R1_01_old_close_after_privacy_withdraw_same_env_not_persisted_and_not_forwarded', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const a: HomeController = f.controller();
      a.start();
      f.contract.pages[0].resolve(ok(page(7, [notice('nb', 'N1', 1, true, null)])));
      await settle();
      const close: HomeNoticeCloseTicket = f.card('nb').noticeRows[0].close as HomeNoticeCloseTicket;
      // 撤回同意：清本机记录（世代 +1），按新身份重建；旧回调不落盘、也不转交新控制器。
      expect(f.local.clear()).assertTrue();
      f.identity = new HomeIdentity('test', HomeLevel.BASIC, null, 'b');
      a.dispose();
      const b: HomeController = f.controller();
      b.start();
      f.contract.pages[1].resolve(ok(page(7, [notice('nb', 'N1', 1, true, null)])));
      await settle();
      const before: number = f.snapshots.length;
      expect(f.port.closeNotice(close)).assertFalse();
      expect(f.local.closedKeys().length).assertEqual(0);
      expect(f.snapshots.length).assertEqual(before);
      expect(f.ids().indexOf('nb')).assertLarger(-1);
    });

    it('R1_01_readonly_ticket_never_persists', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.identity = new HomeIdentity('test', HomeLevel.BASIC, null, 'b');
      f.controller().start();
      f.contract.pages[0].resolve(ok(page(7, [notice('nb', 'N1', 1, true, null)])));
      await settle();
      const close: HomeNoticeCloseTicket = f.card('nb').noticeRows[0].close as HomeNoticeCloseTicket;
      expect(close.persist).assertFalse();
      f.port.closeNotice(close);
      expect(f.local.closedKeys().length).assertEqual(0);
      // 本次页面内存里隐藏（H10）。
      expect(f.ids().indexOf('nb')).assertEqual(-1);
    });

    // ---------------------------------------------------------------- R1-02 渲染时票据

    it('R1_02_old_popup_image_callbacks_after_switch_do_not_touch_B', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const a: HomeController = f.controller();
      a.start();
      f.contract.pages[0].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      const ticketA: HomePopupImageTicket = f.image();
      f.identity = new HomeIdentity('test', HomeLevel.MEMBER, 'B', 's2');
      a.dispose();
      const b: HomeController = f.controller();
      b.start();
      f.contract.pages[1].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      expect(f.last().popupCandidate?.id).assertEqual('pop');
      // A 的图片完成 / 失败在 B 之后执行：B 的图片还没好，不弹，也不被取消。
      f.port.popupImageLoaded(ticketA);
      expect(f.last().popup).assertNull();
      f.port.popupImageFailed(ticketA);
      expect(f.last().popupCandidate?.id).assertEqual('pop');
      f.port.popupImageLoaded(f.image());
      expect(f.last().popup?.id).assertEqual('pop');
    });

    it('R1_02_old_refresh_ticket_neither_refreshes_B_nor_reports_replaced', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const a: HomeController = f.controller();
      a.start();
      f.contract.pages[0].resolve(ok(page(5, [ACTIVITY])));
      await settle();
      const ticketA: HomeRenderTicket = f.last().ticket;
      f.identity = new HomeIdentity('test', HomeLevel.MEMBER, 'B', 's2');
      a.dispose();
      const b: HomeController = f.controller();
      b.start();
      f.contract.pages[1].resolve(ok(page(6, [ACTIVITY])));
      await settle();
      expect(await f.port.refresh(ticketA)).assertFalse();
      expect(f.contract.pages.length).assertEqual(2);
      // 刷新途中换号：结束动画但不报告「已替换」（界面不滚动）。
      const pulled: Promise<boolean> = f.port.refresh(f.last().ticket);
      expect(f.contract.pages.length).assertEqual(3);
      f.identity = new HomeIdentity('test', HomeLevel.GUEST, null, 's3');
      f.contract.pages[2].resolve(ok(page(9, [ACTIVITY])));
      expect(await pulled).assertFalse();
    });

    it('R1_02_tap_from_replaced_render_is_ignored', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(2, [banner('s', 'Search', '{"q":"纸巾"}')])));
      await settle();
      const old: HomeTap = f.card('s').bannerTaps[0];
      const pulled: Promise<boolean> = f.port.refresh(f.last().ticket);
      f.contract.pages[1].resolve(ok(page(3, [banner('s', 'Help', null)])));
      expect(await pulled).assertTrue();
      f.port.open(old);
      expect(f.stack.names.length).assertEqual(0);
      f.port.open(f.card('s').bannerTaps[0]);
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('Help');
    });

    // ---------------------------------------------------------------- R1-03 下拉刷新不安排弹窗

    it('R1_03_pull_refresh_to_popup_page_never_schedules_popup', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(5, [ACTIVITY])));
      await settle();
      const pulled: Promise<boolean> = c.pullRefresh(f.last().ticket);
      f.contract.pages[1].resolve(ok(page(10, [ACTIVITY, POPUP])));
      expect(await pulled).assertTrue();
      expect(f.last().popupCandidate).assertNull();
      expect(f.last().popupImage).assertNull();
    });

    it('R1_03_old_popup_image_after_refresh_to_page_without_popup_not_shown', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      const old: HomePopupImageTicket = f.image();
      const pulled: Promise<boolean> = c.pullRefresh(f.last().ticket);
      f.contract.pages[1].resolve(ok(page(11, [ACTIVITY])));
      await pulled;
      expect(f.last().popupCandidate).assertNull();
      c.popupImageLoaded(old);
      expect(f.last().popup).assertNull();
      c.blockersChanged();
      expect(f.last().popup).assertNull();
    });

    it('R1_03_late_network_replacement_reissues_candidate_and_rejects_old_image', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      // 包内默认（测试覆盖成带 popup 的页）先显示，之后冷启动的网络版到达且用户未交互 → 替换一次（G16 ③）。
      f.defaultJson = page(5, [ACTIVITY, POPUP]);
      const c: HomeController = f.controller();
      c.start();
      f.timer.advance(1500);
      const first: HomePopupImageTicket = f.image();
      f.contract.pages[0].resolve(ok(page(6, [ACTIVITY, POPUP])));
      await settle();
      expect(f.last().version).assertEqual(6);
      const second: HomePopupImageTicket = f.image();
      expect(second.candidate === first.candidate && second.render === first.render).assertFalse();
      c.popupImageLoaded(first);
      expect(f.last().popup).assertNull();
      c.popupImageLoaded(second);
      expect(f.last().popup?.id).assertEqual('pop');
    });

    // ---------------------------------------------------------------- R1-04 公告 42901 的共享闸门

    it('R1_04_notice_listArticles_42901_starts_shared_gate_silently', 0, async () => {
      const rig: Rig = new Rig(null);
      rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/articles') >= 0) {
          return Promise.resolve(envelope(42901, '{}', { 'Retry-After': '9' }));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const f: HomeFixture = new HomeFixture();
      const deps: HomeDeps = new HomeDeps(f.identity, (): string => f.identity.key, f.lkg, f.local, f.gate);
      deps.contract = f.contract;
      deps.notices = new ApiClientHomeNoticePort(() => rig.client);
      deps.clock = (): number => f.timer.now;
      deps.timer = f.timer;
      deps.toast = (key: string, trace: string): void => {
        f.toasts.push(key + '#' + trace);
      };
      const c: HomeController = new HomeController(deps);
      let last: HomeSnapshot = new HomeSnapshot();
      c.onChange = (s: HomeSnapshot): void => {
        last = s;
      };
      c.start();
      f.contract.pages[0].resolve(ok(page(8, [API_NOTICE, GRID])));
      await drain();
      // 先写共享闸门再隐藏公告卡；冷启动静默不提示。
      expect(f.gate.active).assertTrue();
      expect(last.refreshDisabled).assertTrue();
      expect(f.toasts.length).assertEqual(0);
      expect(last.cards.find((v: HomeCardView): boolean => v.card.id === 'na')?.hidden).assertTrue();
      // 页面层：下拉被拦下并提示一次；执行层：之后的卡片请求发包前被拒。
      await c.pullRefresh(last.ticket);
      expect(f.toasts[0].startsWith('error.42901')).assertTrue();
      expect(f.contract.pages.length).assertEqual(1);
      f.contract.items[0].resolve(ok('{"items":[],"next_cursor":null}'));
      await drain(2);
      f.timer.advance(9000);
      expect(f.gate.active).assertFalse();
    });

    // ---------------------------------------------------------------- R1-05 信息流首屏失败

    it('R1_05_feed_first_page_failure_keeps_retry_row_and_retry_is_gated', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(9, [ACTIVITY, FEED])));
      await settle();
      f.contract.items[0].resolve(fail(50001));
      await settle();
      const v: HomeCardView = f.card('feed');
      expect(v.hidden).assertFalse();
      expect(v.feedFailed).assertTrue();
      expect(v.products.length).assertEqual(0);
      expect(v.retryDisabled).assertFalse();
      // 重试也 42901：闸门生效、重试行仍在且禁用；闸门期内再点不发。
      c.retrySection(f.card('feed').section);
      expect(f.card('feed').hidden).assertFalse();
      f.contract.items[1].resolve(fail(42901));
      await settle();
      expect(f.card('feed').hidden).assertFalse();
      expect(f.card('feed').retryDisabled).assertTrue();
      c.retrySection(f.card('feed').section);
      expect(f.contract.items.length).assertEqual(2);
      f.timer.advance(5000);
      c.retrySection(f.card('feed').section);
      f.contract.items[2].resolve(ok('{"items":[' + product('a', null) + '],"next_cursor":null}'));
      await settle();
      expect(f.card('feed').products.length).assertEqual(1);
      // 成功但为空：整张卡隐藏。
      const g: HomeFixture = new HomeFixture();
      g.controller().start();
      g.contract.pages[0].resolve(ok(page(9, [ACTIVITY, FEED])));
      await settle();
      g.contract.items[0].resolve(ok('{"items":[],"next_cursor":null}'));
      await settle();
      expect(g.card('feed').hidden).assertTrue();
    });

    // ---------------------------------------------------------------- R1-06 待清理标记写不进

    it('R1_06_marker_and_delete_both_fail_restart_still_blocks_old_lkg', 0, async () => {
      const backend: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
      const ledger: MemoryHomePendingLedger = new MemoryHomePendingLedger();
      const store: HomeLkgStore = new HomeLkgStore(backend, ledger);
      store.save('test:user:A', page(1, [ACTIVITY]));
      backend.failPending = true;
      backend.failClear = true;
      expect(store.clearScopeResult('test:user:A')).assertEqual(HomeClearResult.PENDING);
      expect(ledger.value).not().assertNull();
      // 进程退出 → 存储恢复 → 重新登录 A：重启后的 store 先按第二通道补清，不读回旧 LKG。
      backend.failPending = false;
      const restarted: HomeLkgStore = new HomeLkgStore(backend, ledger);
      backend.failClear = true;
      expect(restarted.load('test:user:A')).assertNull();
      backend.failClear = false;
      expect(restarted.load('test:user:A')).assertNull();
      expect(backend.files.size).assertEqual(0);
      expect(ledger.value).assertNull();
      expect(backend.pending).assertNull();
    });

    it('R1_06_no_record_channel_falls_back_to_tombstone_or_reports_volatile', 0, async () => {
      const backend: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
      const ledger: MemoryHomePendingLedger = new MemoryHomePendingLedger();
      const store: HomeLkgStore = new HomeLkgStore(backend, ledger);
      store.save('test:user:A', page(1, [ACTIVITY]));
      backend.failPending = true;
      ledger.fail = true;
      backend.failClear = true;
      // 两条记录通道都写不进、删不掉：就地写墓碑；重启后读到墓碑按没有。
      expect(store.clearScopeResult('test:user:A')).assertEqual(HomeClearResult.PENDING);
      backend.failPending = false;
      ledger.fail = false;
      backend.failClear = false;
      expect(new HomeLkgStore(backend, ledger).load('test:user:A')).assertNull();
      // 连墓碑都写不进：上报 VOLATILE 给协调器，本进程阻断读取。
      const b2: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
      const l2: MemoryHomePendingLedger = new MemoryHomePendingLedger();
      const s2: HomeLkgStore = new HomeLkgStore(b2, l2);
      s2.save('test:user:A', page(1, [ACTIVITY]));
      b2.failPending = true;
      l2.fail = true;
      b2.failClear = true;
      b2.failWrite = true;
      expect(s2.clearScopeResult('test:user:A')).assertEqual(HomeClearResult.VOLATILE);
      expect(s2.hasVolatilePending).assertTrue();
      expect(s2.load('test:user:A')).assertNull();
    });

    // ---------------------------------------------------------------- R1-07 关闭记录不按条数淘汰

    it('R1_07_closing_200_more_notices_keeps_first_close', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      expect(f.local.addClosed(NoticeFilter.closeKey('nb', 'N0', 1))).assertTrue();
      for (let i: number = 1; i <= 200; i++) {
        expect(f.local.addClosed(NoticeFilter.closeKey('other', 'N' + i, 1))).assertTrue();
      }
      expect(f.local.closedKeys().indexOf(NoticeFilter.closeKey('nb', 'N0', 1))).assertLarger(-1);
      f.lkg.save(f.identity.scope, page(7, [notice('nb', 'N0', 1, true, null), ACTIVITY]));
      f.withContract = false;
      f.controller().start();
      expect(f.ids().join(',')).assertEqual('entries');
    });

    // ---------------------------------------------------------------- R1-08 只读不等于基本模式

    it('R1_08_readonly_open_keeps_search_and_clipboard_basic_only_by_privacy', 0, async () => {
      const readonlyConsented: HomeFixedArea = HomeFixedArea.of(false, false);
      expect(readonlyConsented.search).assertTrue();
      expect(readonlyConsented.clipboard).assertTrue();
      expect(readonlyConsented.basicNotice).assertFalse();
      const basic: HomeFixedArea = HomeFixedArea.of(true, false);
      expect(basic.basicNotice).assertTrue();
      expect(basic.search).assertFalse();
      const preview: HomeFixedArea = HomeFixedArea.of(false, true);
      expect(preview.search || preview.clipboard || preview.basicNotice).assertFalse();
    });

    // ---------------------------------------------------------------- R1-09 / R1-10 预览数据源

    it('R1_09_preview_fake_source_only_when_enabled_and_env_allows', 0, async () => {
      const fake: FakeContract = new FakeContract();
      expect(HomeDebugSources.contract(true, AppEnvironment.PROD, fake)).assertNull();
      expect(HomeDebugSources.contract(false, AppEnvironment.TEST, fake)).assertNull();
      expect(HomeDebugSources.contract(true, undefined, fake)).assertNull();
      expect(HomeDebugSources.contract(true, AppEnvironment.TEST, fake) === fake).assertTrue();
      // prod（数据源为 null）：草稿里的商品池卡按空数据隐藏，不发 listSectionItems。
      const p: PreviewRig = new PreviewRig();
      p.contract = HomeDebugSources.contract(true, AppEnvironment.PROD, fake);
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, previewDraft([GRID, ACTIVITY])));
      const s: HomePreviewSession = p.session();
      await s.load();
      await drain(2);
      expect(p.lastState().screen).assertEqual(HomePreviewPolicy.DRAFT);
      expect(fake.items.length).assertEqual(0);
      const grid: HomeCardView | undefined = p.lastSnap().cards.find((v: HomeCardView): boolean => v.card.id === 'grid');
      expect(grid?.hidden).assertTrue();
    });

    it('R1_10_preview_notice_api_uses_current_env_api_client', 0, async () => {
      const p: PreviewRig = new PreviewRig();
      p.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/articles') >= 0) {
          return Promise.resolve(envelope(0, articles()));
        }
        return Promise.resolve(envelope(0, previewDraft([API_NOTICE])));
      };
      const s: HomePreviewSession = p.session();
      await s.load();
      await drain();
      expect(p.rig.server.last('/v1/articles').url.indexOf('category=notice')).assertLarger(-1);
      const na: HomeCardView | undefined = p.lastSnap().cards.find((v: HomeCardView): boolean => v.card.id === 'na');
      expect(na?.hidden).assertFalse();
      expect(na?.notices.length).assertEqual(2);
      // 预览里的关闭只在内存（不落盘）。
      const close: HomeNoticeCloseTicket = na?.noticeRows[0].close as HomeNoticeCloseTicket;
      expect(close.persist).assertFalse();
      expect(s.port.closeNotice(close)).assertFalse();
    });

    // ---------------------------------------------------------------- R1-11 实例隔离

    it('R1_11_two_preview_instances_do_not_share_state_or_exits', 0, async () => {
      const p: PreviewRig = new PreviewRig();
      const deferredA: Deferred = new Deferred();
      let call: number = 0;
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        call++;
        return call === 1 ? deferredA.promise : Promise.resolve(envelope(0, previewDraft([ACTIVITY])));
      };
      const a: HomePreviewSession = p.session('a');
      const statesA: HomePreviewState[] = [];
      a.onState = (st: HomePreviewState): void => {
        statesA.push(st);
      };
      const loadingA: Promise<void> = a.load();
      const b: HomePreviewSession = p.session('b');
      const snapsB: HomeSnapshot[] = [];
      b.onSnapshot = (sn: HomeSnapshot): void => {
        snapsB.push(sn);
      };
      await b.load();
      await drain(2);
      const bVersion: number = snapsB[snapsB.length - 1].version;
      deferredA.resolve(envelope(0, previewDraft([banner('x', 'Help', null)])));
      await loadingA;
      await drain(2);
      expect(snapsB[snapsB.length - 1].version).assertEqual(bVersion);
      expect(snapsB[snapsB.length - 1].cards.map((v: HomeCardView): string => v.card.id).join(',')).assertEqual('entries');
      // A 离开不清 B。
      const before: number = snapsB.length;
      a.leave();
      expect(snapsB.length).assertEqual(before);
      expect(b.alive()).assertTrue();
      expect(a.instance === b.instance).assertFalse();
    });

    // ---------------------------------------------------------------- R1-12 按实例退出

    it('R1_12_exit_only_own_instance_never_reopens_home', 0, async () => {
      const p: PreviewRig = new PreviewRig();
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, previewDraft([ACTIVITY])));
      const a: HomePreviewSession = p.session('a');
      const b: HomePreviewSession = p.session('b');
      const stack: string[] = ['nav-a', 'nav-b'];
      // 被盖住的 A 退出：只按 id 移除 A，不弹 B。
      const navA: FakePreviewNav = new FakePreviewNav(stack, 'nav-a');
      a.exit(navA);
      expect(navA.calls.join(',')).assertEqual('remove:nav-a');
      expect(stack.join(',')).assertEqual('nav-b');
      // 栈顶的 B 退出：pop；之后不打开 Home（停在原来的 Tab）。
      const navB: FakePreviewNav = new FakePreviewNav(stack, 'nav-b');
      b.exit(navB);
      expect(navB.calls.join(',')).assertEqual('pop');
      expect(stack.length).assertEqual(0);
      expect(p.home.stack.names.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- R1-13 固定身份与同步出口

    it('R1_13_identity_change_invalidates_preview_and_drops_late_results', 0, async () => {
      const p: PreviewRig = new PreviewRig();
      const fake: FakeContract = new FakeContract();
      p.contract = fake;
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, previewDraft([GRID])));
      const s: HomePreviewSession = p.session();
      await s.load();
      await drain(2);
      expect(fake.items.length).assertEqual(1);
      // 会话换代（同一账号、网络层归属键变了）：同步时立即作废。
      p.identity = new HomeIdentity('test', HomeLevel.MEMBER, 'A', 's2');
      s.identityChanged();
      expect(p.lastState().screen).assertEqual(HomePreviewSession.STALE);
      const n: number = p.snapshots.length;
      fake.items[0].resolve(ok('{"items":[' + product('a', null) + '],"next_cursor":null}'));
      await drain(2);
      expect(p.snapshots.length).assertEqual(n);
      expect(fake.cancelled.length).assertEqual(1);
    });

    it('R1_13_leave_on_will_disappear_cancels_inflight_preview_request', 0, async () => {
      const p: PreviewRig = new PreviewRig();
      const d: Deferred = new Deferred();
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => d.promise;
      const s: HomePreviewSession = p.session();
      const loading: Promise<void> = s.load();
      await drain(1);
      const states: number = p.states.length;
      s.leave();
      expect(p.rig.server.cancelled.length).assertEqual(1);
      d.resolve(envelope(0, previewDraft([ACTIVITY])));
      await loading;
      expect(p.states.length).assertEqual(states);
      expect(p.lastSnap().cards.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- R1-14 弹窗的系统返回

    it('R1_14_back_closes_preview_popup_first_then_passes_through', 0, async () => {
      const p: PreviewRig = new PreviewRig();
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, previewDraft([ACTIVITY, POPUP])));
      const s: HomePreviewSession = p.session();
      // 页面已显示（NavDestination.onShown，R2-03：不可见的预览不弹）。
      s.shown();
      await s.load();
      await drain(2);
      s.port.popupImageLoaded(p.lastSnap().popupImage as HomePopupImageTicket);
      expect(p.lastSnap().popup?.id).assertEqual('pop');
      expect(s.back()).assertTrue();
      expect(p.lastSnap().popup).assertNull();
      expect(s.back()).assertFalse();
      // 首页同一套：出口的系统返回先关弹窗。
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      f.port.popupImageLoaded(f.image());
      expect(f.port.backPressed()).assertTrue();
      expect(f.last().popup).assertNull();
      expect(f.port.backPressed()).assertFalse();
    });

    // ---------------------------------------------------------------- R1-15 预览错误分流

    it('R1_15_preview_42901_keeps_code_text_and_gates_retry', 0, async () => {
      const p: PreviewRig = new PreviewRig();
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(42901, '{}', { 'Retry-After': '7' }));
      const s: HomePreviewSession = p.session();
      await s.load();
      expect(p.lastState().screen).assertEqual(HomePreviewPolicy.ERROR);
      expect(p.lastState().errorText).assertEqual(DefaultTexts.text('error.42901') as string);
      expect(p.lastState().retryDisabled).assertTrue();
      const sent: number = p.rig.server.count('/preview');
      s.retry();
      await drain(2);
      expect(p.rig.server.count('/preview')).assertEqual(sent);
      p.rig.nowMillis += 7000;
      s.retry();
      await drain(2);
      expect(p.rig.server.count('/preview')).assertEqual(sent + 1);
    });

    it('R1_15_server_error_trace6_appended_independently', 0, async () => {
      const p: PreviewRig = new PreviewRig();
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(50303, '{}'));
      const s: HomePreviewSession = p.session();
      await s.load();
      // error.50303 的文案没有 {trace6} 占位：仍独立追加末 6 位（trace-abcdef123456 → 123456）。
      expect(p.lastState().errorText).assertEqual((DefaultTexts.text('error.50303') as string) + '（123456）');
      expect(HomeErrorText.message('error.50001', 'trace-abcdef123456')).assertEqual('出了点问题，请稍后再试（123456）');
      expect(HomeErrorText.message('error.50001', '')).assertEqual('出了点问题，请稍后再试');
      expect(HomeErrorText.message('error.42901', 'trace-abcdef123456')).assertEqual('操作太频繁，请稍后再试');
      expect(HomeErrorText.message('error.59999', 'trace-abcdef123456')).assertEqual('出了点问题，请稍后再试（123456）');
    });

    // ---------------------------------------------------------------- R1-16 公告 scroll 模式

    it('R1_16_notice_scroll_mode_rendered_separately_and_stops_for_screen_reader', 0, async () => {
      expect(HomeNoticeDisplay.of('scroll', 2, false, true).kind).assertEqual(HomeNoticeDisplay.SCROLL);
      expect(HomeNoticeDisplay.of('scroll', 2, false, true).autoplay).assertTrue();
      expect(HomeNoticeDisplay.of('scroll', 2, true, true).autoplay).assertFalse();
      expect(HomeNoticeDisplay.of('scroll', 2, false, false).autoplay).assertFalse();
      expect(HomeNoticeDisplay.of('scroll', 1, false, true).kind).assertEqual(HomeNoticeDisplay.STATIC);
      expect(HomeNoticeDisplay.of('static', 3, false, true).kind).assertEqual(HomeNoticeDisplay.STATIC);
      // 解码保留 mode，渲染视图把它交给界面。
      const p: PreviewRig = new PreviewRig();
      p.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/articles') >= 0) {
          return Promise.resolve(envelope(0, articles()));
        }
        return Promise.resolve(envelope(0, previewDraft([API_NOTICE])));
      };
      const s: HomePreviewSession = p.session();
      await s.load();
      await drain();
      const na: HomeCardView | undefined = p.lastSnap().cards.find((v: HomeCardView): boolean => v.card.id === 'na');
      expect(na?.card.noticeMode).assertEqual('scroll');
      expect(HomeNoticeDisplay.of(na?.card.noticeMode ?? '', na?.noticeRows.length ?? 0, false, true).kind)
        .assertEqual(HomeNoticeDisplay.SCROLL);
    });

    // 公告关闭票据在同一环境、同一清理世代内照常落盘（G11 既定规则，R1-01 的对照）。
    it('R1_01_control_same_env_same_generation_persists', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.controller().start();
      f.contract.pages[0].resolve(ok(page(7, [notice('nb', 'N1', 1, true, null)])));
      await settle();
      const close: HomeNoticeCloseTicket = f.card('nb').noticeRows[0].close as HomeNoticeCloseTicket;
      expect(f.port.closeNotice(close)).assertTrue();
      expect(f.local.closedKeys().indexOf(close.key)).assertLarger(-1);
      expect(f.ids().indexOf('nb')).assertEqual(-1);
      // 本机记录与弹窗计数的票据形状（防止回退成只按 owner 判断）。
      const popupT: HomePopupTicket = new HomePopupTicket(1, 1, 'pop', 'x', null);
      expect(popupT.key).assertEqual('1:1');
      const lsCheck: HomeLocalStore = new HomeLocalStore();
      const gen: number = lsCheck.generation;
      lsCheck.clear();
      expect(lsCheck.generation).assertEqual(gen + 1);
    });
  });
}
