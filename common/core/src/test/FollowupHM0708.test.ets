// FU-HM-0708：鸿蒙回查 APP-07 共性第 27–31 条（F-HM-16、F-APP07-02 鸿蒙部分）的回归测试（实现方自写）。
// 强更补查用真实 UpdateGate + UpdateCheckCoordinator（检查器为手动应答的替身）；剪贴板用真实 ApiClient + 本地假服务（NetworkTestRig，
// 不连任何地址）与执行层 ClipboardController。样例全部是演示数据；测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, ClipboardController, ClipboardDeps, ClipboardReadPolicy, ClipboardResultBinding, ClipboardResultView,
  ClipboardSensitive, ClipboardSnapshot, InvitePasteOutcome, ManualPasteAction, MemoryClipboardHashStore, MemoryUpdateStore,
  ParseRow, PasteboardPort, PasteOutcome, PrivacyState, TransportRequest, TransportResponse, UpdateCheckCoordinator,
  UpdateCheckOutcome, UpdateChecker, UpdateCheckResult, UpdateGate, UpdateStatusRaw, UpdateStoreListing
} from '../../Index';
import { Deferred, envelope, flush, Rig } from './NetworkTestRig';

// ---------------------------------------------------------------- 强更补查（共性第 27 条，F-HM-16）

/** 手动应答的检查器：check() 挂起，测试调 respond 才返回。 */
class HeldChecker implements UpdateChecker {
  calls: number = 0;
  private resolvers: ((o: UpdateCheckOutcome) => void)[] = [];

  check(): Promise<UpdateCheckOutcome> {
    this.calls++;
    return new Promise<UpdateCheckOutcome>((resolve: (o: UpdateCheckOutcome) => void) => {
      this.resolvers.push(resolve);
    });
  }

  async respond(outcome: UpdateCheckOutcome): Promise<void> {
    const resolve: ((o: UpdateCheckOutcome) => void) | undefined = this.resolvers.shift();
    if (resolve !== undefined) {
      resolve(outcome);
    }
    await flush();
  }
}

function forceResult(): UpdateCheckResult {
  return new UpdateCheckResult('1.1.0', '1.1.0', '1.3.0', 'huawei', [new UpdateStoreListing('huawei', '1.3.0')], 1800);
}

/** 与 entry AppUpdate 同一接线：Gate + 协调器，环境已 SETTLED；隐私可改。 */
class UpdateRig {
  now: number = 10000000;
  privacy: PrivacyState = PrivacyState.CONSENTED;
  readonly checker: HeldChecker = new HeldChecker();
  readonly store: MemoryUpdateStore = new MemoryUpdateStore();
  readonly gate: UpdateGate;
  readonly coord: UpdateCheckCoordinator;

  constructor() {
    this.gate = new UpdateGate(this.store, (): number => this.now, '1.0.0', 'harmony', 'agc', null);
    this.coord = new UpdateCheckCoordinator(this.gate, this.checker, (): number => this.now);
    this.coord.environmentSettled = (): boolean => true;
    this.coord.privacy = (): PrivacyState => this.privacy;
  }

  /** 冷启动检查失败：本机没有任何成功检查结果（商店列表为空）。 */
  async coldStartFailed(): Promise<void> {
    expect(this.coord.syncPrivacy(false)).assertTrue();
    expect(this.checker.calls).assertEqual(1);
    await this.checker.respond(UpdateCheckOutcome.failure());
    expect(this.gate.lastResult() === null).assertTrue();
    expect(this.coord.isRunning).assertFalse();
  }
}

// ---------------------------------------------------------------- 剪贴板（共性第 28–31 条，F-APP07-02 鸿蒙部分）

const PRODUCT_LINK: string = 'https://e.tb.cn/h.Demo01?tk=Sample';
const PRODUCT_TEXT: string = '分享好物 ' + PRODUCT_LINK + ' 「全脂纯牛奶 250ml」 其他说明文字不上传';
const INVITE_TEXT: string = '我在用凑狸，邀请码 K7M3QX';

function clipCard(key: string): string {
  return '{"product_key":"' + key + '","item_ref":"ref-' + key + '","platform":"taobao","title":"降噪蓝牙耳机",'
    + '"image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
    + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"link-' + key + '","cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00",'
    + '"stale":false,"age_sec":12,"source":"taobao_union","disclaimer_keys":["price_basis"],"availability":"ok"}';
}

function oneCard(): string {
  return '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"' + PRODUCT_LINK + '"},"card":' + clipCard('tb:1')
    + '}]}';
}

/** 假系统剪贴板：可数读写次数；hold 时读取挂起（模拟 pasteboard 异步交付），由测试放行。 */
class HeldPasteboard implements PasteboardPort {
  text: string | null = null;
  reads: number = 0;
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

/** 剪贴板执行层 + 真实 ApiClient（本地假服务）；导航栈按名字同步（与 entry 的 onStackChanged 同一入口）。 */
class ClipRig {
  readonly rig: Rig;
  readonly pasteboard: HeldPasteboard = new HeldPasteboard();
  readonly controller: ClipboardController;
  consent: string = ClipboardReadPolicy.CONSENT_AGREED;
  overlay: string = ClipboardSensitive.OVERLAY_NONE;
  nowMs: number = 1800000000000;
  /** parse 的回答；null 时挂起到 held。 */
  reply: TransportResponse | null = envelope(0, oneCard());
  held: Deferred[] = [];
  opened: string[] = [];
  /** 执行层送进强更入口（行内 10405）的次数。 */
  forced: number = 0;
  stack: string[] = [];

  constructor(loggedIn: boolean = false) {
    this.rig = loggedIn ? new Rig() : new Rig(null);
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
    const deps: ClipboardDeps = new ClipboardDeps(this.pasteboard, new ApiClientSearchPort(this.rig.client));
    deps.consent = (): string => this.consent;
    deps.overlay = (): string => this.overlay;
    deps.scope = (): string => ClipboardController.scopeKey(this.rig.client.captureScope());
    deps.guest = (): boolean => !loggedIn;
    deps.config = (): Record<string, Object> => {
      const c: Record<string, Object> = {};
      c['share_domains'] = ['share.example.test'];
      return c;
    };
    deps.open = (route: string, _params: Record<string, Object>): boolean => {
      this.opened.push(route);
      return true;
    };
    deps.clock = (): number => this.nowMs;
    deps.store = new MemoryClipboardHashStore();
    deps.forceUpdate = (_m: string | null): void => {
      this.forced++;
    };
    this.controller = new ClipboardController(deps);
    this.controller.onChange = (_s: ClipboardSnapshot): void => {
    };
    this.controller.sync();
    this.controller.onForeground();
  }

  push(route: string): void {
    this.stack.push(route);
    this.controller.stackChanged(this.stack.slice());
  }

  /** 系统返回：页面出口 pageLeft，再出栈并同步栈。 */
  back(): void {
    this.controller.pageLeft();
    this.stack.pop();
    this.controller.stackChanged(this.stack.slice());
  }

  parseCount(): number {
    return this.rig.server.count('/v1/inputs/parse');
  }

  result(): ClipboardResultView | null {
    return this.controller.snapshot.result;
  }

  /** 点击之后、交付之前发生的各种失效（页面、Tab、前台、隐私、会话、环境、敏感浮层）。 */
  exit(kind: string): void {
    if (kind === 'page') {
      this.push('WebPage');
      this.back();
    } else if (kind === 'tab') {
      this.controller.tabChanged('Me', false);
      this.controller.tabChanged('Home', false);
    } else if (kind === 'background') {
      this.controller.onBackground();
      this.controller.onForeground();
    } else if (kind === 'privacy') {
      this.consent = ClipboardReadPolicy.CONSENT_OUTDATED;
      this.rig.client.invalidate();
      this.controller.sync();
      this.consent = ClipboardReadPolicy.CONSENT_AGREED;
      this.controller.sync();
    } else if (kind === 'session') {
      this.rig.client.onSessionChanged();
      this.controller.sync();
    } else if (kind === 'environment') {
      this.controller.environmentSwitched();
    } else if (kind === 'overlay') {
      this.overlay = ClipboardSensitive.OVERLAY_AUTH_JUMP;
      this.controller.overlayShown();
      this.overlay = ClipboardSensitive.OVERLAY_NONE;
    }
  }
}

const EXITS: string[] = ['page', 'tab', 'background', 'privacy', 'session', 'environment', 'overlay'];

export default function followupHM0708Test() {
  describe('FollowupHM0708', () => {
    // ---------------------------------------------------------------- 第 27 条：任何路径进强更都补查（F-HM-16）

    it('fu0708_l27_every_forced_path_without_result_rechecks_immediately', 0, async () => {
      // 网络层整体 10405 带最低版本 / 不带最低版本（含登录受限会话的 markBelow）/ 服务端已判定（parse 行内、订单待跟单关闭的 10405）
      for (const path of ['10405_min', '10405_null', 'server_forced']) {
        const r: UpdateRig = new UpdateRig();
        await r.coldStartFailed();
        if (path === '10405_min') {
          r.coord.on10405('1.1.0');
        } else if (path === '10405_null') {
          r.coord.on10405(null);
        } else {
          r.coord.onServerForced();
        }
        expect(r.gate.state(r.now).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
        // 不等用户点【重试】：立即补查一次
        expect(r.checker.calls).assertEqual(2);
        expect(r.coord.isRunning).assertTrue();
        // 补查期间仍是强更（已知 below_min 不因「检查中」放行）
        expect(r.gate.state(r.now).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
        await r.checker.respond(UpdateCheckOutcome.success(forceResult()));
        // 拿到商店列表：强更页可以选店
        expect(r.gate.lastResult() !== null).assertTrue();
        expect(r.gate.state(r.now).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
      }
    });

    it('fu0708_l27_recheck_reuses_in_flight_and_skips_when_result_known_or_basic_mode', 0, async () => {
      // 冷启动检查还在途时进强更：复用它，不另发
      const a: UpdateRig = new UpdateRig();
      a.coord.syncPrivacy(false);
      expect(a.checker.calls).assertEqual(1);
      a.coord.on10405(null);
      a.coord.onServerForced();
      expect(a.checker.calls).assertEqual(1);
      // 补查在途时再进强更：同样复用
      const b: UpdateRig = new UpdateRig();
      await b.coldStartFailed();
      b.coord.on10405(null);
      b.coord.onServerForced();
      b.coord.on10405('1.2.0');
      expect(b.checker.calls).assertEqual(2);
      // 已有最近一次成功检查结果：不补查
      await b.checker.respond(UpdateCheckOutcome.success(forceResult()));
      b.coord.onServerForced();
      expect(b.checker.calls).assertEqual(2);
      // 基本模式不发检查（已知强更照旧）
      const c: UpdateRig = new UpdateRig();
      await c.coldStartFailed();
      c.privacy = PrivacyState.BASIC_MODE;
      c.coord.syncPrivacy(false);
      c.coord.on10405(null);
      expect(c.gate.state(c.now).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
      expect(c.checker.calls).assertEqual(1);
      // 带回的最低版本不高于本机（Gate 不进强更）：不补查
      const d: UpdateRig = new UpdateRig();
      await d.coldStartFailed();
      d.coord.on10405('1.0.0');
      expect(d.checker.calls).assertEqual(1);
    });

    // ---------------------------------------------------------------- 第 28 条：异步交付按点击时的归属复核

    it('fu0708_l28_late_product_read_dropped_for_every_exit', 0, async () => {
      for (const exit of EXITS) {
        const f: ClipRig = new ClipRig(exit === 'session');
        f.pasteboard.text = PRODUCT_TEXT;
        f.pasteboard.hold = true;
        const pending: Promise<string> = f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
        expect(f.controller.snapshot.busy).assertTrue();
        f.exit(exit);
        f.pasteboard.release();
        // 交付时按点击时捕获的票据复核：失效即丢弃，不按交付时的当前页重新归属
        expect(await pending).assertEqual(PasteOutcome.DROPPED);
        await flush();
        expect(f.parseCount()).assertEqual(0);
        expect(f.result() === null && f.controller.snapshot.prompt === null).assertTrue();
        expect(f.opened.length).assertEqual(0);
        expect(f.controller.snapshot.busy).assertFalse();
      }
    });

    it('fu0708_l28_login_invite_late_delivery_dropped_even_back_on_same_instance', 0, async () => {
      for (const exit of ['page', 'background', 'privacy', 'environment', 'overlay']) {
        const f: ClipRig = new ClipRig();
        f.push('Login');
        f.pasteboard.text = INVITE_TEXT;
        f.pasteboard.hold = true;
        const pending: Promise<InvitePasteOutcome> = f.controller.pasteInvite(true);
        // 离开登录页再回到同一个登录页实例（或经过后台、隐私 / 环境变化、敏感浮层）
        f.exit(exit);
        f.pasteboard.release();
        expect((await pending).actionRaw).assertEqual(InvitePasteOutcome.DROPPED);
        // 回来后用户再点一次：以新点击为准
        f.pasteboard.hold = false;
        const again: InvitePasteOutcome = await f.controller.pasteInvite(true);
        expect(again.actionRaw === InvitePasteOutcome.FILL && again.code === 'K7M3QX').assertTrue();
        expect(f.rig.server.received.length).assertEqual(0);
      }
    });

    // ---------------------------------------------------------------- 第 29 条：整体 10405 的强更副作用受归属约束

    it('fu0708_l29_late_whole_10405_parse_does_not_force_update', 0, async () => {
      for (const exit of EXITS) {
        const f: ClipRig = new ClipRig(exit === 'session');
        f.reply = null;
        f.pasteboard.text = PRODUCT_TEXT;
        await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
        await flush();
        expect(f.held.length).assertEqual(1);
        f.exit(exit);
        f.held[0].resolve(envelope(10405, '{"min_supported_version":"9.0.0"}'));
        await flush();
        // 迟到 / 已失效的整体 10405：网络层不进强更（不调 UpdatePort.on10405，Gate 不落盘），执行层也不送
        expect(f.rig.update.calls.length).assertEqual(0);
        expect(f.forced).assertEqual(0);
        expect(f.result() === null).assertTrue();
      }
      // 对照：归属仍有效时整体 10405 照常进强更（网络层 → UpdatePort.on10405，带回最低版本）
      const g: ClipRig = new ClipRig();
      g.reply = envelope(10405, '{"min_supported_version":"9.0.0"}');
      g.pasteboard.text = PRODUCT_TEXT;
      await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect(g.rig.update.calls.length).assertEqual(1);
      expect(g.rig.update.calls[0]).assertEqual('9.0.0');
    });

    // ---------------------------------------------------------------- 第 30 条：整体 30132 用请求前抽出的标题

    it('fu0708_l30_whole_30132_prefills_locally_extracted_title', 0, async () => {
      // 标题以 http 开头：旧实现从上传片段里取「第一行不是 http 开头」的行，会把它当链接丢掉、预填为空
      const f: ClipRig = new ClipRig();
      f.reply = envelope(30132, 'null');
      f.pasteboard.text = '看看这个 ' + PRODUCT_LINK + ' 「HTTP转接头 USB3.0」';
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
      await flush();
      const r: ClipboardResultView | null = f.result();
      expect(r !== null && r.kind === ClipboardResultView.UNRECOGNIZED && r.textKey === 'error.30132').assertTrue();
      expect((r as ClipboardResultView).prefill).assertEqual('HTTP转接头 USB3.0');
      // 不依赖契约外的 data.raw
      const g: ClipRig = new ClipRig();
      g.reply = envelope(30132, '{"raw":"服务端回显的别的内容"}');
      g.pasteboard.text = PRODUCT_TEXT;
      await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect((g.result() as ClipboardResultView).prefill).assertEqual('全脂纯牛奶 250ml');
      // 没有「」标题：留空（不拿原文首行，也不拿链接）
      const h: ClipRig = new ClipRig();
      h.reply = envelope(30132, 'null');
      h.pasteboard.text = '分享好物 ' + PRODUCT_LINK;
      await h.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const u: ClipboardResultView | null = h.result();
      expect(u !== null && u.kind === ClipboardResultView.UNRECOGNIZED && u.prefill === null).assertTrue();
      h.controller.searchByName(u as ClipboardResultView);
      expect(h.opened.join(',')).assertEqual('Search');
    });

    // ---------------------------------------------------------------- 第 31 条：多卡结果的按钮走共享限流，粘贴入口共享在途

    it('fu0708_l31_card_buy_and_search_rows_respect_shared_block_via_binding', 0, async () => {
      const f: ClipRig = new ClipRig();
      f.reply = envelope(0, '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"x"},"card":' + clipCard('tb:1')
        + '},{"hit":{"platform":"taobao","kind":"text","raw":"「保温杯 500ml」"},"error_code":30132},'
        + '{"hit":{"platform":"jd","kind":"url","raw":"y"},"error_code":42901}]}');
      f.pasteboard.text = PRODUCT_TEXT;
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const r: ClipboardResultView | null = f.result();
      expect(r !== null && r.kind === ClipboardResultView.CARD_LIST).assertTrue();
      // 界面置灰的依据（快照 blocked）与执行层同步
      expect(f.controller.snapshot.blocked && f.controller.blocked).assertTrue();
      // 弹层经渲染时绑定转发：点卡与购买按钮都走 openRow，【用商品名搜索】走 searchRow——禁用期内都不执行
      const binding: ClipboardResultBinding = new ClipboardResultBinding(f.controller, r as ClipboardResultView);
      const cardRow: ParseRow = (r as ClipboardResultView).rows[0];
      const searchRow: ParseRow = (r as ClipboardResultView).rows[1];
      expect(binding.openRow(cardRow)).assertFalse();
      binding.searchRow(searchRow);
      expect(f.opened.length).assertEqual(0);
      expect(f.result() === r).assertTrue();
      // 到期恢复：快照解除、按钮可用
      f.nowMs += 5000;
      f.controller.refreshBlocked();
      expect(f.controller.snapshot.blocked).assertFalse();
      expect(binding.openRow(cardRow)).assertTrue();
      expect(f.opened.join(',')).assertEqual('ProductDetail');
    });

    it('fu0708_l31_product_paste_entries_share_busy_while_parse_in_flight', 0, async () => {
      const f: ClipRig = new ClipRig();
      f.reply = null;
      f.pasteboard.text = PRODUCT_TEXT;
      await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect(f.held.length).assertEqual(1);
      expect(f.controller.snapshot.busy).assertTrue();
      // parse 在途：任何商品粘贴入口（首页、SearchTyping）都不再读、不再发
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.BUSY);
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true)).assertEqual(PasteOutcome.BUSY);
      expect(f.pasteboard.reads).assertEqual(1);
      expect(f.parseCount()).assertEqual(1);
      f.held[0].resolve(envelope(0, oneCard()));
      await flush();
      expect(f.controller.snapshot.busy).assertFalse();
      expect(f.opened.join(',')).assertEqual('ProductDetail');
    });
  });
}
