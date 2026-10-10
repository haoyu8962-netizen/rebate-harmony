// APP-07 鸿蒙剪贴板识别的本地假服务集成测试（brief §2.11）：真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer，不连任何地址）、
// 真实 Router / StackNavigator（经 Router 打开页面，导航栈改动经 StackNavigator.onStackChanged 同步通知执行层，与 entry 同一接线）、
// 执行层 ClipboardController 的生命周期入口（onForeground / onBackground，与 EntryAbility 同一入口）。系统剪贴板用可数读写次数的
// 假剪贴板（测试替身只替代系统能力）。样例全部是演示数据；测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  BridgeHost, ClipboardController, ClipboardDeps, ClipboardPromptView, ClipboardReadDecision, ClipboardReadPolicy, ClipboardResultView,
  ClipboardSensitive, ClipboardSnapshot, GuardState, InvitePasteOutcome, LaunchReadiness, ManualPasteAction,
  MemoryClipboardHashStore, MemoryPendingBackend, PasteboardPort, PasteOutcome, PendingActionStore, PrivacyState,
  RouteRequest, RouteSource, Router, RouteTable, StackNavigator, TransportRequest, TransportResponse,
  UpdateCheckStatus, UpdateState, ApiClientSearchPort, RouteDestination, ParseRow, ClipboardNoticeText,
  ProductDetailController, ProductPhase, ClipboardResultBinding, ClipboardPromptBinding, LocalDataCleanerRegistry,
  PrivacyGate, MemoryPrivacyStore, PrivacyWithdrawalCleaners, CleanReport,
  ClipboardClassifier, ClipboardClassification, ClipboardContext, ClipboardRules, ClipboardText, ManualPasteDecision,
  MemoryUpdateStore,
  PreferencesUpdateStore, RoutingSync, StoreChoice, UpdateCheckResult, UpdateGate, UpdateGateState, UpdatePersisted,
  UpdateRouting, UpdateStatusRaw, UpdateStoreListing
} from '../../Index';
import { RouteSpec } from 'generated';
import { MemoryPathStack } from './App05bFixture';
import { Deferred, envelope, flush, Rig } from './NetworkTestRig';

const PRODUCT_LINK: string = 'https://e.tb.cn/h.Demo01?tk=Sample';
const PRODUCT_TEXT: string = '分享好物 ' + PRODUCT_LINK + ' 「全脂纯牛奶 250ml」 其他说明文字不上传';
const INVITE_TEXT: string = '我在用凑狸，邀请码 K7M3QX';
const ORDINARY_TEXT: string = '今天下午三点在楼下见面';
const TAB_ROOTS: string[] = ['Home', 'AgentChat', 'OrderList', 'Me'];

function card(key: string): string {
  return '{"product_key":"' + key + '","item_ref":"ref-' + key + '","platform":"taobao","title":"降噪蓝牙耳机",'
    + '"image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
    + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"link-' + key + '","cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00",'
    + '"stale":false,"age_sec":12,"source":"taobao_union","disclaimer_keys":["price_basis"],"availability":"ok"}';
}

function oneCard(): string {
  return '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"' + PRODUCT_LINK + '"},"card":' + card('tb:1')
    + '}]}';
}

/** 假系统剪贴板：可数读写次数；hold 时读取挂起，由测试放行（模拟读取期间切后台等）。 */
class FakePasteboard implements PasteboardPort {
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

  writeText(text: string): Promise<boolean> {
    this.writes++;
    this.text = text;
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

class ClipFixture {
  readonly rig: Rig;
  readonly pasteboard: FakePasteboard = new FakePasteboard();
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly store: MemoryClipboardHashStore = new MemoryClipboardHashStore();
  readonly controller: ClipboardController;
  readonly snapshots: ClipboardSnapshot[] = [];
  consent: string = ClipboardReadPolicy.CONSENT_AGREED;
  overlay: string = ClipboardSensitive.OVERLAY_NONE;
  guest: boolean = true;
  tab: string = 'Home';
  nowMs: number = 1800000000000;
  /** parse 的回答；null 时挂起到 held。 */
  reply: TransportResponse | null = envelope(0, oneCard());
  held: Deferred[] = [];
  opened: RouteDestination[] = [];
  /** 送进强更入口的次数与参数（ClipboardDeps.forceUpdate；生产为 AppUpdate.on10405）。 */
  forced: (string | null)[] = [];
  /** 强更入口之后再接的真实处理（R2-01 测试接真实 UpdateGate.onServerForced，与 entry AppClipboard 同一接线）。 */
  forceHook: ((minSupported: string | null) => void) | null = null;

  constructor(loggedIn: boolean = false) {
    this.rig = loggedIn ? new Rig() : new Rig(null);
    this.guest = !loggedIn;
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
      // 与 entry ShellState.showRoot 同：切 Tab 生效之前同步通知执行层
      this.tab = d.route;
      this.controller.tabChanged(d.route, false);
      return true;
    };
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => this.nowMs),
      (): GuardState => new GuardState('consented', 'ok', this.guest ? 'guest' : 'phone_bound', true, '1.0.0', false),
      this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
    const deps: ClipboardDeps = new ClipboardDeps(this.pasteboard, new ApiClientSearchPort(this.rig.client));
    deps.consent = (): string => this.consent;
    deps.overlay = (): string => this.overlay;
    deps.scope = (): string => ClipboardController.scopeKey(this.rig.client.captureScope());
    deps.guest = (): boolean => this.guest;
    deps.config = (): Record<string, Object> => {
      const c: Record<string, Object> = {};
      c['share_domains'] = ['share.example.test'];
      return c;
    };
    deps.open = (route: string, params: Record<string, Object>): boolean => {
      this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
      const names: string[] = this.stack.getAllPathName();
      return names.length > 0 && names[names.length - 1] === route;
    };
    deps.clock = (): number => this.nowMs;
    deps.store = this.store;
    deps.forceUpdate = (minSupported: string | null): void => {
      this.forced.push(minSupported);
      const hook: ((m: string | null) => void) | null = this.forceHook;
      if (hook !== null) {
        hook(minSupported);
      }
    };
    this.controller = new ClipboardController(deps);
    this.controller.onChange = (s: ClipboardSnapshot): void => {
      this.snapshots.push(s);
    };
    // 与 entry AppRouting 同：导航栈经 StackNavigator 改动后同步通知执行层
    this.navigator.onStackChanged = (names: string[]): void => this.controller.stackChanged(names);
    this.controller.sync();
    this.controller.onForeground();
  }

  open(route: string): void {
    this.router.open(RouteRequest.of(route, RouteSource.IN_APP));
  }

  /** 系统返回（不经 StackNavigator）：页面 onWillDisappear 的同步出口 → pageLeft，再出栈并同步栈。 */
  back(): void {
    this.controller.pageLeft();
    const names: string[] = this.stack.getAllPathName();
    this.stack.names = names.slice(0, names.length - 1);
    this.controller.stackChanged(this.stack.getAllPathName());
  }

  /** 直接把一个需前置条件的页面放到栈顶（如 Withdraw 需实名）：模拟用户已经停在那一页。 */
  standOn(route: string): void {
    this.stack.pushPathByName(route, new RouteDestination(route));
    this.controller.stackChanged(this.stack.getAllPathName());
  }

  parseCount(): number {
    return this.rig.server.count('/v1/inputs/parse');
  }

  parseBody(): Record<string, Object> {
    return JSON.parse(this.rig.server.last('/v1/inputs/parse').body ?? '{}') as Record<string, Object>;
  }

  top(): string {
    const names: string[] = this.stack.getAllPathName();
    return names.length === 0 ? '' : names[names.length - 1];
  }

  result(): ClipboardResultView | null {
    return this.controller.snapshot.result;
  }
}

export default function clipboardIntegrationTest() {
  describe('ClipboardIntegration', () => {
    it('foreground_never_reads_on_harmony', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = PRODUCT_TEXT;
      const first: ClipboardReadDecision | null = f.controller.watcher.lastDecision;
      expect(first !== null && first.actionRaw === ClipboardReadPolicy.ACTION_PASTE_ONLY).assertTrue();
      for (let i: number = 0; i < 3; i++) {
        f.controller.onBackground();
        const d: ClipboardReadDecision | null = f.controller.onForeground();
        expect(d !== null && d.actionRaw === ClipboardReadPolicy.ACTION_PASTE_ONLY).assertTrue();
      }
      // 已在前台时重复的 onForeground 不算一次回前台
      expect(f.controller.onForeground() === null).assertTrue();
      await flush();
      expect(f.pasteboard.reads).assertEqual(0);
      expect(f.parseCount()).assertEqual(0);
      expect(f.controller.snapshot.prompt === null).assertTrue();
    });

    it('AC-S1-03.a_paste_button_success_reads_once_and_parses_once', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = PRODUCT_TEXT;
      // 临时授权失败：不读
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, false)).assertEqual(PasteOutcome.NO_AUTH);
      expect(f.pasteboard.reads).assertEqual(0);
      expect(f.parseCount()).assertEqual(0);
      const outcome: string = await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect(outcome).assertEqual(ManualPasteAction.PARSE);
      expect(f.pasteboard.reads).assertEqual(1);
      expect(f.parseCount()).assertEqual(1);
      const body: Record<string, Object> = f.parseBody();
      expect(body['scene'] as string).assertEqual('clipboard');
      // 只上传链接与「」标题，原文其余部分不上传
      expect(body['text'] as string).assertEqual(PRODUCT_LINK + '\n全脂纯牛奶 250ml');
      expect(JSON.stringify(body).indexOf('其他说明文字')).assertEqual(-1);
      // 1 张卡：以进程内种子经 Router 打开 ProductDetail（参数只有 platform / product_key / item_ref），沿用 parse 卡的 link_id
      expect(f.top()).assertEqual('ProductDetail');
      const seed: Record<string, Object> | null = f.controller.seeds.take('tb:1');
      expect(seed !== null && seed['link_id'] === 'link-tb:1').assertTrue();
      // e：全程系统剪贴板写入 0 次、内容不变
      expect(f.pasteboard.writes).assertEqual(0);
      expect(f.pasteboard.text).assertEqual(PRODUCT_TEXT);
    });

    it('AC-S1-03.b_ordinary_text_no_upload_local_30132', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = '「全脂纯牛奶 250ml」 ' + ORDINARY_TEXT;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true))
        .assertEqual(ManualPasteAction.SEARCH_PREFILL);
      await flush();
      expect(f.parseCount()).assertEqual(0);
      const r: ClipboardResultView | null = f.result();
      expect(r !== null && r.kind === ClipboardResultView.UNRECOGNIZED && r.textKey === 'error.30132').assertTrue();
      expect((r as ClipboardResultView).prefill).assertEqual('全脂纯牛奶 250ml');
      // 【用商品名搜索】：首页发起 → 经 Router 打开 Search（q 预填）
      f.controller.searchByName(r as ClipboardResultView);
      expect(f.top()).assertEqual('Search');
      expect(f.pasteboard.writes).assertEqual(0);
    });

    it('empty_clipboard_home_opens_search_typing', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = null;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true))
        .assertEqual(ManualPasteAction.OPEN_SEARCH_TYPING);
      expect(f.top()).assertEqual('Search');
      expect(f.parseCount()).assertEqual(0);
    });

    it('AC-S1-03.d_sensitive_pages_skip_and_no_catchup', 0, async () => {
      for (const route of ['Withdraw', 'FindOrder', 'Login']) {
        const f: ClipFixture = new ClipFixture();
        f.pasteboard.text = PRODUCT_TEXT;
        if (route === 'Login') {
          f.open('Login');
        } else {
          f.standOn(route);
        }
        expect(f.top()).assertEqual(route);
        f.controller.onBackground();
        const d: ClipboardReadDecision | null = f.controller.onForeground();
        expect(d !== null && d.actionRaw === ClipboardReadPolicy.ACTION_SKIP && d.reasonRaw === 'sensitive').assertTrue();
        // 敏感页上即便有入口被点到，执行层也不读
        expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true))
          .assertEqual(PasteOutcome.SKIPPED);
        f.back();
        expect(f.controller.homeRoot()).assertTrue();
        await flush();
        expect(f.pasteboard.reads).assertEqual(0);
        expect(f.parseCount()).assertEqual(0);
        expect(f.controller.snapshot.prompt === null && f.result() === null).assertTrue();
      }
    });

    it('sensitive_overlay_and_basic_mode_do_not_read', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = PRODUCT_TEXT;
      f.overlay = ClipboardSensitive.OVERLAY_AUTH_SHEET;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.SKIPPED);
      f.overlay = ClipboardSensitive.OVERLAY_NONE;
      f.consent = ClipboardReadPolicy.CONSENT_BASIC;
      f.controller.sync();
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.SKIPPED);
      expect((await f.controller.pasteInvite(true)).actionRaw).assertEqual(InvitePasteOutcome.SKIPPED);
      expect(f.pasteboard.reads).assertEqual(0);
    });

    it('AC-S1-63.b_guest_invite_prompt_prefills_login_without_request', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = INVITE_TEXT;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.INVITE_PROMPT);
      const prompt: ClipboardPromptView | null = f.controller.snapshot.prompt;
      expect(prompt !== null && prompt.kind === 'invite' && prompt.inviteCode === 'K7M3QX').assertTrue();
      expect(f.controller.confirmPrompt((prompt as ClipboardPromptView).id)).assertTrue();
      expect(f.top()).assertEqual('Login');
      expect(f.controller.snapshot.prompt === null).assertTrue();
      // 不发任何请求（游客只预填不上传）；进入验证码页时取走一次
      expect(f.rig.server.received.length).assertEqual(0);
      expect(f.controller.invitePrefill.take()).assertEqual('K7M3QX');
      expect(f.controller.invitePrefill.take() === null).assertTrue();
      // 本机记录只有 hash 与时间，没有原文
      expect(f.store.dump().join(';').indexOf('K7M3QX')).assertEqual(-1);
      expect(f.store.dump().join(';').indexOf('邀请码')).assertEqual(-1);
    });

    it('AC-S1-63.d_product_priority_and_close', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = PRODUCT_LINK + ' https://share.example.test/i/K7M3QX 邀请码 K7M3QX';
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
      await flush();
      expect(f.controller.snapshot.prompt === null).assertTrue();
      expect(f.parseCount()).assertEqual(1);
      // 邀请落地页链接不算商品链接、不上传
      expect(f.parseBody()['text'] as string).assertEqual(PRODUCT_LINK);
      // 关闭邀请确认：放弃，不打开登录页
      const g: ClipFixture = new ClipFixture();
      g.pasteboard.text = INVITE_TEXT;
      await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      g.controller.closePrompt((g.controller.snapshot.prompt as ClipboardPromptView).id);
      expect(g.controller.snapshot.prompt === null && g.top() === '').assertTrue();
      expect(g.controller.invitePrefill.pending).assertFalse();
    });

    it('AC-S1-63.e_logged_in_and_self_written_no_invite_prompt', 0, async () => {
      // 已登录（G01：不出邀请确认，本人码与已有上级只在判定逻辑里覆盖；共性第 19 条：静默，不落入 30132）
      const f: ClipFixture = new ClipFixture(true);
      f.pasteboard.text = INVITE_TEXT;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.IGNORED);
      expect(f.controller.snapshot.prompt === null && f.result() === null).assertTrue();
      // App 自写（复制邀请文案）：游客也不出邀请确认，纯邀请内容静默
      const g: ClipFixture = new ClipFixture();
      await g.controller.writer.write(INVITE_TEXT);
      expect(await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.IGNORED);
      expect(g.controller.snapshot.prompt === null && g.result() === null).assertTrue();
      expect(g.controller.ledger.contains(INVITE_TEXT)).assertTrue();
      expect(g.store.dump().join(';').indexOf('K7M3QX')).assertEqual(-1);
      expect(f.rig.server.count('/v1/inputs/parse') + g.rig.server.count('/v1/inputs/parse')).assertEqual(0);
    });

    it('late_parse_dropped_after_background_tab_privacy_account', 0, async () => {
      const exits: string[] = ['background', 'tab', 'privacy', 'account', 'overlay', 'environment'];
      for (const exit of exits) {
        const f: ClipFixture = new ClipFixture(exit === 'account');
        f.reply = null;
        f.pasteboard.text = PRODUCT_TEXT;
        await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
        await flush();
        expect(f.held.length).assertEqual(1);
        if (exit === 'background') {
          f.controller.onBackground();
          f.controller.onForeground();
        } else if (exit === 'tab') {
          f.open('Me');
          expect(f.tab).assertEqual('Me');
          f.open('Home');
        } else if (exit === 'privacy') {
          f.consent = ClipboardReadPolicy.CONSENT_OUTDATED;
          f.rig.client.invalidate();
          f.controller.sync();
          f.consent = ClipboardReadPolicy.CONSENT_AGREED;
        } else if (exit === 'account') {
          f.rig.client.onSessionChanged();
          f.controller.sync();
        } else if (exit === 'overlay') {
          f.overlay = ClipboardSensitive.OVERLAY_AUTH_JUMP;
          f.controller.overlayShown();
          f.overlay = ClipboardSensitive.OVERLAY_NONE;
        } else {
          f.controller.environmentSwitched();
        }
        f.held[0].resolve(envelope(0, oneCard()));
        await flush();
        expect(f.top() === 'ProductDetail').assertFalse();
        expect(f.result() === null).assertTrue();
        expect(f.controller.snapshot.busy).assertFalse();
      }
    });

    it('late_read_dropped_after_background_and_one_read_per_click', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = PRODUCT_TEXT;
      f.pasteboard.hold = true;
      const first: Promise<string> = f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      // 读取在途时再点：不再读
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.BUSY);
      expect(f.pasteboard.reads).assertEqual(1);
      // 读取期间切后台（临时授权失效）：读到的内容丢弃，不分类、不上传
      f.controller.onBackground();
      f.pasteboard.release();
      expect(await first).assertEqual(PasteOutcome.DROPPED);
      await flush();
      expect(f.parseCount()).assertEqual(0);
      expect(f.result() === null && f.controller.snapshot.prompt === null).assertTrue();
    });

    it('page_covered_then_back_to_same_instance_drops_old_parse', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.open('Search');
      f.reply = null;
      f.pasteboard.text = PRODUCT_TEXT;
      const filled: string[] = [];
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true, (q: string): void => {
        filled.push(q);
      });
      await flush();
      expect(f.held.length).assertEqual(1);
      // 盖上另一页再返回同一个搜索页实例
      const params: Record<string, Object> = {};
      params['platform'] = 'taobao';
      params['product_key'] = 'tb:9';
      f.router.open(RouteRequest.of('ProductDetail', RouteSource.IN_APP, params));
      f.back();
      expect(f.top()).assertEqual('Search');
      f.held[0].resolve(envelope(0, oneCard()));
      await flush();
      expect(f.top()).assertEqual('Search');
      expect(f.result() === null).assertTrue();
      expect(filled.length).assertEqual(0);
    });

    it('retry_after_blocks_all_paste_entries', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.reply = envelope(42901, '{}', { 'Retry-After': '7' });
      f.pasteboard.text = PRODUCT_TEXT;
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect(f.controller.blocked).assertTrue();
      expect(f.controller.snapshot.blocked).assertTrue();
      const r: ClipboardResultView | null = f.result();
      expect(r !== null && r.kind === ClipboardResultView.NOTICE && r.textKey === 'error.42901').assertTrue();
      const readsBefore: number = f.pasteboard.reads;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.BLOCKED);
      f.open('Login');
      expect((await f.controller.pasteInvite(true)).actionRaw).assertEqual(InvitePasteOutcome.BLOCKED);
      expect(f.pasteboard.reads).assertEqual(readsBefore);
      // 到期后恢复
      f.nowMs += 7000;
      f.controller.refreshBlocked();
      expect(f.controller.blocked).assertFalse();
      f.pasteboard.text = INVITE_TEXT;
      const invite: InvitePasteOutcome = await f.controller.pasteInvite(true);
      expect(invite.actionRaw === InvitePasteOutcome.FILL && invite.code === 'K7M3QX').assertTrue();
      expect(f.parseCount()).assertEqual(1);
    });

    it('retry_after_missing_or_zero_defaults_to_5s', 0, async () => {
      for (const header of ['', '0', 'abc']) {
        const f: ClipFixture = new ClipFixture();
        const headers: Record<string, string> = {};
        if (header.length > 0) {
          headers['Retry-After'] = header;
        }
        f.reply = envelope(42901, '{}', headers);
        f.pasteboard.text = PRODUCT_TEXT;
        await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
        await flush();
        f.nowMs += 4999;
        expect(f.controller.blocked).assertTrue();
        f.nowMs += 1;
        expect(f.controller.blocked).assertFalse();
      }
    });

    it('multi_results_rows_keep_code_actions_and_trace', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.reply = envelope(0, '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"' + PRODUCT_LINK + '"},"card":'
        + card('tb:1') + '},{"hit":{"platform":"taobao","kind":"text","raw":"「保温杯 500ml」"},"error_code":30132},'
        + '{"hit":{"platform":"jd","kind":"url","raw":"https://u.jd.com/x"},"error_code":42901}]}');
      f.pasteboard.text = PRODUCT_TEXT;
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const r: ClipboardResultView | null = f.result();
      expect(r !== null && r.kind === ClipboardResultView.CARD_LIST && r.rows.length === 3).assertTrue();
      expect((r as ClipboardResultView).traceId).assertEqual('trace-abcdef123456');
      // 行内 42901：启动共享禁用期（5 秒）
      expect(f.controller.blocked).assertTrue();
      // 行内 30132：【用商品名搜索】预填这一行的「」标题（禁用期内不执行，共性第 16 条；到期后执行）
      const row: ParseRow = (r as ClipboardResultView).rows[1];
      f.controller.searchByName(r as ClipboardResultView, row);
      expect(f.top()).assertEqual('');
      f.nowMs += 5000;
      f.controller.searchByName(r as ClipboardResultView, row);
      expect(f.top()).assertEqual('Search');
      expect(f.result() === null).assertTrue();
    });

    it('server_error_and_30131_notices', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.reply = envelope(50001, '{}');
      f.pasteboard.text = PRODUCT_TEXT;
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const r: ClipboardResultView | null = f.result();
      expect(r !== null && r.kind === ClipboardResultView.NOTICE && r.textKey === 'error.50001'
        && r.traceId === 'trace-abcdef123456').assertTrue();
      const g: ClipFixture = new ClipFixture();
      g.reply = envelope(30131, '{}');
      g.pasteboard.text = PRODUCT_TEXT;
      await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const n: ClipboardResultView | null = g.result();
      expect(n !== null && n.textKey === 'error.30131').assertTrue();
      // 整体 30132：用上传片段里的「」标题预填
      const h: ClipFixture = new ClipFixture();
      h.reply = envelope(30132, '{}');
      h.pasteboard.text = PRODUCT_TEXT;
      await h.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const u: ClipboardResultView | null = h.result();
      expect(u !== null && u.kind === ClipboardResultView.UNRECOGNIZED && u.prefill === '全脂纯牛奶 250ml').assertTrue();
    });

    it('search_typing_30132_fills_same_page', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.open('Search');
      f.pasteboard.text = '「保温杯 500ml」 好用';
      const filled: string[] = [];
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true, (q: string): void => {
        filled.push(q);
      });
      const r: ClipboardResultView | null = f.result();
      expect(r !== null && r.kind === ClipboardResultView.UNRECOGNIZED).assertTrue();
      f.controller.searchByName(r as ClipboardResultView);
      expect(filled.join(',')).assertEqual('保温杯 500ml');
      expect(f.stack.getAllPathName().length).assertEqual(1);
      // SearchTyping 上剪贴板为空：留在本页，不另开
      f.pasteboard.text = '';
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true))
        .assertEqual(ManualPasteAction.OPEN_SEARCH_TYPING);
      expect(f.stack.getAllPathName().length).assertEqual(1);
    });

    it('login_invite_paste_fill_and_not_found', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.open('Login');
      f.pasteboard.text = 'https://share.example.test/i/K7M3QX';
      const ok: InvitePasteOutcome = await f.controller.pasteInvite(true);
      expect(ok.actionRaw === InvitePasteOutcome.FILL && ok.code === 'K7M3QX').assertTrue();
      f.pasteboard.text = '这里没有邀请码';
      expect((await f.controller.pasteInvite(true)).actionRaw).assertEqual(InvitePasteOutcome.NOT_FOUND);
      expect((await f.controller.pasteInvite(false)).actionRaw).assertEqual(InvitePasteOutcome.NO_AUTH);
      expect(f.pasteboard.reads).assertEqual(2);
      expect(f.pasteboard.writes).assertEqual(0);
      expect(f.rig.server.received.length).assertEqual(0);
    });

    it('self_write_records_hash_only_and_withdraw_clears', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      const tpwd: string = '￥Zx8Cv7Bn6Mq￥ 复制口令打开淘宝';
      expect(await f.controller.writer.write(tpwd)).assertTrue();
      expect(f.pasteboard.writes).assertEqual(1);
      expect(f.controller.ledger.contains(tpwd)).assertTrue();
      expect(f.store.dump().join(';').indexOf('Zx8Cv7Bn6Mq')).assertEqual(-1);
      // 撤回同意：hash 记录全部清掉
      f.consent = ClipboardReadPolicy.CONSENT_OUTDATED;
      f.controller.sync();
      expect(f.controller.ledger.contains(tpwd)).assertFalse();
      expect(f.store.dump().length).assertEqual(0);
    });

    it('web_auto_detect_suppression_is_per_container_and_not_persisted', 0, () => {
      const f: ClipFixture = new ClipFixture();
      f.controller.setWebAutoDetect('web-1', false);
      expect(f.controller.webSuppressed('web-1')).assertTrue();
      expect(f.controller.webSuppressed('web-2')).assertFalse();
      expect(f.store.dump().length).assertEqual(0);
      f.controller.webClosed('web-1');
      expect(f.controller.webSuppressed('web-1')).assertFalse();
      f.controller.setWebAutoDetect('web-3', false);
      f.controller.setWebAutoDetect('web-3', true);
      expect(f.controller.webSuppressed('web-3')).assertFalse();
    });

    it('bridge_events_never_carry_clipboard_content', 0, () => {
      const empty: Record<string, Object> = {};
      expect(BridgeHost.eventMessage('app.resume', empty) !== null).assertTrue();
      const leak: Record<string, Object> = {};
      leak['clipboard'] = PRODUCT_TEXT;
      expect(BridgeHost.eventMessage('app.resume', leak) === null).assertTrue();
      expect(BridgeHost.eventMessage('clipboard.changed', empty) === null).assertTrue();
    });

    it('lesson9_unknown_5xxxx_falls_back_to_50001_with_trace6', 0, () => {
      const texts: Map<string, string> = new Map<string, string>();
      texts.set('error.50001', '出了点问题，请稍后再试（{trace6}）');
      texts.set('error.30131', '暂不支持这个链接或平台');
      texts.set('error.50401', '服务繁忙');
      const format = (key: string, vars: Map<string, string>): string => {
        let t: string = texts.get(key) ?? '';
        vars.forEach((v: string, k: string) => {
          t = t.split('{' + k + '}').join(v);
        });
        return t;
      };
      // 未收录的 5xxxx：回落 error.50001 正文，带 trace 末 6 位
      expect(ClipboardNoticeText.of('error.50999', 'trace-abcdef123456', format)).assertEqual('出了点问题，请稍后再试（123456）');
      // 收录但文案里没有占位：统一补 trace6
      expect(ClipboardNoticeText.of('error.50401', 'trace-abcdef123456', format)).assertEqual('服务繁忙（123456）');
      // 没有 trace_id：不带编号；4xxxx 不回落
      expect(ClipboardNoticeText.of('error.30131', null, format)).assertEqual('暂不支持这个链接或平台');
      expect(ClipboardNoticeText.of('error.39999', null, format)).assertEqual('');
    });

    it('seeded_detail_shows_parse_card_without_refetch', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = PRODUCT_TEXT;
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const seed: Record<string, Object> | null = f.controller.seeds.take('tb:1');
      const before: number = f.rig.server.received.length;
      const detail: ProductDetailController = new ProductDetailController(new ApiClientSearchPort(f.rig.client),
        (): Record<string, Object> => {
          const c: Record<string, Object> = {};
          c['loggedIn'] = false;
          c['privacy'] = 'consented';
          return c;
        });
      detail.load('taobao', 'tb:1', 'ref-tb:1', seed);
      await flush();
      expect(detail.snapshot.phase).assertEqual(ProductPhase.CONTENT);
      expect((detail.snapshot.product as Record<string, Object>)['link_id'] as string).assertEqual('link-tb:1');
      expect(f.rig.server.received.length).assertEqual(before);
      // 种子只用一次（取走即丢弃）
      expect(f.controller.seeds.take('tb:1') === null).assertTrue();
    });

    it('lesson14_withdraw_clear_retried_until_persisted', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      await f.controller.writer.write('https://e.tb.cn/h.Self01');
      f.store.failWrites = true;
      f.consent = ClipboardReadPolicy.CONSENT_OUTDATED;
      f.controller.sync();
      expect(f.controller.recordsClearPending).assertTrue();
      expect(f.store.dump().length > 0).assertTrue();
      // 落盘恢复后：回前台重试并确认清掉
      f.store.failWrites = false;
      f.controller.onBackground();
      f.controller.onForeground();
      expect(f.controller.recordsClearPending).assertFalse();
      expect(f.store.dump().length).assertEqual(0);
    });

    it('lesson13_manual_paste_landing_only_not_uploaded', 0, async () => {
      // 只有邀请落地页链接：不上传 parse，游客出邀请确认（本地抽码）
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = 'https://share.example.test/i/K7M3QX';
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.INVITE_PROMPT);
      await flush();
      expect(f.parseCount()).assertEqual(0);
      // 已登录：不上传，静默结束（共性第 19 条：不落入 30132）
      const g: ClipFixture = new ClipFixture(true);
      g.pasteboard.text = 'https://share.example.test/i/K7M3QX';
      expect(await g.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true)).assertEqual(PasteOutcome.IGNORED);
      expect(g.result() === null).assertTrue();
      await flush();
      expect(g.parseCount()).assertEqual(0);
    });

    it('lesson15_search_typing_invite_inline_confirm', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.open('Search');
      f.pasteboard.text = '邀请码 K7M3QX';
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true))
        .assertEqual(PasteOutcome.INVITE_PROMPT);
      const p: ClipboardPromptView | null = f.controller.snapshot.prompt;
      expect(p !== null && p.entry === 'search_typing' && p.inviteCode === 'K7M3QX').assertTrue();
      expect(f.controller.confirmPrompt((p as ClipboardPromptView).id)).assertTrue();
      expect(f.top()).assertEqual('Login');
      expect(f.rig.server.received.length).assertEqual(0);
      expect(f.controller.invitePrefill.take()).assertEqual('K7M3QX');
    });

    it('lesson16_result_buttons_check_block_and_currency', 0, async () => {
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = INVITE_TEXT;
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      const p: ClipboardPromptView | null = f.controller.snapshot.prompt;
      expect(p !== null).assertTrue();
      // 过时的提示编号：不预填、不导航
      expect(f.controller.confirmPrompt((p as ClipboardPromptView).id + 1)).assertFalse();
      expect(f.top()).assertEqual('');
      expect(f.controller.invitePrefill.pending).assertFalse();
      // 多卡结果在共享禁用期内：【用商品名搜索】与点卡都不执行
      const g: ClipFixture = new ClipFixture();
      g.reply = envelope(0, '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"x"},"card":' + card('tb:1')
        + '},{"hit":{"platform":"jd","kind":"url","raw":"y"},"error_code":42901}]}');
      g.pasteboard.text = PRODUCT_TEXT;
      await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const r: ClipboardResultView | null = g.result();
      expect(r !== null && g.controller.blocked).assertTrue();
      const row: ParseRow = (r as ClipboardResultView).rows[0];
      expect(g.controller.openCard(r as ClipboardResultView, row)).assertFalse();
      expect(g.top()).assertEqual('');
      g.nowMs += 5000;
      expect(g.controller.openCard(r as ClipboardResultView, row)).assertTrue();
      expect(g.top()).assertEqual('ProductDetail');
    });

    it('h_r1_01_withdraw_hash_delete_failure_reported_through_registry_and_gate', 0, async () => {
      // 真实清理注册表 + 真实 PrivacyGate（与 entry AppPrivacy 同一接线：报告 ok 才 withdrawalCleanupDone）
      const f: ClipFixture = new ClipFixture();
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      PrivacyWithdrawalCleaners.registerPlaceholders(registry);
      f.controller.installCleaner(registry);
      const privacy: MemoryPrivacyStore = new MemoryPrivacyStore();
      const reports: CleanReport[] = [];
      const wire = (g: PrivacyGate): void => {
        g.withdrawalCleanup = (): void => {
          PrivacyWithdrawalCleaners.run(registry).then((report: CleanReport): void => {
            reports.push(report);
            if (report.ok) {
              g.withdrawalCleanupDone();
            }
          });
        };
      };
      let gate: PrivacyGate = new PrivacyGate(privacy, (): number => 1, '1');
      wire(gate);
      gate.agree(1);
      await f.controller.writer.write('https://e.tb.cn/h.Self01');
      expect(f.store.dump().length > 0).assertTrue();
      // 撤回同意时 hash 删除没落盘：注册表记为失败，撤回待清理标记保留
      f.store.failWrites = true;
      gate.withdraw(2);
      await flush();
      expect(reports.length).assertEqual(1);
      expect(reports[0].ok).assertFalse();
      expect(reports[0].failed.indexOf(ClipboardController.CLEANER_NAME) >= 0).assertTrue();
      expect(gate.withdrawalCleanupPending).assertTrue();
      expect(privacy.withdrawalCleanupPending).assertTrue();
      expect(gate.credentialsReadable()).assertFalse();
      expect(f.controller.recordsClearPending).assertTrue();
      expect(f.store.dump().length > 0).assertTrue();
      // 下次冷启动：落盘恢复，重试清理成功 → 报告 ok、标记清除、hash 清空
      f.store.failWrites = false;
      gate = new PrivacyGate(privacy, (): number => 3, '1');
      wire(gate);
      gate.coldStart(3);
      expect(gate.retryPendingWithdrawalCleanup()).assertTrue();
      await flush();
      expect(reports.length).assertEqual(2);
      expect(reports[1].ok).assertTrue();
      expect(privacy.withdrawalCleanupPending).assertFalse();
      expect(f.controller.recordsClearPending).assertFalse();
      expect(f.store.dump().length).assertEqual(0);
    });

    it('h_r1_02_manual_paste_excludes_self_written', 0, async () => {
      // 复制口令 / 桥 clipboard.write 写入含商品链接的内容 → 首页与 SearchTyping 的手动粘贴都不上传 parse
      const f: ClipFixture = new ClipFixture();
      expect(await f.controller.writer.write(PRODUCT_TEXT)).assertTrue();
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true))
        .assertEqual(ManualPasteAction.SEARCH_PREFILL);
      await flush();
      expect(f.parseCount()).assertEqual(0);
      const r: ClipboardResultView | null = f.result();
      expect(r !== null && r.kind === ClipboardResultView.UNRECOGNIZED).assertTrue();
      f.open('Search');
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true, (_q: string): void => {
      })).assertEqual(ManualPasteAction.SEARCH_PREFILL);
      await flush();
      expect(f.parseCount()).assertEqual(0);
      // 换成用户自己复制的同一链接（未经 App 写入）：照常上传
      const g: ClipFixture = new ClipFixture();
      g.pasteboard.text = PRODUCT_TEXT;
      await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect(g.parseCount()).assertEqual(1);
    });

    it('h_r1_03_late_callbacks_of_result_a_do_not_act_on_result_b', 0, async () => {
      const twoCards = (a: string, b: string): TransportResponse => envelope(0, '{"results":[{"hit":{"platform":"taobao",'
        + '"kind":"url","raw":"x"},"card":' + card(a) + '},{"hit":{"platform":"taobao","kind":"url","raw":"y"},"card":'
        + card(b) + '}]}');
      const f: ClipFixture = new ClipFixture();
      f.pasteboard.text = PRODUCT_TEXT;
      f.reply = twoCards('tb:1', 'tb:2');
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const a: ClipboardResultView = f.result() as ClipboardResultView;
      // 渲染 A 时绑定（与 AppClipboard.apply 同一个绑定类）
      const bindA: ClipboardResultBinding = new ClipboardResultBinding(f.controller, a);
      const rowA: ParseRow = a.rows[0];
      f.reply = twoCards('tb:3', 'tb:4');
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const b: ClipboardResultView = f.result() as ClipboardResultView;
      expect(b !== a && b.rows.length === 2).assertTrue();
      const bindB: ClipboardResultBinding = new ClipboardResultBinding(f.controller, b);
      // A 的回调迟到：点卡、行内搜索、整体搜索、关闭、弹层 onDisappear 都不作用于 B
      expect(bindA.openRow(rowA)).assertFalse();
      bindA.searchRow(rowA);
      bindA.searchByName();
      bindA.close();
      expect(f.top()).assertEqual('');
      expect(f.result() === b).assertTrue();
      expect(f.controller.seeds.take('tb:1') === null).assertTrue();
      // 旧行配新结果也不行（行必须属于绑定的结果）
      expect(bindB.openRow(rowA)).assertFalse();
      expect(f.top()).assertEqual('');
      // B 自己的回调照常
      expect(bindB.openRow(b.rows[0])).assertTrue();
      expect(f.top()).assertEqual('ProductDetail');
      expect(f.controller.seeds.take('tb:3') !== null).assertTrue();
      // 多卡弹层换成提示后，弹层迟到的 onDisappear 不清掉提示
      const g: ClipFixture = new ClipFixture();
      g.pasteboard.text = PRODUCT_TEXT;
      g.reply = twoCards('tb:1', 'tb:2');
      await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const sheet: ClipboardResultBinding = new ClipboardResultBinding(g.controller, g.result() as ClipboardResultView);
      g.pasteboard.text = ORDINARY_TEXT;
      await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      const notice: ClipboardResultView | null = g.result();
      expect(notice !== null && notice.kind === ClipboardResultView.UNRECOGNIZED).assertTrue();
      sheet.close();
      expect(g.result() === notice).assertTrue();
      // 邀请确认条：旧提示的确认 / 关闭不作用于新提示
      const h: ClipFixture = new ClipFixture();
      h.pasteboard.text = INVITE_TEXT;
      await h.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      const p1: ClipboardPromptBinding = new ClipboardPromptBinding(h.controller,
        (h.controller.snapshot.prompt as ClipboardPromptView).id);
      h.pasteboard.text = '邀请码 K7M3QX';
      await h.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      const p2: ClipboardPromptView = h.controller.snapshot.prompt as ClipboardPromptView;
      expect(p2.id !== p1.promptId).assertTrue();
      expect(p1.confirm()).assertFalse();
      p1.close();
      expect(h.controller.snapshot.prompt === p2).assertTrue();
      expect(h.top()).assertEqual('');
      expect(h.controller.invitePrefill.pending).assertFalse();
      expect(new ClipboardPromptBinding(h.controller, p2.id).confirm()).assertTrue();
      expect(h.top()).assertEqual('Login');
    });

    it('h_r1_04_logged_in_pure_invite_is_silent', 0, async () => {
      for (const text of ['邀请码 K7M3QX', INVITE_TEXT, 'https://share.example.test/i/K7M3QX']) {
        for (const entry of [ManualPasteAction.ENTRY_HOME, ManualPasteAction.ENTRY_SEARCH_TYPING]) {
          const f: ClipFixture = new ClipFixture(true);
          if (entry === ManualPasteAction.ENTRY_SEARCH_TYPING) {
            f.open('Search');
          }
          const filled: string[] = [];
          f.pasteboard.text = text;
          expect(await f.controller.pasteProduct(entry, true, (q: string): void => {
            filled.push(q);
          })).assertEqual(PasteOutcome.IGNORED);
          await flush();
          // 不发 parse、不出 30132「识别不了」与【用商品名搜索】、不出邀请确认、不预填邀请码
          expect(f.parseCount()).assertEqual(0);
          expect(f.result() === null).assertTrue();
          expect(f.controller.snapshot.prompt === null).assertTrue();
          expect(filled.length).assertEqual(0);
          expect(f.controller.invitePrefill.pending).assertFalse();
          expect(f.controller.snapshot.busy).assertFalse();
        }
      }
      // 已登录的普通文字（不是邀请内容）仍给本地 30132
      const g: ClipFixture = new ClipFixture(true);
      g.pasteboard.text = ORDINARY_TEXT;
      expect(await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true))
        .assertEqual(ManualPasteAction.SEARCH_PREFILL);
      expect(g.result() !== null).assertTrue();
    });

    it('h_r1_05_inline_10405_enters_force_update', 0, async () => {
      // 单条：外层 code=0，结果 error_code=10405
      const f: ClipFixture = new ClipFixture();
      f.reply = envelope(0, '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"x"},"error_code":10405}]}');
      f.pasteboard.text = PRODUCT_TEXT;
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect(f.forced.length).assertEqual(1);
      expect(f.forced[0] === null).assertTrue();
      expect(f.result() === null && f.top() === '').assertTrue();
      expect(f.controller.snapshot.busy).assertFalse();
      // 多条之一 10405：同样进强更，不出多卡弹层、不跳详情
      const g: ClipFixture = new ClipFixture();
      g.reply = envelope(0, '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"x"},"card":' + card('tb:1')
        + '},{"hit":{"platform":"jd","kind":"url","raw":"y"},"error_code":10405}]}');
      g.pasteboard.text = PRODUCT_TEXT;
      await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect(g.forced.length).assertEqual(1);
      expect(g.result() === null && g.top() === '').assertTrue();
      // 归属检查保留：离开发起页后迟到的行内 10405 只丢弃
      const h: ClipFixture = new ClipFixture();
      h.reply = null;
      h.pasteboard.text = PRODUCT_TEXT;
      await h.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      h.open('Me');
      h.held[0].resolve(envelope(0, '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"x"},"error_code":10405}]}'));
      await flush();
      expect(h.forced.length).assertEqual(0);
      // 没有 10405 的普通结果不进强更
      const k: ClipFixture = new ClipFixture();
      k.pasteboard.text = PRODUCT_TEXT;
      await k.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect(k.forced.length).assertEqual(0);
    });

    it('h_r2_01_inline_10405_forces_update_page_despite_cached_minimum', 0, async () => {
      // 共性第 21 条：本机 2.0.0，启动检查缓存的最低版本低于 / 等于本机（ok）；随后 parse 行内 10405 → 真实 UpdateGate 强制 below_min，
      // 经 RoutingSync（entry AppRouting 同一同步出口）进 ForceUpdate，不按缓存最低版本放行
      for (const cachedMin of ['1.0.0', '2.0.0']) {
        const f: ClipFixture = new ClipFixture();
        const store: MemoryUpdateStore = new MemoryUpdateStore();
        const result: UpdateCheckResult = new UpdateCheckResult(cachedMin, null, '2.1.0', 'huawei',
          [new UpdateStoreListing('huawei', '2.1.0')], 1800);
        const gate: UpdateGate = new UpdateGate(store, (): number => f.nowMs, '2.0.0', 'harmony', 'agc', null);
        gate.onColdStart(f.nowMs);
        gate.apply(result, f.nowMs);
        expect(gate.state(f.nowMs).statusRaw).assertEqual(UpdateStatusRaw.OK);
        f.forceHook = (_m: string | null): void => gate.onServerForced(f.nowMs);
        f.reply = envelope(0, '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"x"},"error_code":10405}]}');
        f.pasteboard.text = PRODUCT_TEXT;
        await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
        await flush();
        expect(f.forced.length).assertEqual(1);
        const forced: UpdateGateState = gate.state(f.nowMs);
        expect(forced.statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
        // 目标版本不取不高于本机的缓存最低版本；选店要求高于本机（2.1.0 可选）
        expect(forced.targetVersion === null).assertTrue();
        const choice: StoreChoice = gate.pickStore(result, f.nowMs, (_k: string): boolean => true);
        expect(choice.storeKey === 'huawei' && !choice.unavailable).assertTrue();
        // 页面分流：结论同步后导航栈只剩 ForceUpdate
        const sync: RoutingSync = new RoutingSync(f.router, f.navigator, (): boolean => true);
        sync.sync(new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateRouting.status(forced, 0)), f.nowMs);
        expect(f.stack.getAllPathName().join(',')).assertEqual('ForceUpdate');
        // 冷启动（同版本）仍强更；落盘编解码保留该标记
        const cold: UpdateGate = new UpdateGate(store, (): number => f.nowMs, '2.0.0', 'harmony', 'agc', null);
        expect(cold.state(f.nowMs).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
        const saved: UpdatePersisted = store.load();
        expect(PreferencesUpdateStore.decode(PreferencesUpdateStore.encode(saved)).forcedByServer).assertTrue();
        // 升级到新版本后失效（G15），检查失败按 unknown
        const upgraded: UpdateGate = new UpdateGate(store, (): number => f.nowMs, '2.1.0', 'harmony', 'agc', null);
        upgraded.onColdStart(f.nowMs);
        upgraded.applyFailure(f.nowMs);
        expect(upgraded.state(f.nowMs).statusRaw).assertEqual(UpdateStatusRaw.UNKNOWN);
        // 之后一次成功检查解除
        gate.apply(result, f.nowMs);
        expect(gate.state(f.nowMs).statusRaw).assertEqual(UpdateStatusRaw.OK);
        expect(store.load().forcedByServer).assertFalse();
      }
    });

    it('h_r2_02_manual_product_paste_uses_length_and_shape_filter', 0, async () => {
      // 共性第 22 条：手动粘贴商品入口与自动分类同一套过滤（F-CLIP-02），没通过的不上传、走本地 30132
      let long: string = PRODUCT_TEXT;
      while (long.length < 502) {
        long = long + '好';
      }
      expect(ClipboardText.codePoints(long)).assertEqual(502);
      const verdict: ClipboardClassification = ClipboardClassifier.classify(long,
        new ClipboardContext([], [], true, null, ['share.example.test']), ClipboardRules.defaults, 0);
      // 自动分类不把它当商品（超长；随后按邀请再判、无触发字样，故原因为 no_trigger）
      expect(verdict.kindRaw).assertEqual(ClipboardClassifier.KIND_NONE);
      const tooLong: ManualPasteDecision = ManualPasteAction.decide(ManualPasteAction.ENTRY_HOME, long,
        ClipboardRules.defaults);
      expect(tooLong.actionRaw === ManualPasteAction.SEARCH_PREFILL && tooLong.uploadText === null).assertTrue();
      const tooShort: ManualPasteDecision = ManualPasteAction.decide(ManualPasteAction.ENTRY_HOME, 'http://x',
        ClipboardRules.defaults);
      expect(tooShort.actionRaw).assertEqual(ManualPasteAction.SEARCH_PREFILL);
      for (const text of [long, 'http://x']) {
        for (const entry of [ManualPasteAction.ENTRY_HOME, ManualPasteAction.ENTRY_SEARCH_TYPING]) {
          const f: ClipFixture = new ClipFixture();
          if (entry === ManualPasteAction.ENTRY_SEARCH_TYPING) {
            f.open('Search');
          }
          f.pasteboard.text = text;
          expect(await f.controller.pasteProduct(entry, true, (_q: string): void => {
          })).assertEqual(ManualPasteAction.SEARCH_PREFILL);
          await flush();
          expect(f.parseCount()).assertEqual(0);
          const r: ClipboardResultView | null = f.result();
          expect(r !== null && r.kind === ClipboardResultView.UNRECOGNIZED).assertTrue();
        }
      }
      // 邀请分支仍独立判断：超长、含商品链接与「邀请码」的内容不当商品上传，与自动分类一致按纯邀请处理（游客出确认条）
      let mixed: string = '邀请码 K7M3QX https://e.tb.cn/h.Demo01 ';
      while (mixed.length < 502) {
        mixed = mixed + '好';
      }
      expect(ClipboardClassifier.classify(mixed, new ClipboardContext([], [], true, null, ['share.example.test']),
        ClipboardRules.defaults, 0).kindRaw).assertEqual(ClipboardClassifier.KIND_INVITE);
      const m: ClipFixture = new ClipFixture();
      m.pasteboard.text = mixed;
      expect(await m.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.INVITE_PROMPT);
      await flush();
      expect(m.parseCount()).assertEqual(0);
      const prompt: ClipboardPromptView | null = m.controller.snapshot.prompt;
      expect(prompt !== null && prompt.inviteCode === 'K7M3QX').assertTrue();
      // 边界：恰好 500 字、恰好 10 字（白名单内的淘口令）、11 字的白名单短链照常上传
      // FU-CLIP §0.2 例外改动：原用 http://x.y 当「恰好 10 字的商品链接」，x.y 不在白名单（K01），改用白名单内的候选做长度边界
      let edge: string = PRODUCT_TEXT;
      while (edge.length < 500) {
        edge = edge + '好';
      }
      for (const text of [edge, '￥AbCdEf12￥', 'http://3.cn']) {
        const g: ClipFixture = new ClipFixture();
        g.pasteboard.text = text;
        expect(await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
        await flush();
        expect(g.parseCount()).assertEqual(1);
      }
      // 补一例：http://x.y 不在白名单，不上传，本地 30132
      const x: ClipFixture = new ClipFixture();
      x.pasteboard.text = 'http://x.y';
      expect(await x.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.SEARCH_PREFILL);
      await flush();
      expect(x.parseCount()).assertEqual(0);
    });

    it('h_r2_03_ledger_save_failure_blocks_system_write', 0, async () => {
      // 共性第 23 条：自写 hash 落盘失败 → 不写系统剪贴板、返回失败（桥回 90500、复制口令按失败提示）
      const f: ClipFixture = new ClipFixture();
      f.store.failWrites = true;
      expect(await f.controller.writer.write(PRODUCT_TEXT)).assertFalse();
      expect(f.pasteboard.writes).assertEqual(0);
      expect(f.pasteboard.text === null).assertTrue();
      expect(f.controller.ledger.contains(PRODUCT_TEXT)).assertFalse();
      // 存储恢复后再粘贴：系统剪贴板里没有这段 App 内容，不会上传未登记的自写内容
      f.store.failWrites = false;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true))
        .assertEqual(ManualPasteAction.OPEN_SEARCH_TYPING);
      await flush();
      expect(f.parseCount()).assertEqual(0);
      // 恢复后再次复制：先登记再写入，粘贴不上传
      expect(await f.controller.writer.write(PRODUCT_TEXT)).assertTrue();
      expect(f.pasteboard.writes).assertEqual(1);
      expect(f.controller.ledger.contains(PRODUCT_TEXT)).assertTrue();
      const g: ClipFixture = new ClipFixture();
      expect(await g.controller.writer.write(PRODUCT_TEXT)).assertTrue();
      expect(await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true))
        .assertEqual(ManualPasteAction.SEARCH_PREFILL);
      await flush();
      expect(g.parseCount()).assertEqual(0);
    });

    it('route_names_exist_in_routes_json', 0, () => {
      for (const name of [ClipboardController.HOME_ROUTE, ClipboardController.SEARCH_ROUTE,
        ClipboardController.LOGIN_ROUTE, ClipboardController.PRODUCT_DETAIL_ROUTE, ClipboardController.WEB_PAGE_ROUTE]) {
        expect(RouteTable.has(name)).assertTrue();
      }
      for (const name of ClipboardSensitive.ROUTES) {
        expect(RouteTable.has(name)).assertTrue();
      }
      expect(RouteTable.has('InviteBackfill')).assertFalse();
    });
  });
}
