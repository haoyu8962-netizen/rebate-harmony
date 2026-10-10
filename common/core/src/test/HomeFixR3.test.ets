// APP-11 鸿蒙第 3 轮评审修复的回归测试（harmony-review-r3.md R3-01 / R3-02）。接线照 entry：
// - 正式首页控制器的 blockers 经 Core 的 HomeVisibilityHub（AppHome.visibility 同一个类）；AppHome 订阅它并调 visibilityChanged，
//   每个 HomePreview 实例（HomePreviewPage）也订阅它并调本实例的 visibilityChanged；
// - 系统模态实例经 Core 的 HomePopupDialogHost（HomeTabRoot 同一个），承载用替身；
// - 切 Tab 按 ShellState.showRoot 的真实顺序：先回调 onTabWillChange（AppHome.setActive → hub.setTab），之后才改 selected。
import { describe, it, expect } from '@ohos/hypium';
import {
  HomeController, HomePopupDialogHost, HomePopupImageTicket, HomePopupTicket, HomeVisibilityHub, PopupBlocker,
  TabWillChangeRegistry, TransportRequest, TransportResponse
} from '../../Index';
import { HomePreviewSession } from '../staging/ets/home/HomePreviewSession';
import { envelope } from './NetworkTestRig';
import { ACTIVITY, HomeFixture, ok, page, POPUP, settle } from './HomeIntegration.test';
import { draft, drain, FakePresenter, homeHost, homeWithPopup, PreviewRig2 } from './HomeFixR2.test';

/** ShellState.showRoot 的顺序替身：onTabWillChange 先于 selected 更新。 */
class ShellOrder {
  selected: number = 0;
  readonly onTabWillChange: (route: string) => void;

  constructor(onTabWillChange: (route: string) => void) {
    this.onTabWillChange = onTabWillChange;
  }

  showRoot(index: number, route: string): void {
    this.onTabWillChange(route);
    this.selected = index;
  }
}

/** ShellState 的替身（复核 RC-01 之后）：切 Tab 监听表按模块名登记，showRoot 先 dispatch 再改 selected。 */
class ShellRegistry {
  selected: number = 0;
  readonly onTabWillChange: TabWillChangeRegistry = new TabWillChangeRegistry();

  showRoot(index: number, route: string): void {
    this.onTabWillChange.dispatch(route, false);
    this.selected = index;
  }
}

/** EntryAbility.onCreate 的组合顺序替身：AppClipboard.compose 先登记，AppHome.compose 后登记；第二次起按真实状态重设 hub（RC-01）。 */
class AbilityComposer {
  private readonly shell: ShellRegistry;
  private readonly hub: HomeVisibilityHub;
  readonly clipboardCalls: string[] = [];
  private composed: number = 0;
  stackEmpty: boolean = true;
  foreground: boolean = true;

  constructor(shell: ShellRegistry, hub: HomeVisibilityHub) {
    this.shell = shell;
    this.hub = hub;
  }

  compose(): void {
    this.composed++;
    const round: number = this.composed;
    // AppClipboard.compose：每次组合都重新登记自己的 tabChanged。
    this.shell.onTabWillChange.register(TabWillChangeRegistry.CLIPBOARD, (route: string, _b: boolean): void => {
      this.clipboardCalls.push(round + ':' + route);
    });
    // AppHome.compose：每次幂等登记；lkgStore 已存在（第二次起）按真实 Tab、栈、前后台重设后返回。
    this.hub.bindTab(this.shell.onTabWillChange, 'Home');
    if (round > 1) {
      this.hub.resync(this.shell.selected === 0, this.stackEmpty, this.foreground);
    }
  }
}

export default function homeFixR3Test() {
  describe('HomeFixR3', () => {
    // ---------------------------------------------------------------- R3-01 阻挡弹层变化通知首页与每个存活的预览

    it('R3_01_overlay_after_popup_shown_dismisses_home_and_previews_without_recount', 0, async () => {
      const overlays: string[] = [];
      const hub: HomeVisibilityHub = new HomeVisibilityHub((): string[] => overlays);
      // 正式首页：blockers 经 hub，AppHome 订阅 hub 后调当前控制器的 visibilityChanged。
      const f: HomeFixture = new HomeFixture();
      f.blockersFn = (): string[] => hub.blockers([]);
      const presenter: FakePresenter = new FakePresenter();
      const host: HomePopupDialogHost = homeHost(f, presenter);
      const c: HomeController = await homeWithPopup(f, 0);
      hub.subscribe((): void => c.visibilityChanged());
      const t: HomePopupTicket = f.popup();
      host.sync(t);
      await settle();
      f.port.popupShown(t);
      expect(presenter.presented.join(',')).assertEqual('1');
      expect(f.local.shownToday('pop', f.timer.now)).assertEqual(1);
      // 预览实例：其他弹层与首页同一来源，HomePreviewPage 订阅 hub 后调本实例的 visibilityChanged。
      const p: PreviewRig2 = new PreviewRig2();
      p.overlays = overlays;
      p.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, draft([ACTIVITY, POPUP])));
      const s: HomePreviewSession = p.session();
      const pp: FakePresenter = new FakePresenter();
      const host2: HomePopupDialogHost = p.host(s, pp);
      s.shown();
      await s.load();
      await drain(2);
      s.port.popupImageLoaded(p.lastSnap().popupImage as HomePopupImageTicket);
      const pt: HomePopupTicket = p.lastSnap().popupTicket as HomePopupTicket;
      host2.sync(pt);
      await settle();
      s.port.popupShown(pt);
      hub.subscribe((): void => s.visibilityChanged());
      // 弹窗都已显示，不再等阻挡项（没有每秒复核）。
      expect(c.popupWaiting).assertFalse();
      // 版本检查返回可选更新提示，身份不变：广播后首页与预览的弹窗都收起，模态实例关闭。
      overlays.push(PopupBlocker.UPDATE_PROMPT);
      hub.overlaysChanged();
      expect(f.last().popup).assertNull();
      expect(p.lastSnap().popup).assertNull();
      host.sync(f.last().popupTicket);
      host2.sync(p.lastSnap().popupTicket);
      await settle();
      expect(presenter.dismissed.join(',')).assertEqual('1');
      expect(pp.dismissed.join(',')).assertEqual('1');
      // 更新提示消失：已显示过的按关闭处理，不再弹、不重复计次。
      overlays.splice(0, overlays.length);
      hub.overlaysChanged();
      f.timer.advance(3000);
      p.home.timer.advance(3000);
      expect(f.last().popup).assertNull();
      expect(p.lastSnap().popup).assertNull();
      expect(f.local.shownToday('pop', f.timer.now)).assertEqual(1);
      expect(presenter.presented.length).assertEqual(1);
      expect(pp.presented.length).assertEqual(1);
    });

    // ---------------------------------------------------------------- R3-02 切 Tab 读同步目标值

    it('R3_02_tab_switch_during_pending_open_closes_old_instance_uncounted', 0, async () => {
      const hub: HomeVisibilityHub = new HomeVisibilityHub((): string[] => []);
      const shell: ShellOrder = new ShellOrder((route: string): void => hub.setTab(route === 'Home'));
      const f: HomeFixture = new HomeFixture();
      f.blockersFn = (): string[] => hub.blockers([]);
      const presenter: FakePresenter = new FakePresenter();
      presenter.holdOpen = true;
      const host: HomePopupDialogHost = homeHost(f, presenter);
      const c: HomeController = await homeWithPopup(f, 0);
      hub.subscribe((): void => c.visibilityChanged());
      // 打开挂起：通过打开前复核，openCustomDialog 尚未完成。
      const t: HomePopupTicket = f.popup();
      host.sync(t);
      expect(presenter.presented.join(',')).assertEqual('1');
      // 切到「我的」：onTabWillChange 先于 selected 更新；此时首页弹窗立即收起。
      shell.showRoot(4, 'Me');
      expect(shell.selected).assertEqual(4);
      expect(f.last().popup).assertNull();
      expect(hub.visible).assertFalse();
      host.sync(f.last().popupTicket);
      expect(host.currentKey).assertEqual('');
      // 打开完成：旧实例随即关闭；迟到的显示回调不计次。
      presenter.finishOpen(1);
      await settle();
      expect(presenter.dismissed.join(',')).assertEqual('1');
      f.port.popupShown(t);
      expect(f.local.shownToday('pop', f.timer.now)).assertEqual(0);
      expect(f.shownThisRun).assertFalse();
      // 回到首页：没真正显示过，复核通过后以新的弹窗编号再弹（H28）。
      shell.showRoot(0, 'Home');
      const t2: HomePopupTicket = f.popup();
      expect(t2.popupSerial).assertLarger(t.popupSerial);
    });

    // ---------------------------------------------------------------- RC-01 Ability 重建后切 Tab 监听不丢

    it('RC_01_recompose_tab_away_blocks_late_image_and_return_counts_once', 0, async () => {
      const hub: HomeVisibilityHub = new HomeVisibilityHub((): string[] => []);
      const shell: ShellRegistry = new ShellRegistry();
      const ability: AbilityComposer = new AbilityComposer(shell, hub);
      // 同一进程里 Ability 组合两次（重建）：剪贴板与首页各只登记一项，互不覆盖。
      ability.compose();
      ability.compose();
      expect(shell.onTabWillChange.registered().join(',')).assertEqual('clipboard,home');
      expect(hub.visible).assertTrue();
      const f: HomeFixture = new HomeFixture();
      f.blockersFn = (): string[] => hub.blockers([]);
      const presenter: FakePresenter = new FakePresenter();
      const host: HomePopupDialogHost = homeHost(f, presenter);
      const c: HomeController = f.controller();
      hub.subscribe((): void => c.visibilityChanged());
      c.start();
      f.contract.pages[0].resolve(ok(page(10, [ACTIVITY, POPUP])));
      await settle();
      const image: HomePopupImageTicket = f.image();
      // 切到「我的」：剪贴板照常收到（只有重建后的那一份），首页目标值同步变为不可见。
      shell.showRoot(4, 'Me');
      expect(ability.clipboardCalls.join(',')).assertEqual('2:Me');
      expect(hub.visible).assertFalse();
      // 迟到的弹窗图片：首页不可见，不弹、不开模态实例。
      f.port.popupImageLoaded(image);
      host.sync(f.last().popupTicket);
      await settle();
      expect(f.last().popup).assertNull();
      expect(presenter.presented.length).assertEqual(0);
      expect(f.local.shownToday('pop', f.timer.now)).assertEqual(0);
      // 回到首页：复核通过后弹出，只计一次。
      shell.showRoot(0, 'Home');
      expect(ability.clipboardCalls.join(',')).assertEqual('2:Me,2:Home');
      expect(hub.visible).assertTrue();
      expect(f.last().popup !== null).assertTrue();
      const t: HomePopupTicket = f.popup();
      host.sync(t);
      await settle();
      expect(presenter.presented.length).assertEqual(1);
      f.port.popupShown(t);
      f.port.popupShown(t);
      expect(f.local.shownToday('pop', f.timer.now)).assertEqual(1);
      expect(f.shownThisRun).assertTrue();
    });

    it('RC_01_recompose_resyncs_hub_to_real_tab_stack_foreground', 0, async () => {
      const hub: HomeVisibilityHub = new HomeVisibilityHub((): string[] => []);
      const shell: ShellRegistry = new ShellRegistry();
      const ability: AbilityComposer = new AbilityComposer(shell, hub);
      ability.compose();
      shell.showRoot(4, 'Me');
      expect(hub.visible).assertFalse();
      // 重建前的目标值过时（例如在「我的」经历前后台同步时按首页 Tab 写入）：重建按真实状态重设。
      hub.setForeground(true, true);
      expect(hub.visible).assertTrue();
      ability.compose();
      expect(hub.visible).assertFalse();
      // 重建时导航栈上有页面：即使回到首页 Tab 仍不可见；栈清空后可见。
      ability.stackEmpty = false;
      ability.compose();
      shell.showRoot(0, 'Home');
      expect(hub.visible).assertFalse();
      hub.setStackEmpty(true);
      expect(hub.visible).assertTrue();
      expect(shell.onTabWillChange.registered().join(',')).assertEqual('clipboard,home');
    });
  });
}
