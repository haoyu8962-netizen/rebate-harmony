// FU-CLIP 鸿蒙第 2 轮评审（harmony-review-r2 R2-01…R2-03）的回归测试：真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer，不连任何
// 地址）、真实 Router / StackNavigator、执行层 ClipboardController。粘贴走 pasteProduct（PasteButton 入口），系统分享走与 EntryAbility →
// AppClipboard.receiveShare 同一个执行层入口 receiveShare（取内容用可控延迟的替身代替 systemShare.getSharedData）。样例全部是演示数据。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, ClipboardBridgeRead, ClipboardCandidates, ClipboardController, ClipboardDeps, ClipboardLimits,
  ClipboardPageMark, ClipboardPromptBinding, ClipboardPromptView, ClipboardReadPolicy, ClipboardResultView, ClipboardRules,
  ClipboardSensitive,
  ClipboardSnapshot, ClipboardTitlePolicy, GuardState, LaunchReadiness, ManualPasteAction, ManualPasteDecision,
  MemoryClipboardHashStore, MemoryClipboardSaltStore, MemoryPendingBackend, PasteboardPort, PendingActionStore, PrivacyState,
  PurchaseModalRegistry, RouteDestination, RouteRequest, RouteSource, Router, RouteTable, SharedTextRecord,
  ShareImportAction, ShareReceipt, StackNavigator, TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState
} from '../../Index';
import { RouteSpec } from 'generated';
import { MemoryPathStack } from './App05bFixture';
import { envelope, flush, Rig } from './NetworkTestRig';

const TB_LINK: string = 'https://m.tb.cn/h.Demo01?tk=Sample';
/** 评审给的复现样例：白名单短链 + 夹带私人订单链接的「」标题。 */
const PRIVATE_TITLE_TEXT: string = 'https://e.tb.cn/demo 「查看订单 https://example.com/private?order=123」';
const TAB_ROOTS: string[] = ['Home', 'AgentChat', 'OrderList', 'Me'];
const TEXT_UTD: string = 'general.plain-text';
const SHARE_DOMAINS: string[] = ['share.example.test'];

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

/** 可控的 systemShare.getSharedData 替身。 */
class ShareSource {
  calls: number = 0;
  private resolvers: ((records: SharedTextRecord[] | null) => void)[] = [];

  fetch(): () => Promise<SharedTextRecord[] | null> {
    return (): Promise<SharedTextRecord[] | null> => {
      this.calls++;
      return new Promise<SharedTextRecord[] | null>((resolve: (r: SharedTextRecord[] | null) => void): void => {
        this.resolvers.push(resolve);
      });
    };
  }

  text(index: number, text: string): void {
    this.resolvers[index]([new SharedTextRecord(TEXT_UTD, text)]);
  }
}

class FixedPasteboard implements PasteboardPort {
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
  readonly pasteboard: FixedPasteboard = new FixedPasteboard();
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly controller: ClipboardController;
  readonly share: ShareSource = new ShareSource();
  consent: string = ClipboardReadPolicy.CONSENT_AGREED;
  /** 冷启动就绪（环境对账、隐私与会话、导航外壳；生产为 AppClipboard 接的 deps.bootReady）。 */
  ready: boolean = true;
  flags: Record<string, Object> = {};
  reply: TransportResponse = envelope(0, oneCard());

  /** cold=true：冷启动——onCreate 已同步隐私结论，环境对账还没结论（端点为空）、还没进过前台、启动未就绪。 */
  constructor(cold: boolean = false) {
    this.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      if (r.url.indexOf('/v1/inputs/parse') >= 0) {
        return Promise.resolve(this.reply);
      }
      return Promise.resolve(envelope(0, '{}'));
    };
    if (cold) {
      this.rig.context.settled = false;
      this.ready = false;
    }
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
    deps.overlay = (): string => ClipboardSensitive.OVERLAY_NONE;
    deps.scope = (): string => ClipboardController.scopeKey(this.rig.client.captureScope());
    deps.guest = (): boolean => true;
    deps.bootReady = (): boolean => this.ready;
    deps.config = (): Record<string, Object> => {
      const c: Record<string, Object> = {};
      c['share_domains'] = SHARE_DOMAINS;
      const features: Record<string, Object> = {};
      features['flags'] = this.flags;
      c['features'] = features;
      return c;
    };
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
    if (!cold) {
      this.controller.onForeground();
    }
  }

  receive(): Promise<string> {
    return this.controller.receiveShare(ShareReceipt.WANT_ACTION, this.share.fetch());
  }

  /** 环境对账有结论、导航外壳就绪：端点落定，状态同步（AppRouting.stateChanged → syncClipboard）。 */
  settle(): void {
    this.rig.context.settled = true;
    this.ready = true;
    this.controller.sync();
  }

  open(route: string): void {
    this.router.open(RouteRequest.of(route, RouteSource.IN_APP));
  }

  parseCount(): number {
    return this.rig.server.count('/v1/inputs/parse');
  }

  body(): Record<string, Object> {
    return JSON.parse(this.rig.server.last('/v1/inputs/parse').body ?? '{}') as Record<string, Object>;
  }

  prompt(): ClipboardPromptView | null {
    return this.controller.snapshot.prompt;
  }

  promptPlatform(): string {
    const p: ClipboardPromptView | null = this.prompt();
    return p === null || p.info === null ? '' : p.info.platform;
  }

  confirm(): boolean {
    const p: ClipboardPromptView | null = this.prompt();
    return new ClipboardPromptBinding(this.controller, p === null ? -1 : p.id).confirm();
  }
}

function upload(text: string, rules: ClipboardRules = ClipboardRules.defaults): string | null {
  return ClipboardCandidates.uploadText(text, rules, SHARE_DOMAINS);
}

export default function clipboardFuClipReviewR2Test() {
  describe('ClipboardFuClipReviewR2', () => {
    // ------------------------------------------------------------------ R2-01：「」标题最小化，经两条真实入口断言请求体
    it('r2_01_private_link_in_title_not_uploaded_by_home_paste', 0, async () => {
      const f: Fixture = new Fixture();
      f.pasteboard.text = PRIVATE_TITLE_TEXT;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
      await flush();
      expect(f.parseCount()).assertEqual(1);
      const text: string = f.body()['text'] as string;
      expect(text).assertEqual('https://e.tb.cn/demo');
      expect(text.indexOf('example.com') < 0 && text.indexOf('order=123') < 0 && text.indexOf('查看订单') < 0).assertTrue();
      expect(f.body()['scene']).assertEqual('clipboard');
      expect(f.pasteboard.writes).assertEqual(0);
    });

    it('r2_01_private_link_in_title_not_uploaded_by_search_typing_paste', 0, async () => {
      const f: Fixture = new Fixture();
      f.open('Search');
      f.pasteboard.text = PRIVATE_TITLE_TEXT;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true))
        .assertEqual(ManualPasteAction.PARSE);
      await flush();
      expect(f.body()['text']).assertEqual('https://e.tb.cn/demo');
    });

    it('r2_01_private_link_in_title_not_uploaded_by_share', 0, async () => {
      const f: Fixture = new Fixture();
      const a: Promise<string> = f.receive();
      f.share.text(0, PRIVATE_TITLE_TEXT);
      expect(await a).assertEqual(ShareImportAction.PROMPT);
      expect(f.parseCount()).assertEqual(0);
      expect(f.confirm()).assertTrue();
      await flush();
      expect(f.parseCount()).assertEqual(1);
      const text: string = f.body()['text'] as string;
      expect(text).assertEqual('https://e.tb.cn/demo');
      expect(text.indexOf('example.com') < 0).assertTrue();
      expect(f.body()['scene']).assertEqual(ShareImportAction.SCENE_SHARE);
    });

    it('r2_01_title_links_and_tokens_cannot_bypass_candidate_cap', 0, async () => {
      // 原文外已有 3 个候选：标题里的第 4 个白名单链接与口令不再借标题上传，标题只留商品名
      const text: string = 'https://m.tb.cn/a https://m.tb.cn/b https://m.tb.cn/c 「降噪耳机 https://m.tb.cn/d ￥AbCdEfGh12￥」';
      const expected: string = 'https://m.tb.cn/a\nhttps://m.tb.cn/b\nhttps://m.tb.cn/c\n降噪耳机';
      expect(upload(text)).assertEqual(expected);
      const f: Fixture = new Fixture();
      f.pasteboard.text = text;
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect(f.body()['text']).assertEqual(expected);
      const g: Fixture = new Fixture();
      const a: Promise<string> = g.receive();
      g.share.text(0, text);
      await a;
      g.confirm();
      await flush();
      expect(g.body()['text']).assertEqual(expected);
      // 标题里只有白名单链接：作为候选按原文位置参与排序，标题剔除后为空即不带标题
      expect(upload('「https://m.tb.cn/h.x」')).assertEqual('https://m.tb.cn/h.x');
    });

    it('r2_01_title_with_any_non_whitelisted_link_shape_is_dropped', 0, () => {
      const cases: string[] = [
        '「耳机 https://example.com/x」',
        '「耳机 https://taobao.com@evil.cn/x」',
        '「耳机 https://taobao.com.evil.cn/x」',
        '「耳机 http://127.0.0.1/x」',
        '「耳机 https://m.tb.cn:8443/x」',
        '「耳机 https://share.example.test/i/K7M2QX」',
        '「耳机 taobao://item?id=1」',
        '「耳机 example.com/private?order=1」',
        '「耳机 www.example.com」',
        '「耳机 联系 demo@example.com」',
        '「耳机 10.0.0.8/admin」',
        '「耳机 ￥AB12CD￥」',
        '「耳机 /XY1234 abc/」'
      ];
      for (const title of cases) {
        expect(upload('https://m.tb.cn/h.x ' + title)).assertEqual('https://m.tb.cn/h.x');
      }
      // 普通商品名（含价格、规格）照常带上
      expect(upload('https://m.tb.cn/h.x 「降噪耳机 3.5mm ¥99/¥199 v2.0」'))
        .assertEqual('https://m.tb.cn/h.x\n降噪耳机 3.5mm ¥99/¥199 v2.0');
    });

    it('r2_01_title_follows_tightened_rules', 0, () => {
      // 远程关掉京东 / 关掉口令：标题里的京东链接、口令按非白名单处理，整段舍弃
      const noJd: ClipboardRules = ClipboardRules.defaults.tightened(ClipboardLimits.fromFeatureFlags({ 'clipboard.enabled.jd': false }));
      expect(upload('https://m.tb.cn/h.x 「耳机 https://u.jd.com/abc」', noJd)).assertEqual('https://m.tb.cn/h.x');
      expect(upload('https://m.tb.cn/h.x 「耳机 https://u.jd.com/abc」'))
        .assertEqual('https://m.tb.cn/h.x\nhttps://u.jd.com/abc\n耳机');
      const noTpwd: ClipboardRules = ClipboardRules.defaults.tightened(new ClipboardLimits(null, null, false));
      expect(upload('https://m.tb.cn/h.x 「耳机 ￥AbCdEfGh12￥」', noTpwd)).assertEqual('https://m.tb.cn/h.x');
      expect(ClipboardTitlePolicy.minimize(null, ClipboardRules.defaults, SHARE_DOMAINS) === null).assertTrue();
    });

    it('r2_01_bridge_read_and_manual_decision_use_minimized_title', 0, () => {
      expect(ClipboardBridgeRead.respond(ClipboardReadPolicy.CONSENT_AGREED, (): string => PRIVATE_TITLE_TEXT,
        ClipboardRules.defaults, SHARE_DOMAINS)).assertEqual('https://e.tb.cn/demo');
      const d: ManualPasteDecision = ManualPasteAction.decide(ManualPasteAction.ENTRY_HOME, PRIVATE_TITLE_TEXT,
        ClipboardRules.defaults, SHARE_DOMAINS);
      expect(d.uploadText).assertEqual('https://e.tb.cn/demo');
      const payload: string | null = ShareImportAction.payload(ShareImportAction.MIME_TEXT, PRIVATE_TITLE_TEXT,
        ClipboardRules.defaults, SHARE_DOMAINS).uploadText;
      expect(payload).assertEqual('https://e.tb.cn/demo');
    });

    it('r2_01_search_prefill_does_not_carry_title_link_or_token', 0, async () => {
      // 同类路径：【用商品名搜索】预填点了就发搜索，预填与上传同一套最小化
      // 手动粘贴、没有候选：标题夹带私人链接 → 预填留空（不退回首行）
      const f: Fixture = new Fixture();
      f.pasteboard.text = '今天见面 「查看订单 https://example.com/private?order=123」';
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.SEARCH_PREFILL);
      const r: ClipboardResultView = f.controller.snapshot.result as ClipboardResultView;
      expect(r.kind).assertEqual(ClipboardResultView.UNRECOGNIZED);
      expect(r.prefill === null).assertTrue();
      expect(f.parseCount()).assertEqual(0);
      // 首行是非白名单链接：留空；普通首行照常
      expect(ManualPasteAction.decide(ManualPasteAction.ENTRY_HOME, 'https://example.com/a', ClipboardRules.defaults,
        SHARE_DOMAINS).prefill === null).assertTrue();
      expect(ManualPasteAction.decide(ManualPasteAction.ENTRY_HOME, '全脂纯牛奶 250ml\n第二行', ClipboardRules.defaults,
        SHARE_DOMAINS).prefill).assertEqual('全脂纯牛奶 250ml');
      // 分享、没有候选
      const g: Fixture = new Fixture();
      const a: Promise<string> = g.receive();
      g.share.text(0, '聊天 「订单 https://example.com/p?o=1」');
      expect(await a).assertEqual(ShareImportAction.SEARCH_PREFILL);
      expect((g.controller.snapshot.result as ClipboardResultView).prefill === null).assertTrue();
      // 有候选、服务端整体 30132：请求前绑定的标题也是最小化后的
      const h: Fixture = new Fixture();
      h.reply = envelope(30132, 'null');
      h.pasteboard.text = PRIVATE_TITLE_TEXT;
      await h.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const hr: ClipboardResultView = h.controller.snapshot.result as ClipboardResultView;
      expect(hr.kind === ClipboardResultView.UNRECOGNIZED && hr.prefill === null).assertTrue();
      const k: Fixture = new Fixture();
      k.reply = envelope(30132, 'null');
      k.pasteboard.text = 'https://e.tb.cn/demo 「降噪耳机 https://m.tb.cn/h.x」';
      await k.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect((k.controller.snapshot.result as ClipboardResultView).prefill).assertEqual('降噪耳机');
    });

    // ------------------------------------------------------------------ R2-02：页面退出通知带页面实例与世代
    it('r2_02_old_search_exit_callbacks_after_share_to_home_keep_home_prompt', 0, async () => {
      const f: Fixture = new Fixture();
      f.open('Search');
      // AppSearchPage：aboutToAppear 取实例编号，onShown 登记
      const page: number = f.controller.pageInstance();
      const mark: ClipboardPageMark = f.controller.pageShown(page);
      const a: Promise<string> = f.receive();
      f.share.text(0, TB_LINK);
      expect(await a).assertEqual(ShareImportAction.PROMPT);
      expect(f.controller.currentRoute()).assertEqual('Home');
      // 清栈回首页之后，旧搜索页的 onHidden / onWillDisappear 迟到
      f.controller.pageLeft(mark);
      f.controller.pageLeft(mark);
      expect(f.promptPlatform()).assertEqual('taobao');
      expect(f.confirm()).assertTrue();
      await flush();
      expect(f.parseCount()).assertEqual(1);
      expect(f.body()['scene']).assertEqual(ShareImportAction.SCENE_SHARE);
    });

    it('r2_02_page_exit_still_invalidates_its_own_operations', 0, async () => {
      // 页面仍是当前界面的主人（被盖住但栈变化还没到）：它发起的读取作废
      const f: Fixture = new Fixture();
      f.open('Search');
      const page: number = f.controller.pageInstance();
      const mark: ClipboardPageMark = f.controller.pageShown(page);
      f.pasteboard.text = TB_LINK;
      f.pasteboard.hold = true;
      const paste: Promise<string> = f.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true);
      f.controller.pageLeft(mark);
      f.pasteboard.release();
      expect(await paste).assertEqual('dropped');
      await flush();
      expect(f.parseCount()).assertEqual(0);
      // 同一实例再次显示后，上一次显示的标记迟到：不作废新显示的操作；当前标记照常作废
      const g: Fixture = new Fixture();
      g.open('Search');
      const p2: number = g.controller.pageInstance();
      const first: ClipboardPageMark = g.controller.pageShown(p2);
      const second: ClipboardPageMark = g.controller.pageShown(p2);
      g.pasteboard.text = TB_LINK;
      g.pasteboard.hold = true;
      const late: Promise<string> = g.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true);
      g.controller.pageLeft(first);
      // 另一个页面实例的标记也不算
      g.controller.pageLeft(new ClipboardPageMark(p2 + 1, second.gen));
      g.pasteboard.release();
      expect(await late).assertEqual(ManualPasteAction.PARSE);
      await flush();
      expect(g.parseCount()).assertEqual(1);
      g.controller.pageLeft(second);
      expect(g.controller.snapshot.busy).assertFalse();
    });

    it('r2_02_stale_modal_of_cleared_page_does_not_register_overlay', 0, () => {
      const reg: PurchaseModalRegistry = new PurchaseModalRegistry();
      const page: Object = new Object();
      reg.prune(['Search']);
      // 清栈回首页（分享导入）后，旧搜索页迟到的弹层通知：页面已不在栈里，不登记、不算敏感浮层出现
      reg.prune([]);
      expect(reg.setModal(page, 'Search', true)).assertFalse();
      expect(reg.active).assertFalse();
      expect(reg.size).assertEqual(0);
      // 对照：页面在栈里时照常登记
      reg.prune(['Search']);
      expect(reg.setModal(page, 'Search', true)).assertTrue();
    });

    // ------------------------------------------------------------------ R2-03：冷启动等环境、会话与前台都就绪后再取操作身份
    it('r2_03_cold_start_content_first_waits_for_boot_ready', 0, async () => {
      const f: Fixture = new Fixture(true);
      const a: Promise<string> = f.receive();
      f.share.text(0, TB_LINK);
      expect(await a).assertEqual('pending');
      // 前台先到、环境对账还没结论：不出提示（不会出了又被端点落定清掉）
      f.controller.onForeground();
      expect(f.prompt() === null).assertTrue();
      f.settle();
      expect(f.promptPlatform()).assertEqual('taobao');
      expect(f.confirm()).assertTrue();
      await flush();
      expect(f.parseCount()).assertEqual(1);
      expect(f.body()['scene']).assertEqual(ShareImportAction.SCENE_SHARE);
      expect(f.body()['text']).assertEqual(TB_LINK);
    });

    it('r2_03_cold_start_content_late_after_foreground_and_after_ready', 0, async () => {
      // 内容在前台之后、就绪之前返回：暂存，就绪后的状态同步处理
      const f: Fixture = new Fixture(true);
      const a: Promise<string> = f.receive();
      f.controller.onForeground();
      f.share.text(0, TB_LINK);
      expect(await a).assertEqual('pending');
      expect(f.prompt() === null).assertTrue();
      f.settle();
      expect(f.promptPlatform()).assertEqual('taobao');
      // 内容在就绪之后才返回：直接处理
      const g: Fixture = new Fixture(true);
      const b: Promise<string> = g.receive();
      g.controller.onForeground();
      g.settle();
      g.share.text(0, TB_LINK);
      expect(await b).assertEqual(ShareImportAction.PROMPT);
      expect(g.promptPlatform()).assertEqual('taobao');
      expect(g.confirm()).assertTrue();
      await flush();
      expect(g.parseCount()).assertEqual(1);
    });

    it('r2_03_cold_start_real_account_switch_withdraw_or_env_switch_still_drops', 0, async () => {
      // 冷启动期间真实换号（登录序号 / 会话世代推进）：立即作废，就绪后也不出提示
      const f: Fixture = new Fixture(true);
      const a: Promise<string> = f.receive();
      f.share.text(0, TB_LINK);
      await a;
      f.controller.onForeground();
      f.rig.client.onSessionChanged();
      f.controller.sync();
      expect(f.controller.lastShareAction).assertEqual(ShareImportAction.DROP);
      f.settle();
      expect(f.prompt() === null).assertTrue();
      // 没有中间的状态同步、换号后直接就绪：按到达时固定的世代比较，同样丢弃
      const g: Fixture = new Fixture(true);
      const b: Promise<string> = g.receive();
      g.share.text(0, TB_LINK);
      await b;
      g.rig.client.onSessionChanged();
      g.ready = true;
      g.rig.context.settled = true;
      g.controller.onForeground();
      expect(g.prompt() === null).assertTrue();
      // 内容还在途时换号：返回即丢弃
      const h: Fixture = new Fixture(true);
      const c: Promise<string> = h.receive();
      h.controller.onForeground();
      h.rig.client.onSessionChanged();
      h.settle();
      h.share.text(0, TB_LINK);
      expect(await c).assertEqual(ShareImportAction.DROP);
      // 撤回同意、切换环境
      const k: Fixture = new Fixture(true);
      const d: Promise<string> = k.receive();
      k.share.text(0, TB_LINK);
      await d;
      k.controller.onForeground();
      k.consent = ClipboardReadPolicy.CONSENT_BASIC;
      k.controller.sync();
      k.consent = ClipboardReadPolicy.CONSENT_AGREED;
      k.settle();
      expect(k.prompt() === null).assertTrue();
      const m: Fixture = new Fixture(true);
      const e: Promise<string> = m.receive();
      m.share.text(0, TB_LINK);
      await e;
      m.controller.onForeground();
      m.controller.environmentSwitched();
      m.settle();
      expect(m.prompt() === null).assertTrue();
      await flush();
      for (const x of [f, g, h, k, m]) {
        expect(x.parseCount()).assertEqual(0);
      }
    });

    it('r2_03_after_boot_scope_drift_still_invalidates_prompt', 0, async () => {
      // 就绪之后不再容忍归属漂移：已出的分享提示条随端点变化同步作废（不是忽略全部归属变化）
      const f: Fixture = new Fixture(true);
      const a: Promise<string> = f.receive();
      f.share.text(0, TB_LINK);
      await a;
      f.controller.onForeground();
      f.settle();
      expect(f.promptPlatform()).assertEqual('taobao');
      f.rig.context.settled = false;
      f.controller.sync();
      expect(f.prompt() === null).assertTrue();
      // 热启动（已就绪）时也是：到达后端点变了就丢弃
      const g: Fixture = new Fixture();
      const b: Promise<string> = g.receive();
      g.rig.context.settled = false;
      g.share.text(0, TB_LINK);
      expect(await b).assertEqual(ShareImportAction.DROP);
    });
  });
}
