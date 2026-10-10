// APP-11 鸿蒙第 2 轮评审修复的回归测试（harmony-review-r2.md R2-01…R2-05）。接线照 entry：
// - R2-01：真实 ApiClient → DebugMockTransport（entry DebugFakeServer 的 send / cancel 只经它）→ 本机假服务或真实传输层，环境用真实的
//   EnvironmentSwitcher 切换（staging 源码集，按相对路径引入，rule-gaps H01 / H25）；
// - R2-02 / R2-03：系统模态实例经 Core 的 HomePopupDialogHost（HomeTabRoot 同一个），承载用替身；首页执行出口是 Core 的 HomeTicketPort；
// - R2-04：HomeLocalStore 接按本机 SDK 单值上限（8192）抛错的偏好替身；
// - R2-05：HomePreviewSession 订阅 HomeSignalHub（entry 由系统 touchGuideStateChange 驱动）。
import { describe, it, expect } from '@ohos/hypium';
import {
  AppEnvironment, EnvironmentEndpoints, EnvironmentRecord, EnvironmentSwitchGate, HomeCardView, HomeController,
  HomeIdentity, HomeLevel, HomeLkgStore, HomeLocalStore, HomeNoticeDisplay, HomePopupDialogHost, HomePopupImageTicket,
  HomePopupPresenter, HomePopupTicket, HomeSignalHub, HomeSnapshot, LocalDataCleanerRegistry, MemoryHomeClearMark,
  MemoryHomeLkgBackend, MemoryHomePendingLedger, MemoryHomePrefsBackend, NoticeFilter, PopupBlocker, PROD_ENDPOINTS,
  RouteRequest, RouteSource, TransportRequest, TransportResponse
} from '../../Index';
import {
  HomeDebugSources, HomePreviewDeps, HomePreviewDisplay, HomePreviewSession, HomePreviewState
} from '../staging/ets/home/HomePreviewSession';
import { HomePreviewPolicy } from '../staging/ets/home/HomePreviewPolicy';
import { DebugMockGate, DebugMockTransport } from '../staging/ets/network/DebugMockTransport';
import { EnvironmentSwitcher } from '../staging/ets/config/EnvironmentSwitcher';
import { Deferred, envelope, FakeServer, Rig } from './NetworkTestRig';
import { ACTIVITY, FakeContract, HomeFixture, ok, page, POPUP, settle, T0 } from './HomeIntegration.test';

const API_NOTICE: string = '{"id":"na","type":"notice_bar","version":1,"props":{"mode":"scroll"},"data_source":{"kind":"api"}}';

function articles(): string {
  const one: (id: string) => string = (id: string): string => '{"article_id":"a_' + id + '","category":"notice","title":"t",'
    + '"version":1,"published_at":"2026-10-01T00:00:00+08:00","notice":{"item_id":"' + id + '","content_version":1,'
    + '"text":"测试公告","target":null,"closable":true,"start_at":"2026-10-01T00:00:00+08:00","end_at":null}}';
  return '{"items":[' + one('N1') + ',' + one('N2') + '],"next_cursor":null}';
}

export function draft(sections: string[]): string {
  return '{"page_key":"home","version":12,"sections":[' + sections.join(',') + ']}';
}

export async function drain(n: number = 6): Promise<void> {
  for (let i: number = 0; i < n; i++) {
    await settle();
  }
}

class MemoryRecord implements EnvironmentRecord {
  readonly values: Map<string, string> = new Map<string, string>();

  async get(key: string): Promise<string | undefined> {
    return this.values.get(key);
  }

  async put(key: string, value: string): Promise<void> {
    this.values.set(key, value);
  }

  async remove(key: string): Promise<void> {
    this.values.delete(key);
  }
}

function environments(): Map<AppEnvironment, EnvironmentEndpoints> {
  const map: Map<AppEnvironment, EnvironmentEndpoints> = new Map<AppEnvironment, EnvironmentEndpoints>();
  map.set(AppEnvironment.TEST, new EnvironmentEndpoints('https://api.test.unit.invalid', 'https://h5.test.unit.invalid'));
  map.set(AppEnvironment.PROD, PROD_ENDPOINTS);
  return map;
}

/** 系统模态承载的替身：记录每个实例的打开 / 关闭；打开可挂起（模拟异步打开与打开失败）；可模拟系统关闭请求。 */
export class FakePresenter implements HomePopupPresenter {
  readonly presented: number[] = [];
  readonly dismissed: number[] = [];
  readonly tickets: Map<number, HomePopupTicket> = new Map<number, HomePopupTicket>();
  holdOpen: boolean = false;
  private readonly willDismiss: Map<number, () => void> = new Map<number, () => void>();
  private readonly resolvers: Map<number, () => void> = new Map<number, () => void>();
  private readonly rejecters: Map<number, (e: Error) => void> = new Map<number, (e: Error) => void>();

  present(instance: number, ticket: HomePopupTicket, onWillDismiss: () => void): Promise<void> {
    this.presented.push(instance);
    this.tickets.set(instance, ticket);
    this.willDismiss.set(instance, onWillDismiss);
    if (!this.holdOpen) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      this.resolvers.set(instance, resolve);
      this.rejecters.set(instance, reject);
    });
  }

  dismiss(instance: number): void {
    this.dismissed.push(instance);
  }

  finishOpen(instance: number): void {
    const r: (() => void) | undefined = this.resolvers.get(instance);
    if (r !== undefined) {
      r();
    }
  }

  failOpen(instance: number): void {
    const r: ((e: Error) => void) | undefined = this.rejecters.get(instance);
    if (r !== undefined) {
      r(new Error('open failed'));
    }
  }

  /** 这个实例收到系统关闭请求（返回键、点遮罩）。 */
  systemDismiss(instance: number): void {
    const f: (() => void) | undefined = this.willDismiss.get(instance);
    if (f !== undefined) {
      f();
    }
  }
}

/** HomePreview 的装配（与 entry HomePreviewPage 同一接线：真实 ApiClient、真实 Router、系统状态订阅、可见性与其他弹层）。 */
export class PreviewRig2 {
  readonly rig: Rig;
  readonly home: HomeFixture = new HomeFixture();
  readonly reader: HomeSignalHub = new HomeSignalHub(false);
  readonly foreground: HomeSignalHub = new HomeSignalHub(true);
  identity: HomeIdentity = new HomeIdentity('test', HomeLevel.MEMBER, 'A', 's1');
  top: boolean = true;
  overlays: string[] = [];
  states: HomePreviewState[] = [];
  snapshots: HomeSnapshot[] = [];
  displays: HomePreviewDisplay[] = [];

  constructor(rig: Rig | null = null) {
    this.rig = rig ?? new Rig(null);
    this.rig.nowMillis = T0;
  }

  session(token: string = 'draft'): HomePreviewSession {
    const deps: HomePreviewDeps = new HomePreviewDeps((): HomeIdentity => this.identity, () => this.rig.client, 'home',
      token);
    deps.clock = (): number => this.rig.nowMillis;
    deps.timer = this.home.timer;
    deps.open = (route: string, params: Record<string, Object>): void => {
      this.home.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
    };
    deps.screenReader = this.reader;
    deps.foreground = this.foreground;
    deps.isTop = (): boolean => this.top;
    deps.overlays = (): string[] => this.overlays;
    const s: HomePreviewSession = new HomePreviewSession(deps);
    s.onState = (st: HomePreviewState): void => {
      this.states.push(st);
    };
    s.onSnapshot = (sn: HomeSnapshot): void => {
      this.snapshots.push(sn);
    };
    s.onDisplay = (d: HomePreviewDisplay): void => {
      this.displays.push(d);
    };
    return s;
  }

  lastSnap(): HomeSnapshot {
    return this.snapshots.length > 0 ? this.snapshots[this.snapshots.length - 1] : new HomeSnapshot();
  }

  lastState(): HomePreviewState {
    return this.states[this.states.length - 1];
  }

  /** 页面的模态宿主（HomeTabRoot 同一接线：关闭回调提交本实例票据，打开前复核）。 */
  host(s: HomePreviewSession, presenter: FakePresenter): HomePopupDialogHost {
    return new HomePopupDialogHost(presenter, (t: HomePopupTicket): void => {
      s.port.closePopup(t);
    }, (t: HomePopupTicket): boolean => s.port.popupBeforeOpen(t));
  }
}

/** 首页（HomeFixture）的模态宿主：与 HomeTabRoot 同一接线，出口是 Core 的 HomeTicketPort。 */
export function homeHost(f: HomeFixture, presenter: FakePresenter): HomePopupDialogHost {
  return new HomePopupDialogHost(presenter, (t: HomePopupTicket): void => {
    f.port.closePopup(t);
  }, (t: HomePopupTicket): boolean => f.port.popupBeforeOpen(t));
}

export async function homeWithPopup(f: HomeFixture, call: number): Promise<HomeController> {
  const c: HomeController = f.controller();
  c.start();
  f.contract.pages[call].resolve(ok(page(10 + call, [ACTIVITY, POPUP])));
  await settle();
  f.port.popupImageLoaded(f.image());
  return c;
}

export default function homeFixR2Test() {
  describe('HomeFixR2', () => {
    // ---------------------------------------------------------------- R2-01 传输入口统一检查 MOCK_DATA

    it('R2_01_fake_server_entry_goes_real_in_prod_after_env_switch', 0, async () => {
      const fake: FakeServer = new FakeServer();
      const real: FakeServer = new FakeServer();
      fake.handler = (r: TransportRequest): Promise<TransportResponse> => Promise.resolve(
        r.url.indexOf('/v1/articles') >= 0 ? envelope(0, articles()) : envelope(0, draft([ACTIVITY, API_NOTICE])));
      real.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(30701, '{}'));
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, environments(),
        new LocalDataCleanerRegistry(), new MemoryRecord(), new EnvironmentSwitchGate());
      let enabled: boolean = true;
      const entry: DebugMockTransport = new DebugMockTransport(fake, real, (): boolean => enabled,
        (): AppEnvironment | undefined => switcher.current);
      const p: PreviewRig2 = new PreviewRig2(new Rig(null, entry));
      // test 环境 + 假服务打开：草稿与公告都由本机假服务回答。
      const a: HomePreviewSession = p.session('a');
      await a.load();
      await drain();
      expect(p.lastState().screen).assertEqual(HomePreviewPolicy.DRAFT);
      expect(fake.count('/preview')).assertEqual(1);
      expect(fake.count('/v1/articles')).assertEqual(1);
      expect(real.received.length).assertEqual(0);
      // 切到 prod（真实切换流程）：同一个传输入口一律走真实传输层，草稿与公告都不再被本地截获，服务端 30701 原样生效。
      const result: string = (await switcher.switchTo(AppEnvironment.PROD)).outcome;
      expect(result).assertEqual('switched');
      p.identity = new HomeIdentity('prod', HomeLevel.MEMBER, 'A', 's1');
      const b: HomePreviewSession = p.session('b');
      await b.load();
      await drain();
      expect(real.count('/preview')).assertEqual(1);
      expect(fake.count('/preview')).assertEqual(1);
      expect(p.lastState().screen).assertEqual(HomePreviewPolicy.EXPIRED);
      const sent: number = fake.received.length;
      const r: TransportResponse = await entry.send(new TransportRequest('GET',
        'https://api.prod.couli.invalid/v1/articles?category=notice', {}, null, 10000));
      expect(r.status).assertEqual(400);
      expect(fake.received.length).assertEqual(sent);
      expect(real.count('/v1/articles')).assertEqual(1);
      // 假服务关闭（任何环境）同样走真实传输层；环境未定按不允许。
      expect(DebugMockGate.allowed(true, AppEnvironment.TEST)).assertTrue();
      expect(DebugMockGate.allowed(true, AppEnvironment.PROD)).assertFalse();
      expect(DebugMockGate.allowed(false, AppEnvironment.TEST)).assertFalse();
      expect(DebugMockGate.allowed(true, undefined)).assertFalse();
      enabled = false;
      expect(entry.mockAllowed()).assertFalse();
      // 首页待定接口的数据源与传输入口同一判断。
      const contract: FakeContract = new FakeContract();
      expect(HomeDebugSources.contract(true, AppEnvironment.PROD, contract)).assertNull();
      expect(HomeDebugSources.contract(true, AppEnvironment.TEST, contract) === contract).assertTrue();
    });

    it('R2_01_cancel_goes_to_side_that_took_the_request', 0, async () => {
      const fake: FakeServer = new FakeServer();
      const real: FakeServer = new FakeServer();
      const held: Deferred = new Deferred();
      fake.handler = (_r: TransportRequest): Promise<TransportResponse> => held.promise;
      let env: AppEnvironment = AppEnvironment.TEST;
      const entry: DebugMockTransport = new DebugMockTransport(fake, real, (): boolean => true,
        (): AppEnvironment | undefined => env);
      const req: TransportRequest = new TransportRequest('GET', 'https://api.test.unit.invalid/v1/pages/home/preview', {}, null,
        10000);
      const pending: Promise<TransportResponse> = entry.send(req);
      // 发出后切到 prod：取消仍交给当初接下它的本机假服务。
      env = AppEnvironment.PROD;
      entry.cancel(req);
      expect(fake.cancelled.length).assertEqual(1);
      expect(real.cancelled.length).assertEqual(0);
      held.resolve(envelope(0, '{}'));
      await pending;
      // prod 下发出的请求由真实传输层取消。
      const req2: TransportRequest = new TransportRequest('GET', 'https://api.prod.couli.invalid/v1/me', {}, null, 10000);
      entry.send(req2);
      entry.cancel(req2);
      expect(real.cancelled.length).assertEqual(1);
      expect(fake.received.length).assertEqual(1);
    });

    // ---------------------------------------------------------------- R2-02 模态关闭回调只关自己的实例

    it('R2_02_old_dialog_will_dismiss_does_not_close_new_controller_popup', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const presenter: FakePresenter = new FakePresenter();
      const host: HomePopupDialogHost = homeHost(f, presenter);
      const a: HomeController = await homeWithPopup(f, 0);
      const ticketA: HomePopupTicket = f.popup();
      host.sync(ticketA);
      await settle();
      expect(presenter.presented.join(',')).assertEqual('1');
      // 首页身份切换：作废 A、按新身份建 B，B 的弹窗显示；宿主关掉旧实例、打开新实例。
      a.dispose();
      f.shownThisRun = false;
      const b: HomeController = await homeWithPopup(f, 1);
      const ticketB: HomePopupTicket = f.popup();
      expect(ticketB.owner).assertEqual(b.serial);
      host.sync(ticketB);
      await settle();
      expect(presenter.presented.join(',')).assertEqual('1,2');
      expect(presenter.dismissed.join(',')).assertEqual('1');
      // 旧实例的系统关闭回调迟到（关闭动画中收到返回）：只提交 A 的票据，B 的弹窗与 B 的实例都不受影响。
      presenter.systemDismiss(1);
      await settle();
      expect(f.last().popupTicket?.key).assertEqual(ticketB.key);
      expect(host.currentKey).assertEqual(ticketB.key);
      expect(f.port.closePopup(ticketA)).assertFalse();
      expect(f.last().popup?.id).assertEqual('pop');
      // B 自己的实例收到系统关闭：只关 B。
      presenter.systemDismiss(2);
      await settle();
      expect(f.last().popup).assertNull();
      expect(host.currentKey).assertEqual('');
    });

    it('R2_02_async_open_failure_and_early_close_only_touch_own_instance', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const presenter: FakePresenter = new FakePresenter();
      presenter.holdOpen = true;
      const host: HomePopupDialogHost = homeHost(f, presenter);
      const a: HomeController = await homeWithPopup(f, 0);
      host.sync(f.popup());
      a.dispose();
      f.shownThisRun = false;
      await homeWithPopup(f, 1);
      const ticketB: HomePopupTicket = f.popup();
      host.sync(ticketB);
      // 旧实例的异步打开失败：不清掉后来实例的句柄。
      presenter.failOpen(1);
      await settle();
      expect(host.currentKey).assertEqual(ticketB.key);
      presenter.finishOpen(2);
      await settle();
      expect(presenter.dismissed.length).assertEqual(0);
      // 打开完成前就被要求关闭：打开完成后立即关闭本实例（不留孤儿弹窗）。
      const f2: HomeFixture = new HomeFixture();
      const p2: FakePresenter = new FakePresenter();
      p2.holdOpen = true;
      const host2: HomePopupDialogHost = homeHost(f2, p2);
      await homeWithPopup(f2, 0);
      host2.sync(f2.popup());
      host2.sync(null);
      expect(p2.dismissed.length).assertEqual(0);
      p2.finishOpen(1);
      await settle();
      expect(p2.dismissed.join(',')).assertEqual('1');
    });

    // ---------------------------------------------------------------- R2-03 预览与首页的可见性、阻挡项

    it('R2_03_covered_preview_image_completion_does_not_open_dialog', 0, async () => {
      const p: PreviewRig2 = new PreviewRig2();
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, draft([ACTIVITY, POPUP])));
      const s: HomePreviewSession = p.session();
      const presenter: FakePresenter = new FakePresenter();
      const host: HomePopupDialogHost = p.host(s, presenter);
      s.shown();
      await s.load();
      await drain(2);
      const image: HomePopupImageTicket = p.lastSnap().popupImage as HomePopupImageTicket;
      // 打开页面 B：A 留在栈里、不在栈顶，onWillHide。
      p.top = false;
      s.willHide();
      expect(s.display.active).assertFalse();
      s.port.popupImageLoaded(image);
      host.sync(p.lastSnap().popupTicket);
      expect(p.lastSnap().popup).assertNull();
      expect(presenter.presented.length).assertEqual(0);
      // 计时复核期间仍被盖住：不弹。
      p.home.timer.advance(3000);
      host.sync(p.lastSnap().popupTicket);
      expect(presenter.presented.length).assertEqual(0);
      // B 出栈、A 重新显示：复核通过才弹。
      p.top = true;
      s.shown();
      expect(p.lastSnap().popup?.id).assertEqual('pop');
      host.sync(p.lastSnap().popupTicket);
      expect(presenter.presented.length).assertEqual(1);
      // App 退到后台（前后台订阅）同样算不可见。
      const s2: HomePreviewSession = p.session('b');
      s2.shown();
      p.foreground.set(false);
      expect(s2.blockers().indexOf(PopupBlocker.HOME_NOT_VISIBLE)).assertLarger(-1);
      p.foreground.set(true);
      expect(s2.blockers().length).assertEqual(0);
      // 从未显示（onShown 之前）不算可见。
      const s3: HomePreviewSession = p.session('c');
      expect(s3.blockers().indexOf(PopupBlocker.HOME_NOT_VISIBLE)).assertLarger(-1);
    });

    it('R2_03_recheck_before_opening_modal_returns_to_waiting', 0, async () => {
      const p: PreviewRig2 = new PreviewRig2();
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, draft([ACTIVITY, POPUP])));
      const s: HomePreviewSession = p.session();
      const presenter: FakePresenter = new FakePresenter();
      const host: HomePopupDialogHost = p.host(s, presenter);
      s.shown();
      await s.load();
      await drain(2);
      s.port.popupImageLoaded(p.lastSnap().popupImage as HomePopupImageTicket);
      const first: HomePopupTicket = p.lastSnap().popupTicket as HomePopupTicket;
      expect(first === null).assertFalse();
      // 快照到达界面、真正打开模态之前出现了别的弹层：不打开，退回等待（不计数）。
      p.overlays = [PopupBlocker.PRIVACY_DIALOG];
      host.sync(first);
      expect(presenter.presented.length).assertEqual(0);
      expect(p.lastSnap().popup).assertNull();
      host.sync(p.lastSnap().popupTicket);
      // 弹层结束：每秒复核，满足后以新的弹窗编号再弹。
      p.overlays = [];
      p.home.timer.advance(1000);
      const second: HomePopupTicket = p.lastSnap().popupTicket as HomePopupTicket;
      expect(second.popupSerial).assertLarger(first.popupSerial);
      host.sync(second);
      expect(presenter.presented.length).assertEqual(1);
      // 显示过（已计数）后页面被盖住：收起，回来也不再弹。
      s.port.popupShown(second);
      p.top = false;
      s.willHide();
      expect(p.lastSnap().popup).assertNull();
      host.sync(p.lastSnap().popupTicket);
      await settle();
      expect(presenter.dismissed.join(',')).assertEqual('1');
      p.top = true;
      s.shown();
      p.home.timer.advance(2000);
      expect(p.lastSnap().popup).assertNull();
    });

    it('R2_03_formal_home_hidden_suspends_and_rechecks_before_open', 0, async () => {
      const f: HomeFixture = new HomeFixture();
      const presenter: FakePresenter = new FakePresenter();
      const host: HomePopupDialogHost = homeHost(f, presenter);
      const c: HomeController = await homeWithPopup(f, 0);
      const t1: HomePopupTicket = f.popup();
      // 打开前首页被推入的页面盖住：不打开，退回等待。
      f.blockers = [PopupBlocker.HOME_NOT_VISIBLE];
      host.sync(t1);
      expect(presenter.presented.length).assertEqual(0);
      expect(f.last().popup).assertNull();
      expect(c.popupWaiting).assertTrue();
      // 回到首页：复核通过再弹。
      f.blockers = [];
      c.visibilityChanged();
      host.sync(f.popup());
      expect(presenter.presented.length).assertEqual(1);
      // 显示中切走（未计数）：收起，回来再弹；计数后被盖住：按关闭处理。
      f.blockers = [PopupBlocker.HOME_NOT_VISIBLE];
      c.visibilityChanged();
      expect(f.last().popup).assertNull();
      f.blockers = [];
      c.visibilityChanged();
      const t3: HomePopupTicket = f.popup();
      f.port.popupShown(t3);
      f.blockers = [PopupBlocker.HOME_NOT_VISIBLE];
      c.visibilityChanged();
      f.blockers = [];
      c.visibilityChanged();
      expect(f.last().popup).assertNull();
      expect(f.local.shownToday('pop', f.timer.now)).assertEqual(1);
    });

    // ---------------------------------------------------------------- R2-04 关闭记录的存储容量

    it('R2_04_close_records_beyond_8192_chars_persist_across_restart', 0, async () => {
      const prefs: MemoryHomePrefsBackend = new MemoryHomePrefsBackend();
      const mark: MemoryHomeClearMark = new MemoryHomeClearMark();
      const store: HomeLocalStore = new HomeLocalStore();
      store.attach(prefs, mark);
      const keys: string[] = [];
      let total: number = 0;
      for (let i: number = 0; i < 1000; i++) {
        const k: string = NoticeFilter.closeKey('notice_bar_' + (i % 7), 'item_' + i, 1 + (i % 3));
        keys.push(k);
        total += k.length + 3;
        expect(store.addClosed(k)).assertTrue();
      }
      // 合起来远超单值上限，但每个值都在上限内。
      expect(total).assertLarger(MemoryHomePrefsBackend.SDK_MAX_VALUE_LENGTH * 2);
      prefs.values.forEach((v: string) => {
        expect(v.length <= MemoryHomePrefsBackend.SDK_MAX_VALUE_LENGTH).assertTrue();
      });
      // 重复关闭不重复记。
      const before: number = prefs.values.size;
      expect(store.addClosed(keys[0])).assertTrue();
      expect(prefs.values.size).assertEqual(before);
      // 重启（新的存储对象接同一份偏好）：第一条与最后一条都还在，没有淘汰。
      const restarted: HomeLocalStore = new HomeLocalStore();
      restarted.attach(prefs, mark);
      const read: string[] = restarted.closedKeys();
      expect(read.length).assertEqual(1000);
      expect(read.indexOf(keys[0])).assertEqual(0);
      expect(read.indexOf(keys[999])).assertEqual(999);
      // 撤回同意 / 切换环境照旧整体清掉（所有分片）。
      expect(restarted.clear()).assertTrue();
      expect(prefs.values.size).assertEqual(0);
      expect(restarted.closedKeys().length).assertEqual(0);
      // 清理没完成时（待清理标记在）不读不写。
      mark.value = true;
      prefs.failClear = true;
      expect(restarted.addClosed(keys[1])).assertFalse();
      prefs.failClear = false;
      expect(restarted.addClosed(keys[1])).assertTrue();
      expect(restarted.closedKeys().join(',')).assertEqual(keys[1]);
    });

    it('R2_04_same_class_long_popup_id_and_pending_ledger_stay_within_limits', 0, async () => {
      const prefs: MemoryHomePrefsBackend = new MemoryHomePrefsBackend();
      const store: HomeLocalStore = new HomeLocalStore();
      store.attach(prefs, new MemoryHomeClearMark());
      const longId: string = 'p'.repeat(3000);
      expect(store.countShown(longId, T0)).assertTrue();
      expect(store.shownToday(longId, T0)).assertEqual(1);
      expect(HomeLocalStore.popupKey(longId).length).assertLess(64);
      expect(HomeLocalStore.popupKey('pop')).assertEqual('popup.pop');
      expect(HomeLocalStore.popupKey(longId) === HomeLocalStore.popupKey('q'.repeat(3000))).assertFalse();
      // LKG 待清理的第二通道（Preferences）：作用域多到放不下时收拢成全部待清理（多清不少清）。
      const backend: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
      const ledger: MemoryHomePendingLedger = new MemoryHomePendingLedger();
      const lkg: HomeLkgStore = new HomeLkgStore(backend, ledger);
      backend.failClear = true;
      for (let i: number = 0; i < 300; i++) {
        lkg.clearScope('test:user:account_' + i);
      }
      const value: string = ledger.value ?? '';
      expect(value.length <= HomeLkgStore.PENDING_MAX_CHARS).assertTrue();
      expect(value).assertEqual('*');
    });

    // ---------------------------------------------------------------- R2-05 预览持续订阅读屏

    it('R2_05_preview_follows_screen_reader_toggle_and_unsubscribes_on_leave', 0, async () => {
      const p: PreviewRig2 = new PreviewRig2();
      p.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/articles') >= 0) {
          return Promise.resolve(envelope(0, articles()));
        }
        return Promise.resolve(envelope(0, draft([API_NOTICE])));
      };
      const s: HomePreviewSession = p.session();
      s.shown();
      await s.load();
      await drain();
      const na: HomeCardView | undefined = p.lastSnap().cards.find((v: HomeCardView): boolean => v.card.id === 'na');
      const mode: string = na?.card.noticeMode ?? '';
      const count: number = na?.noticeRows.length ?? 0;
      const autoplay: (d: HomePreviewDisplay) => boolean = (d: HomePreviewDisplay): boolean =>
      HomeNoticeDisplay.of(mode, count, d.screenReader, d.active).autoplay;
      expect(autoplay(s.display)).assertTrue();
      // 同一预览页里开启读屏（系统快捷方式）：本实例立即停自动滚动；关闭后恢复。
      p.reader.set(true);
      expect(p.displays[p.displays.length - 1].screenReader).assertTrue();
      expect(autoplay(p.displays[p.displays.length - 1])).assertFalse();
      p.reader.set(false);
      expect(autoplay(p.displays[p.displays.length - 1])).assertTrue();
      // 两个实例各自订阅；离开的实例注销，之后不再收到变化。
      const other: HomePreviewSession = p.session('b');
      expect(p.reader.listenerCount).assertEqual(2);
      s.leave();
      expect(p.reader.listenerCount).assertEqual(1);
      expect(p.foreground.listenerCount).assertEqual(1);
      const n: number = p.displays.length;
      p.reader.set(true);
      expect(other.display.screenReader).assertTrue();
      // 只有仍存活的 other 收到通知。
      expect(p.displays.length).assertEqual(n + 1);
      other.leave();
      expect(p.reader.listenerCount).assertEqual(0);
    });
  });
}
