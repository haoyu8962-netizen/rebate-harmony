// HM-07v-b（APP-11v-b 鸿蒙端：首页弹窗与剪贴板浮层）Core 本机单测。测试作者先写、先红；实现方不改本文件（有问题走「需要编排裁定」）。
// 依据：NATIVE/APP-11v/brief.md §2.2 popup 行、§2.3、§2.4、§5；brief-harmony.md H6 / H7 / H16 / H19 / H20；gaps G-V07；
// notices 2026-10-22 08:24（Android b 段：关闭层独立于图片比例 / 裁剪）、2026-10-24 18:39 / 21:15（iOS 主线三端口径：①⑤ 不设【关闭】、
// ⑤【重试】只重发本次已提取片段且只对 timeout / disconnect / no_envelope 出、新一次手动粘贴即清旧 ①⑤ 结果卡，轻提示 / 邀请条不动）。
// 接口最小签名见 tests-b-harmony-handback.md §3（HomePopupGeometry、ClipboardRetryPolicy、ClipboardResultView.NETWORK_FAILED /
// closable、ClipboardController.retryResult、ClipboardResultBinding.retry）。剪贴板部分用真实 ApiClient + 本机假服务（不连任何地址）、
// 真实 Router / StackNavigator、执行层 ClipboardController；样例全部是演示数据。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, ApiOutcome, ClipboardController, ClipboardDeps, ClipboardPromptView, ClipboardReadPolicy,
  ClipboardResultBinding, ClipboardResultView, ClipboardRetryPolicy, ClipboardSensitive, ClipboardSnapshot, GuardState,
  HomeDraftTexts, HomePopupGeometry, LaunchReadiness, ManualPasteAction, MemoryClipboardHashStore, MemoryPendingBackend,
  PasteboardPort, PasteOutcome, PendingActionStore, PrivacyState, RouteDestination, RouteRequest, RouteSource, Router,
  RouteTable, StackNavigator, TransportFailure, TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState
} from '../../Index';
import { RouteSpec } from 'generated';
import { MemoryPathStack } from './App05bFixture';
import { envelope, flush, Rig } from './NetworkTestRig';

const PRODUCT_LINK: string = 'https://e.tb.cn/h.Demo01?tk=Sample';
const PRODUCT_TEXT: string = '分享好物 ' + PRODUCT_LINK + ' 「全脂纯牛奶 250ml」 其他说明文字不上传';
const UPLOAD_TEXT: string = PRODUCT_LINK + '\n全脂纯牛奶 250ml';
const OTHER_LINK: string = 'https://u.jd.com/demo';
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

function twoCards(): string {
  return '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"' + PRODUCT_LINK + '"},"card":' + card('tb:1') + '},'
    + '{"hit":{"platform":"taobao","kind":"url","raw":"' + PRODUCT_LINK + '"},"card":' + card('tb:2') + '}]}';
}

/** 假系统剪贴板：可数读次数；hold 时读取挂起，由测试放行（用来观察「开始粘贴、读取未完成」那一刻的界面状态）。 */
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

/** parse 的回答：固定一份传输响应（成功外壳、业务错误外壳、无外壳 HTML、或传输失败）。 */
class OverlayClipFixture {
  readonly rig: Rig = new Rig(null);
  readonly pasteboard: FakePasteboard = new FakePasteboard();
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly controller: ClipboardController;
  consent: string = ClipboardReadPolicy.CONSENT_AGREED;
  overlay: string = ClipboardSensitive.OVERLAY_NONE;
  nowMs: number = 1800000000000;
  reply: TransportResponse = envelope(0, twoCards());

  constructor() {
    this.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      if (r.url.indexOf('/v1/inputs/parse') >= 0) {
        return Promise.resolve(this.reply);
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
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => this.nowMs),
      (): GuardState => new GuardState('consented', 'ok', 'guest', true, '1.0.0', false),
      this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
    const deps: ClipboardDeps = new ClipboardDeps(this.pasteboard, new ApiClientSearchPort(this.rig.client));
    deps.consent = (): string => this.consent;
    deps.overlay = (): string => this.overlay;
    deps.scope = (): string => ClipboardController.scopeKey(this.rig.client.captureScope());
    deps.guest = (): boolean => true;
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
    deps.store = new MemoryClipboardHashStore();
    deps.forceUpdate = (_minSupported: string | null): void => {
    };
    this.controller = new ClipboardController(deps);
    this.controller.onChange = (_s: ClipboardSnapshot): void => {
    };
    this.navigator.onStackChanged = (names: string[]): void => this.controller.stackChanged(names);
    this.controller.sync();
    this.controller.onForeground();
  }

  parseCount(): number {
    return this.rig.server.count('/v1/inputs/parse');
  }

  lastUpload(): string {
    const body: Record<string, Object> =
      JSON.parse(this.rig.server.last('/v1/inputs/parse').body ?? '{}') as Record<string, Object>;
    return typeof body['text'] === 'string' ? body['text'] as string : '';
  }

  result(): ClipboardResultView | null {
    return this.controller.snapshot.result;
  }

  kind(): string {
    const r: ClipboardResultView | null = this.result();
    return r === null ? 'none' : r.kind;
  }

  top(): string {
    const names: string[] = this.stack.getAllPathName();
    return names.length === 0 ? '' : names[names.length - 1];
  }

  /** 首页 PasteButton（SUCCESS）粘贴一次 text，并等 parse 结束。 */
  async paste(text: string | null): Promise<string> {
    this.pasteboard.text = text;
    const outcome: string = await this.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
    await flush();
    await flush();
    return outcome;
  }
}

function check(ok: boolean, what: string, detail: string = ''): void {
  expect(ok ? what : what + ' ' + detail).assertEqual(what);
}

/** 无外壳（网关 HTML 错误页）：网络层判 no_envelope。 */
function noEnvelope(): TransportResponse {
  return TransportResponse.ok(502, {}, '<html><body>bad gateway</body></html>');
}

function near(actual: number, expected: number, tol: number, what: string): void {
  check(Math.abs(actual - expected) <= tol, what, 'actual=' + actual + ' expected=' + expected);
}

/** 几何自洽：图片在外框内、关闭命中区 48×48 整个在外框内、贴图片右上（内缩 ≤ 8），外框至少 48×48。 */
function frameInvariants(g: HomePopupGeometry, what: string, anchored: boolean = true): void {
  const all: number[] = [g.imageWidth, g.imageHeight, g.frameWidth, g.frameHeight, g.imageX, g.imageY, g.closeX, g.closeY];
  check(all.every((v: number): boolean => Number.isFinite(v) && v >= 0), what + ' 几何值都是有限非负数', all.join(','));
  check(g.frameWidth >= HomePopupGeometry.CLOSE_HIT && g.frameHeight >= HomePopupGeometry.CLOSE_HIT,
    what + ' 外框至少容下关闭命中区 48×48（关闭层独立于图片比例）', g.frameWidth + 'x' + g.frameHeight);
  check(g.imageX + g.imageWidth <= g.frameWidth + 0.01 && g.imageY + g.imageHeight <= g.frameHeight + 0.01,
    what + ' 图片在外框内', [g.imageX, g.imageY, g.imageWidth, g.imageHeight, g.frameWidth, g.frameHeight].join(','));
  check(g.closeX + HomePopupGeometry.CLOSE_HIT <= g.frameWidth + 0.01 && g.closeY + HomePopupGeometry.CLOSE_HIT <= g.frameHeight + 0.01,
    what + ' 关闭命中区整个在外框内（不被图片裁剪层裁掉）', [g.closeX, g.closeY, g.frameWidth, g.frameHeight].join(','));
  if (!anchored) {
    return;
  }
  const right: number = g.imageX + g.imageWidth;
  check(Math.abs(g.closeX + HomePopupGeometry.CLOSE_HIT - right) <= 8 && Math.abs(g.closeY - g.imageY) <= 8,
    what + ' 关闭压在图片右上角（命中区右缘 / 顶边距图片右上 ≤ 8）', [g.closeX, g.closeY, right, g.imageY].join(','));
}

export default function hm07vOverlayTest() {
  describe('Hm07vOverlay', () => {
    // ================================================================ A15 弹窗（G-V07、H16）

    it('hm07vb_popup_reader_name_is_home_popup_default_and_close_label', 0, () => {
      // 契约 alt 未进锁（CT-07b）→ 默认读屏名「首页弹窗」（规格 §6、G-V07；三端同字）。旧草稿「活动弹窗」不得再出现。
      expect(HomeDraftTexts.text('home.popup.label')).assertEqual('首页弹窗');
      expect(HomeDraftTexts.text('home.popup.close')).assertEqual('关闭');
      check(HomeDraftTexts.keys().every((k: string): boolean => HomeDraftTexts.text(k) !== '活动弹窗'), '草稿表里不再有「活动弹窗」');
    });

    it('hm07vb_popup_geometry_side_margin_32_and_aspect_for_board_windows', 0, () => {
      expect(HomePopupGeometry.SIDE_MARGIN).assertEqual(32);
      expect(HomePopupGeometry.CLOSE_HIT).assertEqual(48);
      expect(HomePopupGeometry.CLOSE_VISUAL).assertEqual(40);
      // 画板 MainPopupStatic：390 宽、图片 326 宽（左右各 32）、4:5。手机宽 320 / 376 / 390 都按「窗口宽 − 64」。
      const widths: number[] = [320, 360, 376, 390, 412];
      for (const w of widths) {
        const g: HomePopupGeometry = HomePopupGeometry.of(w, 844, 652, 816);
        near(g.imageWidth, w - 64, 0.5, 'w' + w + ' 图片宽 = 窗口宽 − 64');
        near(g.imageHeight, (w - 64) * 816 / 652, 0.5, 'w' + w + ' 图片按宽高比定高');
        near(g.imageX + g.imageWidth / 2, g.frameWidth / 2, 0.5, 'w' + w + ' 图片在外框内水平居中');
        frameInvariants(g, 'w' + w);
      }
      // 大屏 / 平板：不随窗口无限放大（上限 400–600 之间由实现定，≤ 内容列 600），仍左右各留 ≥ 32。
      for (const w of [600, 840, 1200]) {
        const g: HomePopupGeometry = HomePopupGeometry.of(w, 1000, 652, 816);
        check(g.imageWidth >= Math.min(400, w - 64) - 0.5 && g.imageWidth <= Math.min(600, w - 64) + 0.5,
          'w' + w + ' 图片宽封顶在 400–600 之间', String(g.imageWidth));
        near(g.imageWidth * 816 / 652, g.imageHeight, 0.5, 'w' + w + ' 封顶后仍按比例');
        frameInvariants(g, 'w' + w);
      }
    });

    it('hm07vb_popup_geometry_close_layer_independent_of_extreme_ratio_and_short_window', 0, () => {
      // Android b r1 S1 反例：320 宽、合法 1000×100 横图 → 图片高 25.6，关闭命中区仍须 48×48、完整、不被裁。
      const wide: HomePopupGeometry = HomePopupGeometry.of(320, 640, 1000, 100);
      near(wide.imageWidth, 256, 0.5, '横图宽 = 320 − 64');
      near(wide.imageHeight, 25.6, 0.5, '横图按比例 25.6 高（不为关闭拉高图片）');
      frameInvariants(wide, '横图 1000×100');
      // 细长竖图：高受窗口限制、宽随之收到 < 48；关闭仍完整。
      const tall: HomePopupGeometry = HomePopupGeometry.of(376, 800, 100, 2000);
      check(tall.imageHeight <= 800 - 2 * HomePopupGeometry.VERTICAL_MARGIN + 0.5, '细长图高不超过窗口高 − 上下各 24',
        String(tall.imageHeight));
      near(tall.imageWidth / tall.imageHeight, 100 / 2000, 0.001, '细长图收高后宽随之收、比例不变');
      frameInvariants(tall, '细长图 100×2000');
      // 短视口（320×400，200% 截图档）：4:5 图按（可用高）收，宽随之收；关闭完整。
      const short: HomePopupGeometry = HomePopupGeometry.of(320, 400, 652, 816);
      check(short.imageHeight <= 400 - 2 * HomePopupGeometry.VERTICAL_MARGIN + 0.5, '短视口图高按可用高收',
        String(short.imageHeight));
      check(short.imageWidth <= 256 + 0.5, '短视口图宽不超过窗口宽 − 64', String(short.imageWidth));
      near(short.imageWidth / short.imageHeight, 652 / 816, 0.002, '短视口收高后比例不变');
      check(short.frameHeight <= 400 && short.frameWidth <= 320, '短视口外框在窗口内',
        short.frameWidth + 'x' + short.frameHeight);
      frameInvariants(short, '短视口 320×400');
    });

    it('hm07vb_popup_geometry_unknown_image_size_falls_back_to_four_by_five', 0, () => {
      // 图片尺寸未知 / 非法（解码前、坏数据）：按画板 4:5 占位，不出现 0 高或 NaN 外框（关闭照样可点）。
      const bad: number[][] = [[0, 0], [-1, 100], [100, 0], [NaN, 100], [100, NaN], [Infinity, 100], [100, Infinity]];
      for (const s of bad) {
        const g: HomePopupGeometry = HomePopupGeometry.of(376, 800, s[0], s[1]);
        near(g.imageWidth, 312, 0.5, '尺寸 ' + s.join('x') + ' 图片宽 312');
        near(g.imageHeight, 312 * HomePopupGeometry.FALLBACK_RATIO, 0.5, '尺寸 ' + s.join('x') + ' 按 4:5 定高');
        frameInvariants(g, '尺寸 ' + s.join('x'));
      }
      expect(HomePopupGeometry.FALLBACK_RATIO).assertEqual(1.25);
      // 窗口尺寸非法时也不得出 NaN（外框至少 48，关闭可达）。
      for (const s of [[0, 0], [NaN, NaN], [-10, 500]]) {
        // 窗口无效时图片框可以是 0 宽，不要求「贴图片右上」，只要求不出 NaN、外框容得下关闭。
        frameInvariants(HomePopupGeometry.of(s[0], s[1], 652, 816), '窗口 ' + s.join('x'), false);
      }
    });

    // ================================================================ A18 ⑤【重试】出现条件（三端口径 2026-10-24 21:15）

    it('hm07vb_retry_policy_only_timeout_disconnect_no_envelope', 0, () => {
      const yes: string[] = [TransportFailure.TIMEOUT, TransportFailure.DISCONNECT, 'no_envelope'];
      for (const f of yes) {
        check(ClipboardRetryPolicy.retryable(ApiOutcome.NETWORK_ERROR, f), '网络失败 ' + f + ' 出【重试】');
      }
      // cancelled、刷新无结论、清会话失败、流协议错误、没有失败原因：不出（会话暂不可读等）。
      const no: string[] = [TransportFailure.CANCELLED, TransportFailure.NONE, 'refresh_unavailable', 'session_cleanup_failed',
        'stream_protocol', '', 'TIMEOUT', 'timeout '];
      for (const f of no) {
        check(!ClipboardRetryPolicy.retryable(ApiOutcome.NETWORK_ERROR, f), '网络失败 [' + f + '] 不出【重试】');
      }
      // 不是网络失败：业务错误（含 5xxxx）、成功（含空结果）、本地拒绝、304 都不出，即使 failure 串碰巧是 timeout。
      for (const o of [ApiOutcome.BUSINESS_ERROR, ApiOutcome.SUCCESS, ApiOutcome.LOCAL_REJECT, ApiOutcome.NOT_MODIFIED, '']) {
        for (const f of yes) {
          check(!ClipboardRetryPolicy.retryable(o, f), o + '/' + f + ' 不出【重试】');
        }
      }
    });

    it('hm07vb_transport_failures_give_network_failed_result_without_close', 0, async () => {
      const cases: TransportResponse[] = [TransportResponse.failed(TransportFailure.TIMEOUT),
        TransportResponse.failed(TransportFailure.DISCONNECT), noEnvelope()];
      const names: string[] = ['timeout', 'disconnect', 'no_envelope'];
      for (let i: number = 0; i < cases.length; i++) {
        const f: OverlayClipFixture = new OverlayClipFixture();
        f.reply = cases[i];
        expect(await f.paste(PRODUCT_TEXT)).assertEqual(ManualPasteAction.PARSE);
        check(f.kind() === ClipboardResultView.NETWORK_FAILED, names[i] + ' → ⑤ 网络失败结果卡', f.kind());
        const r: ClipboardResultView = f.result() as ClipboardResultView;
        expect(r.entry).assertEqual(ManualPasteAction.ENTRY_HOME);
        check(!ClipboardResultView.closable(r.kind), names[i] + ' ⑤ 不设【关闭】');
        check(f.top() === '', names[i] + ' 不跳页');
      }
    });

    it('hm07vb_non_transport_failures_never_show_retry', 0, async () => {
      // cancelled（传输层取消，网络层仍给 NETWORK_ERROR / cancelled）、5xxxx、30131、成功但结果为空（iOS b r1 S2-1）都不是 ⑤。
      const replies: TransportResponse[] = [TransportResponse.failed(TransportFailure.CANCELLED), envelope(50001, '{}'),
        envelope(30131, '{}'), envelope(0, '{"results":[]}'), envelope(0, '{"results":[{"hit":{"platform":"taobao"}}]}')];
      const names: string[] = ['cancelled', '50001', '30131', 'empty_results', 'all_filtered'];
      for (let i: number = 0; i < replies.length; i++) {
        const f: OverlayClipFixture = new OverlayClipFixture();
        f.reply = replies[i];
        await f.paste(PRODUCT_TEXT);
        check(f.kind() !== ClipboardResultView.NETWORK_FAILED, names[i] + ' 不出 ⑤【重试】', f.kind());
        const r: ClipboardResultView | null = f.result();
        if (r !== null) {
          const before: number = f.parseCount();
          check(!f.controller.retryResult(r), names[i] + ' 结果调 retryResult 被拒');
          await flush();
          expect(f.parseCount()).assertEqual(before);
        }
      }
    });

    it('hm07vb_unrecognized_is_card_without_close_and_light_notices_keep_close', 0, async () => {
      // ① 30132（服务端整体 30132 与本地非商品内容两条来源）：卡内版式，不设【关闭】；轻提示（30131 / 42901 / 5xxxx）保留关闭。
      const server: OverlayClipFixture = new OverlayClipFixture();
      server.reply = envelope(30132, '{}');
      await server.paste(PRODUCT_TEXT);
      check(server.kind() === ClipboardResultView.UNRECOGNIZED, '服务端 30132 → ①', server.kind());
      const local: OverlayClipFixture = new OverlayClipFixture();
      expect(await local.paste(ORDINARY_TEXT)).assertEqual(ManualPasteAction.SEARCH_PREFILL);
      check(local.kind() === ClipboardResultView.UNRECOGNIZED, '本地非商品内容 → ①', local.kind());
      check(!ClipboardResultView.closable(ClipboardResultView.UNRECOGNIZED), '① 不设【关闭】');
      check(!ClipboardResultView.closable(ClipboardResultView.NETWORK_FAILED), '⑤ 不设【关闭】');
      check(ClipboardResultView.closable(ClipboardResultView.NOTICE), '轻提示保留【关闭】');
      expect(ClipboardResultView.NETWORK_FAILED).assertEqual('network_failed');
      check([ClipboardResultView.NOTICE, ClipboardResultView.UNRECOGNIZED, ClipboardResultView.CARD_LIST]
        .indexOf(ClipboardResultView.NETWORK_FAILED) < 0, '⑤ 是独立的结果类别');
    });

    // ================================================================ ⑤【重试】只重发本次已提取片段

    it('hm07vb_retry_resends_same_extracted_upload_without_reading_clipboard', 0, async () => {
      const f: OverlayClipFixture = new OverlayClipFixture();
      f.reply = TransportResponse.failed(TransportFailure.TIMEOUT);
      await f.paste(PRODUCT_TEXT);
      const failed: ClipboardResultView = f.result() as ClipboardResultView;
      check(failed.kind === ClipboardResultView.NETWORK_FAILED, '先得 ⑤', failed.kind);
      const reads: number = f.pasteboard.reads;
      const sent: number = f.parseCount();
      expect(f.lastUpload()).assertEqual(UPLOAD_TEXT);
      // 剪贴板此后被别的 App 改写：重试仍发原片段，不读剪贴板（BR-ID-16「候选提取、上传与弹卡」）。
      f.pasteboard.text = '分享 ' + OTHER_LINK + ' 「别的商品」';
      f.reply = envelope(0, twoCards());
      const binding: ClipboardResultBinding = new ClipboardResultBinding(f.controller, failed);
      check(binding.retry(), '【重试】受理');
      // 受理即同步收起 ⑤ 并进在途（入口置灰，防连点）
      check(f.result() === null || f.result() !== failed, '重试受理后旧 ⑤ 卡同步收起');
      check(f.controller.snapshot.busy, '重试在途 busy');
      check(!binding.retry(), '在途时同一张旧卡再点被拒（不重复发）');
      await flush();
      await flush();
      expect(f.pasteboard.reads).assertEqual(reads);
      expect(f.parseCount()).assertEqual(sent + 1);
      expect(f.lastUpload()).assertEqual(UPLOAD_TEXT);
      check(f.kind() === ClipboardResultView.CARD_LIST, '重试成功后按新结果展示（多卡半屏）', f.kind());
      check(!f.controller.retryResult(failed), '旧 ⑤ 卡的迟到回调不再生效');
      await flush();
      expect(f.parseCount()).assertEqual(sent + 1);
      expect(f.pasteboard.writes).assertEqual(0);
    });

    it('hm07vb_retry_failing_again_shows_fresh_network_failed_and_can_retry_again', 0, async () => {
      const f: OverlayClipFixture = new OverlayClipFixture();
      f.reply = TransportResponse.failed(TransportFailure.DISCONNECT);
      await f.paste(PRODUCT_TEXT);
      const first: ClipboardResultView = f.result() as ClipboardResultView;
      check(f.controller.retryResult(first), '第一次重试受理');
      await flush();
      await flush();
      const second: ClipboardResultView | null = f.result();
      check(second !== null && second !== first && second.kind === ClipboardResultView.NETWORK_FAILED, '再次失败 → 新的 ⑤ 卡',
        second === null ? 'none' : second.kind);
      check(f.controller.retryResult(second as ClipboardResultView), '新 ⑤ 卡可再重试');
      await flush();
      await flush();
      expect(f.parseCount()).assertEqual(3);
      expect(f.lastUpload()).assertEqual(UPLOAD_TEXT);
      expect(f.pasteboard.reads).assertEqual(1);
    });

    it('hm07vb_retry_refused_when_not_current_or_blocked_by_overlay_or_privacy', 0, async () => {
      // 敏感浮层出现、撤回同意：不重发（与粘贴同一套归属前提）。
      const covered: OverlayClipFixture = new OverlayClipFixture();
      covered.reply = TransportResponse.failed(TransportFailure.TIMEOUT);
      await covered.paste(PRODUCT_TEXT);
      const a: ClipboardResultView = covered.result() as ClipboardResultView;
      covered.overlay = ClipboardSensitive.OVERLAY_AUTH_SHEET;
      check(!covered.controller.retryResult(a), '敏感浮层在前台时【重试】被拒');
      await flush();
      expect(covered.parseCount()).assertEqual(1);
      const revoked: OverlayClipFixture = new OverlayClipFixture();
      revoked.reply = TransportResponse.failed(TransportFailure.TIMEOUT);
      await revoked.paste(PRODUCT_TEXT);
      const b: ClipboardResultView = revoked.result() as ClipboardResultView;
      revoked.consent = ClipboardReadPolicy.CONSENT_BASIC;
      revoked.controller.sync();
      check(!revoked.controller.retryResult(b), '撤回同意后【重试】被拒');
      await flush();
      expect(revoked.parseCount()).assertEqual(1);
      // 换了一张新结果（新粘贴得 ①）后，旧 ⑤ 的【重试】不生效、不清新结果。
      const replaced: OverlayClipFixture = new OverlayClipFixture();
      replaced.reply = TransportResponse.failed(TransportFailure.TIMEOUT);
      await replaced.paste(PRODUCT_TEXT);
      const old: ClipboardResultView = replaced.result() as ClipboardResultView;
      await replaced.paste(ORDINARY_TEXT);
      check(replaced.kind() === ClipboardResultView.UNRECOGNIZED, '新粘贴得 ①', replaced.kind());
      check(!replaced.controller.retryResult(old), '旧 ⑤ 的【重试】在新结果出来后被拒');
      await flush();
      expect(replaced.parseCount()).assertEqual(1);
      check(replaced.kind() === ClipboardResultView.UNRECOGNIZED, '新 ① 不被旧回调清掉', replaced.kind());
    });

    // ================================================================ 新一次手动粘贴即清旧 ①⑤（三端口径；iOS b r1 S2-2）

    it('hm07vb_new_paste_clears_old_unrecognized_and_network_cards_immediately', 0, async () => {
      // ① 与 ⑤ 各一遍：开始新一次手动粘贴（PasteButton SUCCESS、被受理）那一刻就清，不等读取 / parse 结果。
      const seeds: string[] = ['unrecognized', 'network'];
      for (const seed of seeds) {
        const f: OverlayClipFixture = new OverlayClipFixture();
        if (seed === 'network') {
          f.reply = TransportResponse.failed(TransportFailure.TIMEOUT);
          await f.paste(PRODUCT_TEXT);
        } else {
          await f.paste(ORDINARY_TEXT);
        }
        check(f.result() !== null, seed + ' 旧结果卡在');
        f.pasteboard.text = PRODUCT_TEXT;
        f.pasteboard.hold = true;
        const pending: Promise<string> = f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
        await flush();
        check(f.result() === null, seed + ' 新粘贴读取未完成时旧卡已清', f.kind());
        f.pasteboard.release();
        await pending;
        await flush();
      }
    });

    it('hm07vb_new_paste_that_yields_no_result_still_clears_old_card', 0, async () => {
      // iOS b r1 S2-2 的三种「没有新结果」的粘贴：空剪贴板（首页进 SearchTyping）、纯邀请码（已出邀请条）、App 自写内容静默结束。
      const empty: OverlayClipFixture = new OverlayClipFixture();
      await empty.paste(ORDINARY_TEXT);
      check(empty.kind() === ClipboardResultView.UNRECOGNIZED, '先有 ①');
      expect(await empty.paste(null)).assertEqual(ManualPasteAction.OPEN_SEARCH_TYPING);
      check(empty.result() === null, '空剪贴板粘贴后旧 ① 已清', empty.kind());
      const invite: OverlayClipFixture = new OverlayClipFixture();
      invite.reply = TransportResponse.failed(TransportFailure.TIMEOUT);
      await invite.paste(PRODUCT_TEXT);
      check(invite.kind() === ClipboardResultView.NETWORK_FAILED, '先有 ⑤');
      expect(await invite.paste(INVITE_TEXT)).assertEqual(PasteOutcome.INVITE_PROMPT);
      check(invite.result() === null, '粘贴邀请内容后旧 ⑤ 已清', invite.kind());
      check(invite.controller.snapshot.prompt !== null, '邀请条照常出现');
    });

    it('hm07vb_new_paste_keeps_light_notice_and_invite_prompt', 0, async () => {
      // 轻提示（30131 等）与邀请条不随「开始新粘贴」清（三端口径：只清 ①⑤）。
      const f: OverlayClipFixture = new OverlayClipFixture();
      f.reply = envelope(30131, '{}');
      await f.paste(PRODUCT_TEXT);
      const light: ClipboardResultView | null = f.result();
      check(light !== null && light.kind === ClipboardResultView.NOTICE, '30131 是轻提示', f.kind());
      f.pasteboard.text = PRODUCT_TEXT;
      f.pasteboard.hold = true;
      const pending: Promise<string> = f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      check(f.result() === light, '读取未完成时轻提示不动', f.kind());
      f.pasteboard.release();
      await pending;
      await flush();
      const g: OverlayClipFixture = new OverlayClipFixture();
      expect(await g.paste(INVITE_TEXT)).assertEqual(PasteOutcome.INVITE_PROMPT);
      const prompt: ClipboardPromptView | null = g.controller.snapshot.prompt;
      check(prompt !== null, '邀请条已出');
      g.pasteboard.text = PRODUCT_TEXT;
      g.pasteboard.hold = true;
      const again: Promise<string> = g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      check(g.controller.snapshot.prompt === prompt, '开始新粘贴时邀请条不动');
      g.pasteboard.release();
      await again;
      await flush();
    });

    it('hm07vb_paste_not_admitted_does_not_clear_old_card', 0, async () => {
      // 没有真正开始粘贴（临时授权失败 / 敏感浮层）：不清旧卡（用户没有发起新一次读取）。
      const f: OverlayClipFixture = new OverlayClipFixture();
      await f.paste(ORDINARY_TEXT);
      const old: ClipboardResultView | null = f.result();
      check(old !== null, '先有 ①');
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, false)).assertEqual(PasteOutcome.NO_AUTH);
      check(f.result() === old, '临时授权失败不清旧卡');
      f.overlay = ClipboardSensitive.OVERLAY_AUTH_SHEET;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(PasteOutcome.SKIPPED);
      expect(f.pasteboard.reads).assertEqual(1);
    });
  });
}
