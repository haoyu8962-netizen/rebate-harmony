// FU-CLIP 鸿蒙第 1 轮评审（harmony-review-r1 R1-01…R1-04）的回归测试：真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer，不连任何
// 地址）、真实 Router / StackNavigator、执行层 ClipboardController。系统分享走与 EntryAbility → AppClipboard.receiveShare 同一个执行层入口
// ClipboardController.receiveShare（Want action + 取内容函数；取内容用可控延迟的替身代替 systemShare.getSharedData）。样例全部是演示数据。
// R1-03 的按钮用 designsystem 真实的 CouliFixedTap（ClipboardPromptBar / ClipboardNotice / CouliSheetPanel 的 onClick 就是它）。
import { describe, it, expect } from '@ohos/hypium';
import { CouliFixedTap } from 'designsystem/Logic';
import {
  ApiClientSearchPort, ClipboardController, ClipboardDeps, ClipboardPromptBinding, ClipboardPromptView,
  ClipboardReadPolicy, ClipboardResultBinding, ClipboardResultView, ClipboardSensitive, ClipboardSnapshot, GuardState,
  LaunchReadiness, ManualPasteAction, MemoryClipboardHashStore, MemoryClipboardSaltStore, MemoryPendingBackend,
  PasteboardPort, PendingActionStore, PrivacyState, RouteDestination, RouteRequest, RouteSource, Router, RouteTable,
  SharedTextRecord, ShareImportAction, ShareReceipt, StackNavigator, TransportRequest, TransportResponse,
  UpdateCheckStatus, UpdateState
} from '../../Index';
import { RouteSpec } from 'generated';
import { MemoryPathStack } from './App05bFixture';
import { Deferred, envelope, flush, Rig } from './NetworkTestRig';

const TB_LINK: string = 'https://m.tb.cn/h.Demo01?tk=Sample';
const JD_LINK: string = 'https://u.jd.com/demo';
const TAB_ROOTS: string[] = ['Home', 'AgentChat', 'OrderList', 'Me'];
const TEXT_UTD: string = 'general.plain-text';

function card(key: string): string {
  return '{"product_key":"' + key + '","item_ref":"ref-' + key + '","platform":"taobao","title":"降噪蓝牙耳机",'
    + '"image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
    + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"link-' + key + '","cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00",'
    + '"stale":false,"age_sec":12,"source":"taobao_union","disclaimer_keys":["price_basis"],"availability":"ok"}';
}

function oneCard(): string {
  return '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"' + TB_LINK + '"},"card":' + card('tb:1') + '}]}';
}

function twoCards(): string {
  return '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"' + TB_LINK + '"},"card":' + card('tb:1') + '},'
    + '{"hit":{"platform":"taobao","kind":"url","raw":"' + TB_LINK + '"},"card":' + card('tb:2') + '}]}';
}

/** 可控的 systemShare.getSharedData 替身：记下调用次数，每次返回一个由测试决定何时、以什么结果完成的 Promise。 */
class ShareSource {
  calls: number = 0;
  private resolvers: ((records: SharedTextRecord[] | null) => void)[] = [];
  private rejecters: ((e: Object) => void)[] = [];

  fetch(): () => Promise<SharedTextRecord[] | null> {
    return (): Promise<SharedTextRecord[] | null> => {
      this.calls++;
      return new Promise<SharedTextRecord[] | null>((resolve: (r: SharedTextRecord[] | null) => void,
        reject: (e: Object) => void): void => {
        this.resolvers.push(resolve);
        this.rejecters.push(reject);
      });
    };
  }

  /** 第 index 次取内容返回一条文本记录。 */
  text(index: number, text: string): void {
    this.resolvers[index]([new SharedTextRecord(TEXT_UTD, text)]);
  }

  records(index: number, records: SharedTextRecord[]): void {
    this.resolvers[index](records);
  }

  fail(index: number): void {
    this.rejecters[index](new Error('1003703001'));
  }
}

/** 假系统剪贴板（读取可挂起；写入次数始终为 0）。 */
class HoldPasteboard implements PasteboardPort {
  text: string | null = null;
  reads: number = 0;
  writes: number = 0;
  hold: boolean = false;
  private releases: (() => void)[] = [];

  readText(): Promise<string | null> {
    this.reads++;
    const value: string | null = this.text;
    if (!this.hold) {
      return Promise.resolve(value);
    }
    return new Promise<string | null>((resolve: (v: string | null) => void): void => {
      this.releases.push((): void => resolve(value));
    });
  }

  writeText(_text: string): Promise<boolean> {
    this.writes++;
    return Promise.resolve(true);
  }

  release(): void {
    const list: (() => void)[] = this.releases;
    this.releases = [];
    for (const r of list) {
      r();
    }
  }
}

class Fixture {
  readonly rig: Rig = new Rig(null);
  readonly pasteboard: HoldPasteboard = new HoldPasteboard();
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly controller: ClipboardController;
  readonly share: ShareSource = new ShareSource();
  consent: string = ClipboardReadPolicy.CONSENT_AGREED;
  overlay: string = ClipboardSensitive.OVERLAY_NONE;
  reply: TransportResponse | null = envelope(0, oneCard());
  held: Deferred[] = [];

  /** foreground=false：冷启动——onCreate 已同步隐私结论，还没进过前台。 */
  constructor(foreground: boolean = true) {
    this.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      if (r.url.indexOf('/v1/inputs/parse') >= 0) {
        const fixed: TransportResponse | null = this.reply;
        if (fixed !== null) {
          return Promise.resolve(fixed);
        }
        const d: Deferred = new Deferred();
        this.held.push(d);
        return d.promise;
      }
      return Promise.resolve(envelope(0, '{}'));
    };
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => {
      if (d.route === null || TAB_ROOTS.indexOf(d.route) < 0) {
        return false;
      }
      this.controller.tabChanged(d.route, false);
      return true;
    };
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => 1800000000000),
      (): GuardState => new GuardState('consented', 'ok', 'guest', true, '1.0.0', false),
      this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
    const deps: ClipboardDeps = new ClipboardDeps(this.pasteboard, new ApiClientSearchPort(this.rig.client));
    deps.consent = (): string => this.consent;
    deps.overlay = (): string => this.overlay;
    deps.scope = (): string => ClipboardController.scopeKey(this.rig.client.captureScope());
    deps.guest = (): boolean => true;
    deps.open = (route: string, params: Record<string, Object>): boolean => {
      this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
      return true;
    };
    deps.clock = (): number => 1800000000000;
    deps.store = new MemoryClipboardHashStore();
    deps.saltStore = new MemoryClipboardSaltStore();
    this.controller = new ClipboardController(deps);
    this.controller.onChange = (_s: ClipboardSnapshot): void => {
    };
    this.navigator.onStackChanged = (names: string[]): void => this.controller.stackChanged(names);
    this.controller.sync();
    if (foreground) {
      this.controller.onForeground();
    }
  }

  /** EntryAbility onCreate / onNewWant → AppClipboard.receiveShare(want) 的执行层入口。 */
  receive(action: string = ShareReceipt.WANT_ACTION): Promise<string> {
    return this.controller.receiveShare(action, this.share.fetch());
  }

  open(route: string): void {
    this.router.open(RouteRequest.of(route, RouteSource.IN_APP));
  }

  standOn(route: string): void {
    this.stack.pushPathByName(route, new RouteDestination(route));
    this.controller.stackChanged(this.stack.getAllPathName());
  }

  parseCount(): number {
    return this.rig.server.count('/v1/inputs/parse');
  }

  parseText(): string {
    const body: Record<string, Object> = JSON.parse(this.rig.server.last('/v1/inputs/parse').body ?? '{}') as
    Record<string, Object>;
    return body['text'] as string;
  }

  prompt(): ClipboardPromptView | null {
    return this.controller.snapshot.prompt;
  }

  promptPlatform(): string {
    const p: ClipboardPromptView | null = this.prompt();
    return p === null || p.info === null ? '' : p.info.platform;
  }

  result(): ClipboardResultView | null {
    return this.controller.snapshot.result;
  }

  binding(): ClipboardPromptBinding {
    const p: ClipboardPromptView | null = this.prompt();
    return new ClipboardPromptBinding(this.controller, p === null ? -1 : p.id);
  }

  resultBinding(): ClipboardResultBinding | null {
    const r: ClipboardResultView | null = this.result();
    return r === null ? null : new ClipboardResultBinding(this.controller, r);
  }
}

/**
 * ClipboardPromptBar / ClipboardNotice 的按钮在测试里的对应：@Event 属性随父页面渲染而更新（与 ArkUI 一样可变），按钮登记的 onClick 就是
 * 组件属性链里的 CouliFixedTap.of(this.onAction, this.actionKey)——渲染一次登记一次。
 */
class BarHarness {
  onAction: () => void = (): void => {
  };
  onClose: () => void = (): void => {
  };
  actionKey: number = 0;

  /** 父页面按新的提示 / 结果渲染（ClipboardUiModel 的 *Action() 在渲染时取出的固定回调）。 */
  render(action: () => void, close: () => void, key: number): void {
    this.onAction = action;
    this.onClose = close;
    this.actionKey = key;
  }

  /** 组件属性链此刻登记的点击回调。 */
  registeredAction(): () => void {
    return CouliFixedTap.of(this.onAction, this.actionKey);
  }

  registeredClose(): () => void {
    return CouliFixedTap.of(this.onClose, this.actionKey);
  }
}

/** ClipboardUiModel.promptConfirmAction / promptCloseAction 的同一写法：渲染时把这一次的绑定固定在闭包里。 */
function promptActions(f: Fixture): (() => void)[] {
  const b: ClipboardPromptBinding = f.binding();
  return [(): void => {
    b.confirm();
  }, (): void => {
    b.close();
  }];
}

export default function clipboardFuClipReviewR1Test() {
  describe('ClipboardFuClipReviewR1', () => {
    // ------------------------------------------------------------------ R1-01：真实接收入口，收到 Want 时过闸门、固定票据
    it('r1_01_basic_mode_at_want_drops_without_fetch_even_if_consent_granted_before_return', 0, async () => {
      const f: Fixture = new Fixture();
      f.consent = ClipboardReadPolicy.CONSENT_BASIC;
      f.controller.sync();
      const pending: Promise<string> = f.receive();
      // 闸门不过：连 getSharedData 都不调
      expect(f.share.calls).assertEqual(0);
      f.consent = ClipboardReadPolicy.CONSENT_AGREED;
      f.controller.sync();
      expect(await pending).assertEqual(ShareImportAction.DROP);
      await flush();
      expect(f.prompt() === null && f.result() === null).assertTrue();
      expect(f.parseCount()).assertEqual(0);
    });

    it('r1_01_privacy_dialog_sensitive_page_and_busy_at_want_never_fetch', 0, async () => {
      const f: Fixture = new Fixture();
      f.overlay = ClipboardSensitive.OVERLAY_PRIVACY_FIRST_LAUNCH;
      expect(await f.receive()).assertEqual(ShareImportAction.DROP);
      const g: Fixture = new Fixture();
      g.standOn('Withdraw');
      expect(await g.receive()).assertEqual(ShareImportAction.DROP);
      expect(g.controller.currentRoute()).assertEqual('Withdraw');
      const h: Fixture = new Fixture();
      h.reply = null;
      h.pasteboard.text = TB_LINK;
      expect(await h.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
      expect(h.controller.snapshot.busy).assertTrue();
      expect(await h.receive()).assertEqual(ShareImportAction.IGNORE_BUSY);
      expect(f.share.calls + g.share.calls + h.share.calls).assertEqual(0);
      // 不是分享的 Want：什么都不做
      const k: Fixture = new Fixture();
      expect(await k.receive('ohos.want.action.viewData')).assertEqual(ShareReceipt.NOT_SHARE);
      expect(k.share.calls).assertEqual(0);
    });

    it('r1_01_account_switch_page_leave_or_background_while_fetching_drops_late_share', 0, async () => {
      // 换号（不等状态同步，返回时直接按原票据比较归属）
      const f: Fixture = new Fixture();
      const a: Promise<string> = f.receive();
      expect(f.share.calls).assertEqual(1);
      f.rig.client.onSessionChanged();
      f.share.text(0, TB_LINK);
      expect(await a).assertEqual(ShareImportAction.DROP);
      // 离页
      const g: Fixture = new Fixture();
      const b: Promise<string> = g.receive();
      g.open('Search');
      g.share.text(0, TB_LINK);
      expect(await b).assertEqual(ShareImportAction.DROP);
      expect(g.controller.currentRoute()).assertEqual('Search');
      // 进后台再回前台
      const h: Fixture = new Fixture();
      const c: Promise<string> = h.receive();
      h.controller.onBackground();
      h.controller.onForeground();
      h.share.text(0, TB_LINK);
      expect(await c).assertEqual(ShareImportAction.DROP);
      // 撤回再同意
      const k: Fixture = new Fixture();
      const d: Promise<string> = k.receive();
      k.consent = ClipboardReadPolicy.CONSENT_BASIC;
      k.controller.sync();
      k.consent = ClipboardReadPolicy.CONSENT_AGREED;
      k.controller.sync();
      k.share.text(0, TB_LINK);
      expect(await d).assertEqual(ShareImportAction.DROP);
      await flush();
      for (const x of [f, g, h, k]) {
        expect(x.prompt() === null && x.result() === null).assertTrue();
        expect(x.parseCount()).assertEqual(0);
      }
    });

    it('r1_01_out_of_order_returns_newest_share_wins_both_orders', 0, async () => {
      // 新分享先返回：旧分享晚到不覆盖
      const f: Fixture = new Fixture();
      const older: Promise<string> = f.receive();
      const newer: Promise<string> = f.receive();
      f.share.text(1, JD_LINK);
      expect(await newer).assertEqual(ShareImportAction.PROMPT);
      f.share.text(0, TB_LINK);
      expect(await older).assertEqual(ShareImportAction.DROP);
      expect(f.promptPlatform()).assertEqual('jd');
      // 旧分享先返回：已被替代，不出条；新分享照常
      const g: Fixture = new Fixture();
      const older2: Promise<string> = g.receive();
      const newer2: Promise<string> = g.receive();
      g.share.text(0, TB_LINK);
      expect(await older2).assertEqual(ShareImportAction.DROP);
      expect(g.prompt() === null).assertTrue();
      g.share.text(1, JD_LINK);
      expect(await newer2).assertEqual(ShareImportAction.PROMPT);
      expect(g.promptPlatform()).assertEqual('jd');
      expect(g.binding().confirm()).assertTrue();
      await flush();
      expect(g.parseCount()).assertEqual(1);
      expect(g.parseText()).assertEqual(JD_LINK);
    });

    it('r1_01_record_pick_and_fetch_failure_through_receive_entry', 0, async () => {
      const f: Fixture = new Fixture();
      const a: Promise<string> = f.receive();
      f.share.records(0, [new SharedTextRecord('general.image', null), new SharedTextRecord('general.hyperlink', TB_LINK)]);
      expect(await a).assertEqual(ShareImportAction.PROMPT);
      const g: Fixture = new Fixture();
      const b: Promise<string> = g.receive();
      g.share.records(0, [new SharedTextRecord('general.image', null)]);
      expect(await b).assertEqual(ShareImportAction.IGNORE_MIME);
      const h: Fixture = new Fixture();
      const c: Promise<string> = h.receive();
      h.share.fail(0);
      expect(await c).assertEqual(ShareReceipt.FETCH_FAILED);
      expect(h.prompt() === null && h.result() === null).assertTrue();
    });

    // ------------------------------------------------------------------ R1-02：后台暂存带票据，失效同步清空，回前台不重新赋予身份
    it('r1_02_background_stash_then_account_switch_does_not_restore', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.onBackground();
      const a: Promise<string> = f.receive();
      f.share.text(0, TB_LINK);
      expect(await a).assertEqual('pending');
      f.rig.client.onSessionChanged();
      f.controller.sync();
      f.controller.onForeground();
      expect(f.prompt() === null).assertTrue();
      expect(f.controller.lastShareAction).assertEqual(ShareImportAction.DROP);
      // 没有状态同步时也按到达身份比较
      const g: Fixture = new Fixture();
      g.controller.onBackground();
      const b: Promise<string> = g.receive();
      g.share.text(0, TB_LINK);
      await b;
      g.rig.client.onSessionChanged();
      g.controller.onForeground();
      expect(g.prompt() === null).assertTrue();
      await flush();
      expect(f.parseCount() + g.parseCount()).assertEqual(0);
    });

    it('r1_02_background_stash_then_page_change_withdraw_or_env_switch_does_not_restore', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.onBackground();
      const a: Promise<string> = f.receive();
      f.share.text(0, TB_LINK);
      await a;
      f.open('Search');
      f.controller.onForeground();
      expect(f.prompt() === null).assertTrue();
      expect(f.controller.currentRoute()).assertEqual('Search');
      const g: Fixture = new Fixture();
      g.controller.onBackground();
      const b: Promise<string> = g.receive();
      g.share.text(0, TB_LINK);
      await b;
      g.consent = ClipboardReadPolicy.CONSENT_BASIC;
      g.controller.sync();
      g.consent = ClipboardReadPolicy.CONSENT_AGREED;
      g.controller.sync();
      g.controller.onForeground();
      expect(g.prompt() === null).assertTrue();
      const h: Fixture = new Fixture();
      h.controller.onBackground();
      const c: Promise<string> = h.receive();
      h.share.text(0, TB_LINK);
      await c;
      h.controller.environmentSwitched();
      h.controller.onForeground();
      expect(h.prompt() === null).assertTrue();
      await flush();
      expect(f.parseCount() + g.parseCount() + h.parseCount()).assertEqual(0);
    });

    it('r1_02_stash_is_consumed_only_by_the_next_foreground_and_fetch_return_after_foreground', 0, async () => {
      // 对照：没有失效时回前台处理一次
      const f: Fixture = new Fixture();
      f.controller.onBackground();
      const a: Promise<string> = f.receive();
      f.share.text(0, TB_LINK);
      await a;
      f.controller.onForeground();
      expect(f.promptPlatform()).assertEqual('taobao');
      // 后台到达、回前台之后内容才返回：按到达票据处理（正好是到达后的这一次回前台）
      const g: Fixture = new Fixture();
      g.controller.onBackground();
      const b: Promise<string> = g.receive();
      g.controller.onForeground();
      g.share.text(0, TB_LINK);
      expect(await b).assertEqual(ShareImportAction.PROMPT);
      // 后台到达、回前台又进后台再回来之后才返回：已不是同一次交接，丢弃
      const h: Fixture = new Fixture();
      h.controller.onBackground();
      const c: Promise<string> = h.receive();
      h.controller.onForeground();
      h.controller.onBackground();
      h.controller.onForeground();
      h.share.text(0, TB_LINK);
      expect(await c).assertEqual(ShareImportAction.DROP);
      expect(h.prompt() === null).assertTrue();
    });

    it('r1_02_cold_start_arrival_waits_for_first_foreground_and_withdraw_drops_it', 0, async () => {
      // 冷启动（onCreate 时还没进过前台）：暂存，第一次回前台处理；启动期环境对账带来的归属变化（端点落定）不作废（HS12）。
      // 第 2 轮（R2-03）起换号（onSessionChanged）属于真实换号，冷启动期间同样作废，见 ClipboardFuClipReviewR2
      const f: Fixture = new Fixture(false);
      f.rig.context.settled = false;
      f.controller.sync();
      const a: Promise<string> = f.receive();
      f.share.text(0, TB_LINK);
      expect(await a).assertEqual('pending');
      f.rig.context.settled = true;
      f.controller.sync();
      f.controller.onForeground();
      expect(f.promptPlatform()).assertEqual('taobao');
      // 冷启动期间撤回同意 / 切换环境 / 页面变化：同步清空
      const g: Fixture = new Fixture(false);
      const b: Promise<string> = g.receive();
      g.share.text(0, TB_LINK);
      await b;
      g.consent = ClipboardReadPolicy.CONSENT_BASIC;
      g.controller.sync();
      g.consent = ClipboardReadPolicy.CONSENT_AGREED;
      g.controller.sync();
      g.controller.onForeground();
      expect(g.prompt() === null).assertTrue();
      const h: Fixture = new Fixture(false);
      const c: Promise<string> = h.receive();
      h.share.text(0, TB_LINK);
      await c;
      h.standOn('Search');
      h.controller.onForeground();
      expect(h.prompt() === null).assertTrue();
      // 冷启动时首启隐私弹窗显示中：收到即丢弃，不取内容
      const k: Fixture = new Fixture(false);
      k.overlay = ClipboardSensitive.OVERLAY_PRIVACY_FIRST_LAUNCH;
      expect(await k.receive()).assertEqual(ShareImportAction.DROP);
      expect(k.share.calls).assertEqual(0);
    });

    // ------------------------------------------------------------------ R1-03：真实按钮旧回调在提示 / 结果更新后执行无效
    it('r1_03_retained_prompt_button_callbacks_stay_bound_to_old_prompt', 0, async () => {
      const f: Fixture = new Fixture();
      const bar: BarHarness = new BarHarness();
      const a: Promise<string> = f.receive();
      f.share.text(0, TB_LINK);
      expect(await a).assertEqual(ShareImportAction.PROMPT);
      const tb: (() => void)[] = promptActions(f);
      bar.render(tb[0], tb[1], (f.prompt() as ClipboardPromptView).id);
      const oldTap: () => void = bar.registeredAction();
      const oldClose: () => void = bar.registeredClose();
      // 提示条由淘宝换成京东（同一个提示条组件，属性更新）
      const b: Promise<string> = f.receive();
      f.share.text(1, JD_LINK);
      await b;
      const jd: (() => void)[] = promptActions(f);
      bar.render(jd[0], jd[1], (f.prompt() as ClipboardPromptView).id);
      oldTap();
      oldClose();
      await flush();
      expect(f.parseCount()).assertEqual(0);
      expect(f.promptPlatform()).assertEqual('jd');
      // 新按钮照常
      bar.registeredAction()();
      await flush();
      expect(f.parseCount()).assertEqual(1);
      expect(f.parseText()).assertEqual(JD_LINK);
    });

    it('r1_03_live_read_closure_would_fire_new_prompt_control', 0, async () => {
      // 对照（变异前的写法 () => this.onAction()）：执行时读属性，会转调京东绑定——证明上面的测试能发现这个缺陷
      const f: Fixture = new Fixture();
      const bar: BarHarness = new BarHarness();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      const tb: (() => void)[] = promptActions(f);
      bar.render(tb[0], tb[1], (f.prompt() as ClipboardPromptView).id);
      const liveTap: () => void = (): void => bar.onAction();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, JD_LINK);
      const jd: (() => void)[] = promptActions(f);
      bar.render(jd[0], jd[1], (f.prompt() as ClipboardPromptView).id);
      liveTap();
      await flush();
      expect(f.parseCount()).assertEqual(1);
    });

    it('r1_03_retained_notice_buttons_do_not_act_on_newer_result', 0, async () => {
      const f: Fixture = new Fixture();
      const notice: BarHarness = new BarHarness();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, '今天见面 「蓝牙耳机」');
      const first: ClipboardResultView = f.result() as ClipboardResultView;
      const b1: ClipboardResultBinding = new ClipboardResultBinding(f.controller, first);
      notice.render((): void => b1.searchByName(), (): void => b1.close(), first.serial);
      const oldSearch: () => void = notice.registeredAction();
      const oldClose: () => void = notice.registeredClose();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, '晚上吃饭 「机械键盘」');
      const second: ClipboardResultView = f.result() as ClipboardResultView;
      const b2: ClipboardResultBinding = new ClipboardResultBinding(f.controller, second);
      notice.render((): void => b2.searchByName(), (): void => b2.close(), second.serial);
      oldSearch();
      oldClose();
      expect(f.controller.currentRoute()).assertEqual('Home');
      expect(f.result() === second).assertTrue();
      notice.registeredAction()();
      expect(f.controller.currentRoute()).assertEqual('Search');
    });

    // ------------------------------------------------------------------ R1-04：旧结果仍在、新读取或 parse 在途时结果操作被拒且快照 busy
    it('r1_04_search_by_name_refused_while_new_read_or_parse_in_flight', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, '今天见面 「蓝牙耳机」');
      const old: ClipboardResultBinding = f.resultBinding() as ClipboardResultBinding;
      // 读取在途
      f.pasteboard.hold = true;
      f.pasteboard.text = TB_LINK;
      f.reply = null;
      const paste: Promise<string> = f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      expect(f.controller.snapshot.busy).assertTrue();
      expect(f.controller.resultActionsBusy).assertTrue();
      old.searchByName();
      expect(f.controller.currentRoute()).assertEqual('Home');
      expect(f.result() === old.view).assertTrue();
      // parse 在途（旧结果仍显示）
      f.pasteboard.release();
      expect(await paste).assertEqual(ManualPasteAction.PARSE);
      await flush();
      expect(f.parseCount()).assertEqual(1);
      expect(f.result() === old.view).assertTrue();
      expect(f.controller.snapshot.busy).assertTrue();
      old.searchByName();
      expect(f.controller.currentRoute()).assertEqual('Home');
      // 在途结束：busy 解除（新结果替换旧结果）
      f.held[0].resolve(envelope(30132, '{}'));
      await flush();
      await flush();
      expect(f.controller.snapshot.busy).assertFalse();
    });

    it('r1_04_card_list_open_and_buy_refused_while_parse_in_flight', 0, async () => {
      const f: Fixture = new Fixture();
      f.reply = envelope(0, twoCards());
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      expect(f.binding().confirm()).assertTrue();
      await flush();
      await flush();
      const list: ClipboardResultView = f.result() as ClipboardResultView;
      expect(list.kind).assertEqual(ClipboardResultView.CARD_LIST);
      const old: ClipboardResultBinding = new ClipboardResultBinding(f.controller, list);
      // 新的粘贴 parse 在途，多卡弹层仍在：点卡 / 购买都不执行
      f.reply = null;
      f.pasteboard.text = TB_LINK;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
      await flush();
      expect(f.result() === list).assertTrue();
      expect(f.controller.snapshot.busy).assertTrue();
      expect(old.openRow(list.rows[0])).assertFalse();
      expect(old.openRow(list.rows[1])).assertFalse();
      expect(f.controller.currentRoute()).assertEqual('Home');
      // 对照：不在途时同一操作可用
      const g: Fixture = new Fixture();
      g.reply = envelope(0, twoCards());
      g.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      g.binding().confirm();
      await flush();
      await flush();
      const glist: ClipboardResultView = g.result() as ClipboardResultView;
      expect(new ClipboardResultBinding(g.controller, glist).openRow(glist.rows[0])).assertTrue();
      expect(g.controller.currentRoute()).assertEqual('ProductDetail');
    });

    it('r1_04_prompt_buttons_refused_while_read_in_flight', 0, async () => {
      const f: Fixture = new Fixture();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      const share: ClipboardPromptBinding = f.binding();
      f.pasteboard.hold = true;
      f.pasteboard.text = '';
      const paste: Promise<string> = f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      expect(share.confirm()).assertFalse();
      await flush();
      expect(f.parseCount()).assertEqual(0);
      f.pasteboard.release();
      await paste;
    });
  });
}
