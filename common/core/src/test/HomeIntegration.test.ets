// APP-11 鸿蒙首页 SDUI 的本地假服务集成测试（brief §2.19）：Core 执行器 HomeController（页面按钮回调调用的同一套方法）+ 本地假服务
// （待定接口 getPage / listSectionItems 的测试替身；listArticles 经真实 ApiClient 与 NetworkTestRig 的假服务）+ 真实 Router / StackNavigator
// （卡片点击经 Router 打开，断言导航栈与参数值、入口 in_app）。测试值照 Main 稿与向量的测试数据；不连任何地址。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientHomeNoticePort, ApiOutcome, ApiResult, CardErrorDedupe, EffectKind, ErrorEffect, GuardState, ReplayKind,
  HomeAction, HomeCardType, HomeCardView, HomeContractPort, HomeController, HomeDataCleaner, HomeDeps, HomeIdentity,
  HomeLevel, HomeLkgStore, HomeLocalStore, HomeShowing, HomeSnapshot, HomeTimer, LaunchReadiness, LocalDataCleanerRegistry,
  MemoryHomeClearMark, MemoryHomeLkgBackend, MemoryHomePrefsBackend, MemoryPendingBackend, NoticeFilter, PendingActionStore,
  PopupBlocker, PrivacyState, RetryAfterGate, RouteDestination, Router, RouteTable, StackNavigator, TransportFailure,
  TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState, UPGRADE_PROMPT_PAGE, RouteRequest, RouteSource,
  HomeTicketPort, HomeTap, HomePopupImageTicket, HomePopupTicket, HomeNoticeCloseTicket
} from '../../Index';
import { ClientEvent, DefaultHomePage, RouteSpec } from 'generated';
import { envelope, flush, header, Rig } from './NetworkTestRig';
import { ParamStack, TAB_ROOTS } from './OrderIntegration.test';

export const T0: number = Date.parse('2026-10-10T10:00:00+08:00');

/** 手动推进的计时器（1.5 秒等待、公告到期重算）。 */
export class ManualTimer implements HomeTimer {
  now: number = T0;
  private serial: number = 0;
  private tasks: Map<number, [number, () => void]> = new Map<number, [number, () => void]>();

  schedule(ms: number, run: () => void): number {
    this.serial++;
    this.tasks.set(this.serial, [this.now + ms, run]);
    return this.serial;
  }

  cancel(id: number): void {
    this.tasks.delete(id);
  }

  advance(ms: number): void {
    this.now += ms;
    const due: number[] = [];
    this.tasks.forEach((v: [number, () => void], k: number) => {
      if (v[0] <= this.now) {
        due.push(k);
      }
    });
    for (const k of due) {
      const t: [number, () => void] | undefined = this.tasks.get(k);
      this.tasks.delete(k);
      if (t !== undefined) {
        t[1]();
      }
    }
  }
}

export class PageCall {
  readonly anonymous: boolean;
  readonly resolve: (r: ApiResult) => void;

  constructor(anonymous: boolean, resolve: (r: ApiResult) => void) {
    this.anonymous = anonymous;
    this.resolve = resolve;
  }
}

export class ItemsCall {
  readonly sectionId: string;
  readonly cursor: string | null;
  readonly anonymous: boolean;
  readonly resolve: (r: ApiResult) => void;

  constructor(sectionId: string, cursor: string | null, anonymous: boolean, resolve: (r: ApiResult) => void) {
    this.sectionId = sectionId;
    this.cursor = cursor;
    this.anonymous = anonymous;
    this.resolve = resolve;
  }
}

/** getPage / listSectionItems 的测试替身：请求挂起，测试决定何时、以什么结果到达。 */
export class FakeContract implements HomeContractPort {
  pages: PageCall[] = [];
  items: ItemsCall[] = [];
  blocked: number = 0;
  cancelled: number[] = [];

  getPage(_pageKey: string, anonymous: boolean, sendAllowed: () => boolean): Promise<ApiResult> {
    if (!sendAllowed()) {
      this.blocked++;
      return Promise.resolve(ApiResult.rejected('send_blocked'));
    }
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void) => {
      this.pages.push(new PageCall(anonymous, resolve));
    });
  }

  listSectionItems(_pageKey: string, sectionId: string, cursor: string | null, anonymous: boolean,
    sendAllowed: () => boolean): Promise<ApiResult> {
    if (!sendAllowed()) {
      this.blocked++;
      return Promise.resolve(ApiResult.rejected('send_blocked'));
    }
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void) => {
      this.items.push(new ItemsCall(sectionId, cursor, anonymous, resolve));
    });
  }

  cancel(owner: number): void {
    this.cancelled.push(owner);
  }
}

export function ok(json: string): ApiResult {
  return new ApiResult(ApiOutcome.SUCCESS, 0, '', JSON.parse(json) as Record<string, Object>, 'trace-home-0a1b2c', 200,
    TransportFailure.NONE, null, null, null);
}

export function fail(code: number, trace: string = 'test-trace-ABC123', effect: ErrorEffect | null = null): ApiResult {
  return new ApiResult(ApiOutcome.BUSINESS_ERROR, code, '', {}, trace, 500, TransportFailure.NONE, null, effect, null);
}

export function page(version: number, sections: string[]): string {
  return '{"page_key":"home","version":' + version + ',"sections":[' + sections.join(',') + ']}';
}

export const ACTIVITY: string = '{"id":"entries","type":"activity_entry","version":1,"props":{},"data_source":{"kind":"static",'
  + '"items":[{"title":"测试入口","action":{"route":"Help"}}]}}';

export function banner(id: string, route: string, params: string | null, label: string | null = null): string {
  return '{"id":"' + id + '","type":"banner","version":1' + (label === null ? '' : ',"ad_label":"' + label + '"')
    + ',"props":{"height_ratio":0.4,"autoplay_ms":0},"data_source":{"kind":"static","items":[{"image":'
    + '"https://img.example.com/' + id + '.png","action":{"route":"' + route + '"' + (params === null ? '' : ',"params":' + params)
    + '}}]}}';
}

export function notice(id: string, itemId: string, version: number, closable: boolean, end: string | null): string {
  return '{"id":"' + id + '","type":"notice_bar","version":1,"props":{"items":[{"item_id":"' + itemId + '","content_version":'
    + version + ',"text":"测试公告","target":null,"closable":' + closable + ',"start_at":"2026-10-01T00:00:00+08:00",'
    + '"end_at":' + (end === null ? 'null' : '"' + end + '"') + '}]},"data_source":{"kind":"static"}}';
}

export const POPUP: string = '{"id":"pop","type":"popup","version":1,"props":{"image":"https://img.example.com/popup.png","daily_max":1,'
  + '"time_window":["09:00","22:00"]},"data_source":{"kind":"static","items":[{"action":{"route":"AuthSheet","params":'
  + '{"platform":"taobao"}}}]}}';
export const GRID: string = '{"id":"grid","type":"product_grid","version":1,"props":{"columns":2,"title":"测试"},'
  + '"data_source":{"kind":"product_pool","pool_id":"p"}}';
export const SCROLL: string = '{"id":"scroll","type":"product_scroll","version":1,"props":{"title":"测试"},'
  + '"data_source":{"kind":"product_pool","pool_id":"q"}}';

export function product(key: string, ad: string | null): string {
  return '{"product_key":"tb:' + key + '","item_ref":"v1.tb.' + key + '.sig","platform":"taobao","title":"测试商品' + key
    + '","image":null,"price_fen":1990,"coupon_fen":0,"final_price_fen":1990,"est_net_price_fen":1880,"rebate_min_fen":110,'
    + '"rebate_max_fen":110,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,"link_id":null,'
    + '"cta":{"text_key":"btn.buy"},"quoted_at":"2026-10-10T09:59:00+08:00","stale":false,"age_sec":60,'
    + '"source":"taobao_union","disclaimer_keys":["price_basis.general"],"availability":"ok","ad_label":'
    + (ad === null ? 'null' : '"' + ad + '"') + '}';
}

/** 首页执行层 + 真实 Router 的装配（与 entry AppHome 同一接线：卡片点击经 Router 打开）。 */
export class HomeFixture {
  readonly timer: ManualTimer = new ManualTimer();
  readonly contract: FakeContract = new FakeContract();
  readonly lkgBackend: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
  readonly lkg: HomeLkgStore;
  readonly prefs: MemoryHomePrefsBackend = new MemoryHomePrefsBackend();
  readonly mark: MemoryHomeClearMark = new MemoryHomeClearMark();
  readonly local: HomeLocalStore = new HomeLocalStore();
  readonly stack: ParamStack = new ParamStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly dedupe: CardErrorDedupe = new CardErrorDedupe();
  readonly gate: RetryAfterGate;
  identity: HomeIdentity = new HomeIdentity('test', HomeLevel.MEMBER, 'A', 's1');
  events: ClientEvent[] = [];
  toasts: string[] = [];
  forced: number = 0;
  blockers: string[] = [];
  /** 非空时控制器的 blockers 改读它（R3 用例按 entry 的 HomeVisibilityHub 接线）。 */
  blockersFn: (() => string[]) | null = null;
  shownThisRun: boolean = false;
  defaultJson: string | null = DefaultHomePage.DATA_JSON;
  withContract: boolean = true;
  snapshots: HomeSnapshot[] = [];
  spms: string[] = [];
  /** 页面执行出口（与 entry 同一个 Core HomeTicketPort）：source 是此刻的控制器，env 是此刻的环境。 */
  currentCtl: HomeController | null = null;
  env: string = 'test';
  readonly port: HomeTicketPort;

  constructor() {
    this.lkg = new HomeLkgStore(this.lkgBackend);
    this.local.attach(this.prefs, this.mark);
    this.gate = new RetryAfterGate((): number => this.timer.now, (): string => this.identity.key);
    this.port = new HomeTicketPort((): HomeController | null => this.currentCtl, this.local, (): string => this.env);
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => d.route !== null && TAB_ROOTS.indexOf(d.route) >= 0;
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => this.timer.now),
      (): GuardState => new GuardState('consented', 'ok', 'phone_bound', true, '1.0.0', false, false, false),
      this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
  }

  controller(identity: HomeIdentity = this.identity): HomeController {
    const bound: HomeIdentity = identity;
    const deps: HomeDeps = new HomeDeps(bound, (): string => this.identity.key, this.lkg, this.local, this.gate);
    deps.contract = this.withContract ? this.contract : null;
    deps.clock = (): number => this.timer.now;
    deps.timer = this.timer;
    deps.appVersion = '1.10.0';
    deps.dedupe = this.dedupe;
    deps.defaultJson = (): string | null => this.defaultJson;
    deps.track = (e: ClientEvent): void => {
      this.events.push(e);
    };
    deps.toast = (key: string, trace: string): void => {
      this.toasts.push(key + '#' + trace);
    };
    deps.forceUpdate = (): void => {
      this.forced++;
    };
    deps.open = (route: string, params: Record<string, Object>, spm: string): void => {
      this.spms.push(spm);
      this.router.open(RouteRequestOf.inApp(route, params));
    };
    deps.blockers = (): string[] => this.blockersFn !== null ? this.blockersFn() : this.blockers;
    deps.coldStartShown = (): boolean => this.shownThisRun;
    deps.markColdStartShown = (): void => {
      this.shownThisRun = true;
    };
    const c: HomeController = new HomeController(deps);
    c.onChange = (s: HomeSnapshot): void => {
      this.snapshots.push(s);
    };
    this.currentCtl = c;
    return c;
  }

  /** 此刻快照里的弹窗图片票据（渲染时的值）。 */
  image(): HomePopupImageTicket {
    return this.last().popupImage as HomePopupImageTicket;
  }

  popup(): HomePopupTicket {
    return this.last().popupTicket as HomePopupTicket;
  }

  last(): HomeSnapshot {
    return this.snapshots[this.snapshots.length - 1];
  }

  ids(): string[] {
    return this.last().cards.filter((v: HomeCardView): boolean => !v.hidden).map((v: HomeCardView): string => v.card.id);
  }

  card(id: string): HomeCardView {
    const v: HomeCardView | undefined = this.last().cards.find((c: HomeCardView): boolean => c.card.id === id);
    if (v === undefined) {
      throw new Error('no card ' + id);
    }
    return v;
  }
}

class RouteRequestOf {
  static inApp(route: string, params: Record<string, Object>): RouteRequest {
    return RouteRequest.of(route, RouteSource.IN_APP, params);
  }
}

export async function settle(): Promise<void> {
  await flush();
  await flush();
}

export default function homeIntegrationTest() {
  describe('HomeIntegration', () => {
    // ---------------------------------------------------------------- AC-HOME-04 三级兜底

    it('AC_HOME_04_no_lkg_500_shows_default_after_1500_without_toast', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      expect(f.last().showing).assertEqual(HomeShowing.NONE);
      f.contract.pages[0].resolve(fail(50001));
      await settle();
      expect(f.last().showing).assertEqual(HomeShowing.NONE);
      f.timer.advance(1499);
      expect(f.last().showing).assertEqual(HomeShowing.NONE);
      f.timer.advance(1);
      expect(f.last().showing).assertEqual(HomeShowing.DEFAULT);
      expect(f.ids().join(',')).assertEqual('default_icons,default_activities');
      expect(f.toasts.length).assertEqual(0);
      expect(f.lkgBackend.writes).assertEqual(0);
    });

    it('AC_HOME_04_network_within_1500_shown_and_written', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.controller().start();
      f.timer.advance(1000);
      f.contract.pages[0].resolve(ok(page(2, [ACTIVITY])));
      await settle();
      expect(f.last().showing).assertEqual(HomeShowing.NETWORK);
      expect(f.last().version).assertEqual(2);
      expect(f.lkgBackend.writes).assertEqual(1);
      f.timer.advance(1000);
      expect(f.last().showing).assertEqual(HomeShowing.NETWORK);
    });

    it('AC_HOME_04_late_network_replaces_once_without_interaction', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.controller().start();
      f.timer.advance(1500);
      expect(f.last().showing).assertEqual(HomeShowing.DEFAULT);
      f.timer.advance(500);
      f.contract.pages[0].resolve(ok(page(2, [ACTIVITY])));
      await settle();
      expect(f.last().showing).assertEqual(HomeShowing.NETWORK);
      expect(f.lkgBackend.writes).assertEqual(1);
    });

    it('AC_HOME_04_late_network_after_scroll_only_writes_then_next_cold_start', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.timer.advance(1500);
      c.interacted(f.last().ticket);
      f.contract.pages[0].resolve(ok(page(2, [ACTIVITY])));
      await settle();
      expect(f.last().showing).assertEqual(HomeShowing.DEFAULT);
      expect(f.lkgBackend.writes).assertEqual(1);
      // 下次冷启动（新控制器）：立即显示 LKG 的新版本。
      f.snapshots = [];
      f.controller().start();
      expect(f.last().showing).assertEqual(HomeShowing.LKG);
      expect(f.last().version).assertEqual(2);
    });

    it('AC_HOME_04_lkg_immediate_network_only_writes_pull_replaces_pull_500_keeps', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.lkg.save(f.identity.scope, page(5, [ACTIVITY]));
      const c: HomeController = f.controller();
      c.start();
      expect(f.last().showing).assertEqual(HomeShowing.LKG);
      expect(f.last().version).assertEqual(5);
      f.contract.pages[0].resolve(ok(page(6, [ACTIVITY])));
      await settle();
      expect(f.last().version).assertEqual(5);
      expect(f.lkg.load(f.identity.scope)?.indexOf('"version":6')).assertLarger(-1);
      const pulled: Promise<boolean> = c.pullRefresh(f.last().ticket);
      f.contract.pages[1].resolve(ok(page(7, [ACTIVITY])));
      await pulled;
      expect(f.last().showing).assertEqual(HomeShowing.NETWORK);
      expect(f.last().version).assertEqual(7);
      const again: Promise<boolean> = c.pullRefresh(f.last().ticket);
      f.contract.pages[2].resolve(fail(50001));
      await again;
      expect(f.last().version).assertEqual(7);
      expect(f.toasts[0]).assertEqual('error.50001#test-trace-ABC123');
    });

    it('AC_HOME_04_corrupt_lkg_treated_as_none', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.lkgBackend.files.set(HomeLkgStore.tagOf(f.identity.scope), '{"page_key":"home","version":');
      f.controller().start();
      expect(f.last().showing).assertEqual(HomeShowing.NONE);
      f.timer.advance(1500);
      expect(f.last().showing).assertEqual(HomeShowing.DEFAULT);
    });

    it('AC_HOME_04_bad_bundled_default_and_offline_shows_load_failed_then_retry', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.defaultJson = '{"page_key":"home","version":0}';
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null,
        null, null));
      await settle();
      f.timer.advance(1500);
      expect(f.last().showing).assertEqual(HomeShowing.LOAD_FAILED);
      f.defaultJson = DefaultHomePage.DATA_JSON;
      c.retry(f.last().ticket);
      f.timer.advance(1500);
      expect(f.last().showing).assertEqual(HomeShowing.DEFAULT);
    });

    it('G02_release_without_contract_shows_default_immediately_and_hides_pool_cards', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.withContract = false;
      f.lkg.save(f.identity.scope, page(3, [ACTIVITY, GRID]));
      f.controller().start();
      expect(f.last().showing).assertEqual(HomeShowing.LKG);
      expect(f.ids().join(',')).assertEqual('entries');
      expect(f.contract.pages.length).assertEqual(0);
      const g: HomeFixture = new HomeFixture();
      g.withContract = false;
      g.controller().start();
      expect(g.last().showing).assertEqual(HomeShowing.DEFAULT);
    });

    // ---------------------------------------------------------------- AC-HOME-01

    it('AC_HOME_01_new_version_not_applied_until_next_cold_start', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.lkg.save(f.identity.scope, page(1, [ACTIVITY]));
      f.controller().start();
      f.contract.pages[0].resolve(ok(page(2, [ACTIVITY])));
      await settle();
      expect(f.last().version).assertEqual(1);
      f.snapshots = [];
      f.controller().start();
      expect(f.last().version).assertEqual(2);
    });

    // ---------------------------------------------------------------- AC-HOME-05 / G20 / G21

    it('AC_HOME_05_mixed_bad_keeps_good_and_reports_dropped_once_with_four_fields', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const bad: string = page(13, [ACTIVITY, '{"id":"unknown","type":"future_card","version":1}',
        '{"id":"missing_version","type":"banner","props":{"height_ratio":0.4},"data_source":{"kind":"static","items":[]}}',
        '{"id":"v2","type":"banner","version":2,"props":{"height_ratio":0.4},"data_source":{"kind":"static","items":[]}}',
        '{"id":"missing_props","type":"banner","version":1,"data_source":{"kind":"static","items":[]}}',
        '{"id":"bad_action","type":"product_scroll","version":1,"props":{"title":"x","more_action":{"js":"test_only",'
          + '"url":"https://x.example.com"}},"data_source":{"kind":"product_pool","pool_id":"x"}}',
        ACTIVITY, banner('frame', 'Help', null)]);
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(bad));
      await settle();
      expect(f.ids().join(',')).assertEqual('entries,frame');
      expect(f.events.length).assertEqual(5);
      const reasons: string[] = f.events.map((e: ClientEvent): string => String(e.fields.get('reason')));
      expect(reasons.join(',')).assertEqual('missing_version,unsupported_version,missing_field,bad_action,duplicate_id');
      for (const e of f.events) {
        expect(e.name).assertEqual('sdui_card_error');
        const keys: string[] = Array.from(e.fields.keys()).sort();
        expect(keys.every((k: string): boolean => ['page_version', 'reason', 'type', 'version'].indexOf(k) >= 0))
          .assertTrue();
        expect(JSON.stringify(Array.from(e.fields.values())).indexOf('http')).assertEqual(-1);
      }
      // 同一进程内同一（page_version、section id、reason）只发一次：再渲染同一页不重复上报。
      f.snapshots = [];
      f.lkg.save(f.identity.scope, bad);
      f.controller().start();
      expect(f.events.length).assertEqual(5);
    });

    // ---------------------------------------------------------------- AC-HOME-06

    it('AC_HOME_06_min_app_version_ge_only_and_condition_not_evaluated', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const card = (id: string, min: string, cond: string): string => '{"id":"' + id
        + '","type":"activity_entry","version":1,"min_app_version":{"harmony":"' + min + '"}' + cond
        + ',"props":{},"data_source":{"kind":"static","items":[{"title":"测试","action":{"route":"Help"}}]}}';
      f.controller().start();
      f.contract.pages[0].resolve(ok(page(14, [card('lower', '1.2.0', ''), card('equal', '1.10.0', ''),
        card('higher', '1.11.0', ''), card('cond', '1.0.0', ',"condition":{"login":"no","has_order":"yes"}')])));
      await settle();
      expect(f.ids().join(',')).assertEqual('lower,equal,cond');
    });

    // ---------------------------------------------------------------- AC-HOME-02 公告

    it('AC_HOME_02_notice_close_persists_version_bump_reappears_expiry_hides', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(7, [notice('nb', 'N1', 1, true, null),
        notice('nb2', 'N2', 1, false, '2026-10-10T10:10:00+08:00')])));
      await settle();
      expect(f.ids().join(',')).assertEqual('nb,nb2');
      // 关闭回调捕获渲染时的票据（三元组 + 环境、清理世代、是否落盘）。
      const v: HomeCardView = f.card('nb');
      f.port.closeNotice(v.noticeRows[0].close as HomeNoticeCloseTicket);
      expect(f.ids().join(',')).assertEqual('nb2');
      expect(f.local.closedKeys().indexOf(NoticeFilter.closeKey('nb', 'N1', 1))).assertLarger(-1);
      // 推进时钟（不重启）过 end_at：立即隐藏，两条都没了。
      f.timer.advance(10 * 60 * 1000);
      expect(f.ids().length).assertEqual(0);
      // 重启后 N1 仍不出现（清除缓存不碰关闭记录）；content_version + 1 后重新出现。
      f.snapshots = [];
      f.lkg.save(f.identity.scope, page(8, [notice('nb', 'N1', 1, true, null), ACTIVITY]));
      f.controller().start();
      expect(f.ids().join(',')).assertEqual('entries');
      f.snapshots = [];
      f.lkg.save(f.identity.scope, page(9, [notice('nb', 'N1', 2, true, null)]));
      f.controller().start();
      expect(f.ids().join(',')).assertEqual('nb');
    });

    it('G11_consent_withdraw_cleaner_clears_closed_counts_and_lkg', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.local.addClosed(NoticeFilter.closeKey('nb', 'N1', 1));
      f.local.countShown('pop', T0);
      f.lkg.save(f.identity.scope, page(1, [ACTIVITY]));
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      let invalidated: number = 0;
      HomeDataCleaner.install(registry, f.lkg, f.local, (): void => {
        invalidated++;
      });
      expect(registry.beforeClearNames().indexOf(HomeLkgStore.CLEANER_NAME)).assertLarger(-1);
      await registry.cleanAll();
      expect(invalidated).assertEqual(1);
      expect(f.local.closedKeys().length).assertEqual(0);
      expect(f.local.shownToday('pop', T0)).assertEqual(0);
      expect(f.lkg.load(f.identity.scope)).assertNull();
    });

    // ---------------------------------------------------------------- AC-HOME-03 商品与推广角标

    it('AC_HOME_03_products_in_server_order_ad_label_raw_no_channel_params_empty_hides_only_that', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.controller().start();
      f.contract.pages[0].resolve(ok(page(4, [SCROLL, GRID, ACTIVITY])));
      await settle();
      expect(f.contract.items.length).assertEqual(2);
      expect(f.contract.items.map((i: ItemsCall): string => i.sectionId + ':' + i.cursor).join(','))
        .assertEqual('scroll:null,grid:null');
      f.contract.items[0].resolve(ok('{"items":[],"next_cursor":null}'));
      f.contract.items[1].resolve(ok('{"items":[' + product('b', '推广') + ',' + product('a', null) + '],"next_cursor":null}'));
      await settle();
      expect(f.ids().join(',')).assertEqual('grid,entries');
      const grid: HomeCardView = f.card('grid');
      expect(grid.products.map((p: Record<string, Object>): string => String(p['product_key'])).join(','))
        .assertEqual('tb:b,tb:a');
      expect(String(grid.products[0]['ad_label'])).assertEqual('推广');
      expect(grid.products[1]['ad_label']).assertNull();
    });

    it('G13_feed_page_failure_only_stops_feed_and_retry_continues', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(9, [ACTIVITY, '{"id":"feed","type":"feed_infinite","version":1,"data_source":'
        + '{"kind":"union_material","platforms":["taobao","jd","pdd"]}}'])));
      await settle();
      f.contract.items[0].resolve(ok('{"items":[' + product('a', null) + '],"next_cursor":"c2"}'));
      await settle();
      c.loadMore(f.card('feed').section);
      expect(f.contract.items[1].cursor).assertEqual('c2');
      f.contract.items[1].resolve(fail(50001));
      await settle();
      expect(f.card('feed').feedFailed).assertTrue();
      expect(f.card('feed').products.length).assertEqual(1);
      expect(f.ids().join(',')).assertEqual('entries,feed');
      c.retrySection(f.card('feed').section);
      f.contract.items[2].resolve(ok('{"items":[' + product('b', null) + '],"next_cursor":null}'));
      await settle();
      expect(f.card('feed').products.length).assertEqual(2);
      expect(f.card('feed').feedFailed).assertFalse();
    });

    // ---------------------------------------------------------------- AC-HOME-08 弹窗

    it('AC_HOME_08_popup_after_image_close_once_daily_max_next_day', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      expect(f.last().popupCandidate?.id).assertEqual('pop');
      expect(f.last().popup).assertNull();
      c.popupImageLoaded(f.image());
      const s: HomeSnapshot = f.last();
      expect(s.popup?.id).assertEqual('pop');
      expect(f.local.shownToday('pop', f.timer.now)).assertEqual(0);
      c.popupShown(f.popup());
      expect(f.local.shownToday('pop', f.timer.now)).assertEqual(1);
      c.closePopup(s.popupTicket as HomePopupTicket);
      expect(f.last().popup).assertNull();
      // 同日第二次冷启动不弹（daily_max=1）；次日再弹。
      f.shownThisRun = false;
      f.snapshots = [];
      f.lkg.save(f.identity.scope, page(10, [ACTIVITY, POPUP]));
      f.controller().start();
      expect(f.last().popupCandidate).assertNull();
      f.timer.now = Date.parse('2026-10-11T10:00:00+08:00');
      f.snapshots = [];
      f.controller().start();
      expect(f.last().popupCandidate?.id).assertEqual('pop');
    });

    it('AC_HOME_08_blockers_defer_then_show_basic_never_image_fail_no_count', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.blockers = [PopupBlocker.CLIPBOARD_PROMPT];
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      c.popupImageLoaded(f.image());
      expect(f.last().popup).assertNull();
      f.blockers = [];
      c.blockersChanged();
      expect(f.last().popup?.id).assertEqual('pop');
      // 基本模式：不弹不计数。
      const g: HomeFixture = new HomeFixture();
      g.identity = new HomeIdentity('test', HomeLevel.BASIC, null, 's1');
      g.controller().start();
      g.contract.pages[0].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      expect(g.last().popupCandidate).assertNull();
      expect(g.contract.pages[0].anonymous).assertTrue();
      // 图片失败：不弹不计数。
      const h: HomeFixture = new HomeFixture();
      const hc: HomeController = h.controller();
      hc.start();
      h.contract.pages[0].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      hc.popupImageFailed(h.image());
      expect(h.last().popupCandidate).assertNull();
      expect(h.local.shownToday('pop', h.timer.now)).assertEqual(0);
    });

    it('AC_HOME_08_popup_image_opens_AuthSheet_in_app_and_session_loss_closes_without_count', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      c.popupImageLoaded(f.image());
      const s: HomeSnapshot = f.last();
      const action: HomeAction | null = s.popup?.popupAction ?? null;
      expect(action?.route).assertEqual('AuthSheet');
      f.port.openPopup(s.popupTicket as HomePopupTicket);
      expect(f.last().popup).assertNull();
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('AuthSheet');
      expect(String(f.stack.topParams()['platform'])).assertEqual('taobao');
      // 显示中会话失效：立即关闭且不计数。
      const g: HomeFixture = new HomeFixture();
      const gc: HomeController = g.controller();
      gc.start();
      g.contract.pages[0].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      gc.popupImageLoaded(g.image());
      const gs: HomeSnapshot = g.last();
      g.identity = new HomeIdentity('test', HomeLevel.GUEST, null, 's2');
      gc.dispose();
      gc.popupShown(gs.popupTicket as HomePopupTicket);
      expect(g.local.shownToday('pop', g.timer.now)).assertEqual(0);
    });

    // ---------------------------------------------------------------- AC-S1-81 / AC-S1-131 ① 动作

    it('AC_S1_81_131_card_actions_go_through_router_in_app_with_exact_params', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(2, [banner('s', 'Search', '{"q":"纸巾"}'), banner('p', 'Search', '{"platform":"jd"}'),
        banner('n', 'Notice', '{"article_id":"test_notice_main"}'),
        banner('e', 'ExternalPage', '{"url":"https://x.example.com/a?z=%2f&a=hello+world","title":"品牌活动说明","nav_style":"dark"}'),
        banner('d', 'ProductDetail', '{"platform":"taobao","product_key":"tb:1"}'), banner('h', 'HotRankList', '{}')])));
      await settle();
      const open = (id: string): void => {
        const v: HomeCardView = f.card(id);
        c.open(v.bannerTaps[0]);
      };
      open('s');
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('Search');
      expect(JSON.stringify(f.stack.topParams())).assertEqual('{"q":"纸巾"}');
      open('p');
      expect(JSON.stringify(f.stack.topParams())).assertEqual('{"platform":"jd"}');
      open('n');
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('Notice');
      open('e');
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('ExternalPage');
      expect(String(f.stack.topParams()['url'])).assertEqual('https://x.example.com/a?z=%2f&a=hello+world');
      open('d');
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('ProductDetail');
      open('h');
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual(UPGRADE_PROMPT_PAGE);
      expect(f.spms[0]).assertEqual('home.s.1');
      // 两个账号点同一张卡得到的 url 逐字相同（不拼任何个人数据）。
      const g: HomeFixture = new HomeFixture();
      g.identity = new HomeIdentity('test', HomeLevel.MEMBER, 'B', 's9');
      const gc: HomeController = g.controller();
      gc.start();
      g.contract.pages[0].resolve(ok(page(2, [banner('e', 'ExternalPage', '{"url":"https://x.example.com/a?z=%2f&a=hello+world"}')])));
      await settle();
      gc.open(g.card('e').bannerTaps[0]);
      expect(String(g.stack.topParams()['url'])).assertEqual('https://x.example.com/a?z=%2f&a=hello+world');
    });

    it('G05_js_or_url_only_action_never_executes', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.controller().start();
      f.contract.pages[0].resolve(ok(page(2, ['{"id":"x","type":"banner","version":1,"props":{"height_ratio":0.4},'
        + '"data_source":{"kind":"static","items":[{"image":"https://img.example.com/x.png","action":{"js":"test_only",'
        + '"url":"https://x.example.com"}}]}}', ACTIVITY])));
      await settle();
      // 坏动作只丢这一条，整张卡空 → 隐藏；没有任何可点的东西。
      expect(f.ids().join(',')).assertEqual('entries');
      expect(f.stack.names.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- 基本模式与迟到 / 作废

    it('G25_basic_mode_anonymous_no_events_lkg_in_basic_scope', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.identity = new HomeIdentity('test', HomeLevel.BASIC, null, 'b');
      f.controller().start();
      const bad: string = page(13, [ACTIVITY, '{"id":"v2","type":"banner","version":2}']);
      f.contract.pages[0].resolve(ok(bad));
      await settle();
      expect(f.contract.pages[0].anonymous).assertTrue();
      expect(f.events.length).assertEqual(0);
      expect(f.lkg.load('test:basic')).not().assertNull();
      expect(f.lkg.load('test:user:A')).assertNull();
    });

    it('brief0_A_inflight_response_after_switch_to_B_neither_writes_B_lkg_nor_changes_B_screen', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const a: HomeController = f.controller();
      a.start();
      // A 会话失效 → 登录 B：作废 A 的控制器、按 B 重建。
      f.identity = new HomeIdentity('test', HomeLevel.MEMBER, 'B', 's2');
      a.dispose();
      f.snapshots = [];
      const b: HomeController = f.controller();
      b.start();
      f.contract.pages[0].resolve(ok(page(77, [banner('a_only', 'Help', null)])));
      await settle();
      f.timer.advance(1500);
      expect(f.last().owner).assertEqual(b.serial);
      expect(f.ids().indexOf('a_only')).assertEqual(-1);
      expect(f.lkg.load(f.identity.scope)).assertNull();
      expect(f.lkg.load('test:user:A')).assertNull();
      expect(f.contract.cancelled.indexOf(a.serial)).assertLarger(-1);
      // A 的旧卡片点击不执行。
      a.open(new HomeTap(a.serial, 0, 'x', 1, new HomeAction('Help', {}, false)));
      expect(f.stack.names.length).assertEqual(0);
    });

    it('brief0_notice_close_callback_after_switch_records_render_time_triple', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const a: HomeController = f.controller();
      a.start();
      f.contract.pages[0].resolve(ok(page(7, [notice('nb', 'N1', 3, true, null)])));
      await settle();
      const close: HomeNoticeCloseTicket = f.card('nb').noticeRows[0].close as HomeNoticeCloseTicket;
      // 同一环境内换账号：设备级记录照记（G11），旧页面不重画新页面。
      f.identity = new HomeIdentity('test', HomeLevel.MEMBER, 'B', 's2');
      a.dispose();
      f.currentCtl = null;
      f.port.closeNotice(close);
      expect(f.local.closedKeys().indexOf(NoticeFilter.closeKey('nb', 'N1', 3))).assertLarger(-1);
    });

    it('brief0_pull_refresh_inflight_then_identity_change_drops_response', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.lkg.save(f.identity.scope, page(5, [ACTIVITY]));
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(5, [ACTIVITY])));
      await settle();
      const writes: number = f.lkgBackend.writes;
      const pulled: Promise<boolean> = c.pullRefresh(f.last().ticket);
      f.identity = new HomeIdentity('test', HomeLevel.BASIC, null, 'b');
      f.contract.pages[1].resolve(ok(page(9, [ACTIVITY])));
      await pulled;
      expect(f.lkgBackend.writes).assertEqual(writes);
      expect(f.last().version).assertEqual(5);
    });

    it('brief0_42901_disables_refresh_and_blocks_at_execution_layer', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      f.lkg.save(f.identity.scope, page(5, [ACTIVITY]));
      const c: HomeController = f.controller();
      c.start();
      f.contract.pages[0].resolve(ok(page(5, [ACTIVITY])));
      await settle();
      const pulled: Promise<boolean> = c.pullRefresh(f.last().ticket);
      const effect: ErrorEffect = new ErrorEffect(EffectKind.DISABLE_BUTTON, null, 'error.42901', ReplayKind.NONE, false, 7000);
      f.contract.pages[1].resolve(fail(42901, 'trace-429', effect));
      await pulled;
      expect(f.toasts[0].startsWith('error.42901')).assertTrue();
      expect(f.last().refreshDisabled).assertTrue();
      // 页面层：再下拉被本地拦下并提示一次 42901；执行层：发包前 sendAllowed 拒绝。
      await c.pullRefresh(f.last().ticket);
      expect(f.toasts[1].startsWith('error.42901')).assertTrue();
      expect(f.contract.pages.length).assertEqual(2);
      f.timer.advance(7000);
      expect(f.gate.active).assertFalse();
    });

    // ---------------------------------------------------------------- 清理

    it('brief0_lkg_delete_failure_keeps_mark_outside_and_blocks_reads_until_cleared', 0, async () => {
      const backend: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
      const store: HomeLkgStore = new HomeLkgStore(backend);
      store.save('test:user:A', page(1, [ACTIVITY]));
      backend.failClear = true;
      expect(store.clearScope('test:user:A')).assertFalse();
      expect(backend.pending).not().assertNull();
      // 「重启」：新的 store 读前先补清；补不掉就不读回。
      const restarted: HomeLkgStore = new HomeLkgStore(backend);
      expect(restarted.load('test:user:A')).assertNull();
      backend.failClear = false;
      expect(restarted.retryPendingClear()).assertTrue();
      expect(backend.pending).assertNull();
      expect(backend.files.size).assertEqual(0);
    });

    it('G16_logout_rules_clear_only_old_scope', 0, async () => {
      const backend: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
      const store: HomeLkgStore = new HomeLkgStore(backend);
      store.save('test:user:A', page(1, [ACTIVITY]));
      store.save('test:guest', page(1, [ACTIVITY]));
      expect(store.clearScope('test:user:A')).assertTrue();
      expect(store.load('test:user:A')).assertNull();
      expect(store.load('test:guest')).not().assertNull();
    });

    it('G10_api_notice_source_uses_listArticles_first_page_without_credentials', 0, async () => {
      const rig: Rig = new Rig(null);
      let path: string = '';
      let auth: string | undefined = 'x';
      rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        path = r.url.substring(r.url.indexOf('/v1/'));
        auth = header(r, 'Authorization');
        return Promise.resolve(envelope(0, '{"items":[{"article_id":"a1","category":"notice","title":"t","version":1,'
          + '"published_at":"2026-10-01T00:00:00+08:00","notice":{"item_id":"N9","content_version":1,"text":"测试公告",'
          + '"target":null,"closable":true,"start_at":"2026-10-01T00:00:00+08:00","end_at":null}}],"next_cursor":null}'));
      };
      const f: HomeFixture = new HomeFixture();
      const deps: HomeDeps = new HomeDeps(f.identity, (): string => f.identity.key, f.lkg, f.local, f.gate);
      deps.contract = f.contract;
      deps.notices = new ApiClientHomeNoticePort(() => rig.client);
      deps.clock = (): number => f.timer.now;
      deps.timer = f.timer;
      const c: HomeController = new HomeController(deps);
      let last: HomeSnapshot = new HomeSnapshot();
      c.onChange = (s: HomeSnapshot): void => {
        last = s;
      };
      c.start();
      f.contract.pages[0].resolve(ok(page(8, ['{"id":"na","type":"notice_bar","version":1,"props":{"mode":"scroll"},'
        + '"data_source":{"kind":"api","path":"/v1/other","params":{"x":1}}}'])));
      for (let i: number = 0; i < 6; i++) {
        await settle();
      }
      expect(path).assertEqual('/v1/articles?category=notice');
      expect(auth === undefined).assertTrue();
      const v: HomeCardView | undefined = last.cards.find((x: HomeCardView): boolean => x.card.id === 'na');
      expect(v?.notices[0].itemId).assertEqual('N9');
      expect(v?.card.type).assertEqual(HomeCardType.NOTICE_BAR);
    });
  });
}
