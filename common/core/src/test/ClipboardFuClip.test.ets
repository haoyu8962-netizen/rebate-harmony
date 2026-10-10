// FU-CLIP 鸿蒙剪贴板补齐的执行层集成测试（brief §2.7）：真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer，不连任何地址）、真实
// Router / StackNavigator、执行层 ClipboardController 的生命周期与分享入口（与 entry AppClipboard 同一接线）。系统剪贴板用可数读写次数
// 的假剪贴板，盐用内存盐存储（测试替身只替代系统能力）。样例全部是演示数据；盐用 000102…1f 这类明显的样例字节，没有像密钥的字面量。
// 覆盖：C2 白名单与口令（经 PasteButton 入口）、C3 加盐记录（生产接线路径）、C4 鸿蒙 clipboard.read 不声明（经真实 BridgeHost）、
// C5 共享 busy、C6 系统分享导入、C7 分享提示条的平台显示。纯函数向量在 ClipboardCandidatesVector.test.ets。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, BridgeCall, BridgeHost, BridgeResult, ClipboardController, ClipboardDeps, ClipboardFingerprint,
  ClipboardPromptBinding, ClipboardPromptInfo, ClipboardPromptView, ClipboardReadPolicy, ClipboardRecords,
  ClipboardResultView, ClipboardSensitive, ClipboardSnapshot, GuardState, LaunchReadiness, LocalDataCleanerRegistry,
  ManualPasteAction, MemoryClipboardHashStore, MemoryClipboardSaltStore, MemoryPendingBackend, PasteboardPort,
  PendingActionStore, PrivacyState, RequestSigner, RouteDestination, RouteRequest, RouteSource, Router, RouteTable,
  Sha256, ShareImportAction, SharePromptTexts, StackNavigator, TransportRequest, TransportResponse, UpdateCheckStatus,
  UpdateState
} from '../../Index';
import { RouteSpec } from 'generated';
import { MemoryPathStack } from './App05bFixture';
import { FakeState, MAIN_TAP, ManualClock, req, wire } from './BridgeHost.test';
import { Deferred, envelope, flush, Rig } from './NetworkTestRig';

const SALT_HEX: string = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const OTHER_SALT_HEX: string = '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f';
const TB_LINK: string = 'https://m.tb.cn/h.Demo01?tk=Sample';
const SHARE_TEXT: string = '【淘宝】分享给你 ' + TB_LINK + ' 「降噪蓝牙耳机」 复制后打开淘宝，聊天样例13800138000 验证码482731';
const TAB_ROOTS: string[] = ['Home', 'AgentChat', 'OrderList', 'Me'];
/** 草稿表的同一份字（entry ClipboardDraftTexts 的 FU-CLIP 键），供 SharePromptTexts 测试。 */
const DRAFTS: Map<string, string> = new Map<string, string>([
  ['clipboard.share_prompt', '收到分享的{platform_name}商品，查返利？'],
  ['clipboard.share_prompt.label', '检测到{platform_name}商品链接，查返利'],
  ['clipboard.share_prompt.label_tpwd', '检测到{platform_name}口令，查返利'],
  ['clipboard.prompt.detail', '{platform_name}商品链接 {display}'],
  ['clipboard.prompt.detail.tpwd', '{platform_name}口令'],
  ['clipboard.prompt.detail.more', '等 {count} 个']
]);

function bytes(hex: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(hex.length / 2);
  for (let i: number = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function plainSha(text: string): string {
  return RequestSigner.hex(Sha256.digest(RequestSigner.utf8(text)));
}

function draft(key: string, vars: Map<string, string>): string {
  let text: string = DRAFTS.get(key) ?? '';
  vars.forEach((value: string, name: string): void => {
    text = text.split('{' + name + '}').join(value);
  });
  return text;
}

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

/** 假系统剪贴板：可数读写次数（写入次数必须始终为 0：识别、提示、上传、分享导入都不改写系统剪贴板）。 */
class CountingPasteboard implements PasteboardPort {
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

/** 记下删除顺序的盐存储（撤回同意要先删盐）。 */
class LoggingSaltStore extends MemoryClipboardSaltStore {
  readonly log: string[];

  constructor(log: string[]) {
    super();
    this.log = log;
  }

  remove(): boolean {
    this.log.push('salt');
    return super.remove();
  }
}

class LoggingHashStore extends MemoryClipboardHashStore {
  readonly log: string[];

  constructor(log: string[]) {
    super();
    this.log = log;
  }

  write(key: string, value: string | null): boolean {
    if (value === null) {
      this.log.push('del:' + key);
    }
    return super.write(key, value);
  }
}

class ShareFixture {
  readonly rig: Rig;
  readonly pasteboard: CountingPasteboard = new CountingPasteboard();
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly store: MemoryClipboardHashStore;
  readonly saltStore: MemoryClipboardSaltStore;
  readonly controller: ClipboardController;
  readonly snapshots: string[] = [];
  consent: string = ClipboardReadPolicy.CONSENT_AGREED;
  overlay: string = ClipboardSensitive.OVERLAY_NONE;
  flags: Record<string, Object> = {};
  nowMs: number = 1800000000000;
  reply: TransportResponse | null = envelope(0, oneCard());
  held: Deferred[] = [];
  salts: Uint8Array[] = [bytes(SALT_HEX)];

  constructor(store: MemoryClipboardHashStore = new MemoryClipboardHashStore(),
    saltStore: MemoryClipboardSaltStore = new MemoryClipboardSaltStore()) {
    this.store = store;
    this.saltStore = saltStore;
    this.rig = new Rig(null);
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
      const features: Record<string, Object> = {};
      features['flags'] = this.flags;
      c['features'] = features;
      return c;
    };
    deps.open = (route: string, params: Record<string, Object>): boolean => {
      this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
      return true;
    };
    deps.clock = (): number => this.nowMs;
    deps.store = this.store;
    deps.saltStore = this.saltStore;
    deps.randomSalt = (): Uint8Array => {
      const next: Uint8Array | undefined = this.salts.shift();
      return next === undefined ? new Uint8Array(0) : next;
    };
    this.controller = new ClipboardController(deps);
    this.controller.onChange = (s: ClipboardSnapshot): void => {
      this.snapshots.push(ShareFixture.render(s));
    };
    this.navigator.onStackChanged = (names: string[]): void => this.controller.stackChanged(names);
    this.controller.sync();
    this.controller.onForeground();
  }

  /** 快照里能看到的全部文字（提示条与结果；用来核对原文片段不出现）。 */
  static render(s: ClipboardSnapshot): string {
    const p: ClipboardPromptView | null = s.prompt;
    const r: ClipboardResultView | null = s.result;
    const info: ClipboardPromptInfo | null = p === null ? null : p.info;
    return [p === null ? '' : p.kind + '|' + (p.inviteCode ?? '') + '|' + p.entry,
      info === null ? '' : info.platform + '|' + info.labelRaw + '|' + (info.display ?? '') + '|' + info.count,
      r === null ? '' : r.kind + '|' + r.textKey + '|' + (r.prefill ?? '')].join('#');
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

  parseBody(): Record<string, Object> {
    return JSON.parse(this.rig.server.last('/v1/inputs/parse').body ?? '{}') as Record<string, Object>;
  }

  prompt(): ClipboardPromptView | null {
    return this.controller.snapshot.prompt;
  }

  binding(): ClipboardPromptBinding {
    const p: ClipboardPromptView | null = this.prompt();
    return new ClipboardPromptBinding(this.controller, p === null ? -1 : p.id);
  }

  storeText(): string {
    return this.store.dump().join('\n');
  }

  allVisible(): string {
    return this.snapshots.join('\n') + '\n' + ShareFixture.render(this.controller.snapshot);
  }
}

export default function clipboardFuClipTest() {
  describe('ClipboardFuClip', () => {
    // ------------------------------------------------------------------ C2 / C8：经 PasteButton 入口
    it('c2_disguised_or_unlisted_links_never_upload_on_both_entries', 0, async () => {
      for (const text of ['https://taobao.com.evil.cn/x', 'https://taobao.com@evil.cn/x', 'http://127.0.0.1/x',
        'https://example.com/x']) {
        for (const entry of [ManualPasteAction.ENTRY_HOME, ManualPasteAction.ENTRY_SEARCH_TYPING]) {
          const f: ShareFixture = new ShareFixture();
          if (entry === ManualPasteAction.ENTRY_SEARCH_TYPING) {
            f.open('Search');
          }
          f.pasteboard.text = text;
          expect(await f.controller.pasteProduct(entry, true, (_q: string): void => {
          })).assertEqual(ManualPasteAction.SEARCH_PREFILL);
          await flush();
          expect(f.parseCount()).assertEqual(0);
          expect(f.pasteboard.writes).assertEqual(0);
        }
      }
    });

    it('c2_mixed_text_uploads_only_whitelisted_candidates_and_title', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.pasteboard.text = '聊天样例 https://example.com/a ' + TB_LINK + ' https://taobao.com.evil.cn/x 「耳机」 验证码482731';
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
      await flush();
      expect(f.parseCount()).assertEqual(1);
      expect(f.parseBody()['text'] as string).assertEqual(TB_LINK + '\n耳机');
      expect(f.parseBody()['scene'] as string).assertEqual('clipboard');
      expect(f.pasteboard.writes).assertEqual(0);
    });

    it('c8_pure_tpwd_manual_paste_uploads_token_only', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.pasteboard.text = '复制这段 ￥AbCdEfGh12￥ 打开手机淘宝';
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
      await flush();
      expect(f.parseBody()['text'] as string).assertEqual('￥AbCdEfGh12￥');
    });

    it('c2_k03_taobao_flag_off_blocks_taobao_but_keeps_jd', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.flags['clipboard.enabled.taobao'] = false;
      f.pasteboard.text = TB_LINK;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true))
        .assertEqual(ManualPasteAction.SEARCH_PREFILL);
      await flush();
      expect(f.parseCount()).assertEqual(0);
      const g: ShareFixture = new ShareFixture();
      g.flags['clipboard.enabled.taobao'] = false;
      g.pasteboard.text = '￥AbCdEfGh12￥ https://u.jd.com/demo';
      expect(await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
      await flush();
      expect(g.parseBody()['text'] as string).assertEqual('https://u.jd.com/demo');
      // 端键 clipboard.enabled.harmony 仍只管自动识别（鸿蒙没有），不影响手动粘贴
      const h: ShareFixture = new ShareFixture();
      h.flags['clipboard.enabled.harmony'] = false;
      h.pasteboard.text = TB_LINK;
      expect(await h.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
    });

    // ------------------------------------------------------------------ C3：加盐记录（生产接线路径：ClipboardWriter → SaltedWriteLedger）
    it('c3_self_write_stores_hmac_fingerprint_not_plain_sha_and_excludes_paste', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      expect(f.saltStore.hasSalt).assertFalse();
      expect(await f.controller.writer.write(TB_LINK)).assertTrue();
      expect(f.saltStore.hasSalt).assertTrue();
      const fp: ClipboardFingerprint = new ClipboardFingerprint(bytes(SALT_HEX));
      const stored: string = f.storeText();
      expect(stored.indexOf(fp.hash(TB_LINK)) >= 0).assertTrue();
      expect(stored.indexOf(fp.saltId) >= 0).assertTrue();
      expect(stored.indexOf(plainSha(TB_LINK)) < 0).assertTrue();
      expect(stored.indexOf('m.tb.cn') < 0 && stored.indexOf('Demo01') < 0 && stored.indexOf('tk=') < 0).assertTrue();
      // 自写内容手动粘贴不上传
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true))
        .assertEqual(ManualPasteAction.SEARCH_PREFILL);
      await flush();
      expect(f.parseCount()).assertEqual(0);
      expect(f.pasteboard.writes).assertEqual(1);
    });

    it('c3_withdraw_deletes_salt_first_then_both_records_and_reconsent_reprompts', 0, async () => {
      const log: string[] = [];
      const f: ShareFixture = new ShareFixture(new LoggingHashStore(log), new LoggingSaltStore(log));
      f.salts.push(bytes(OTHER_SALT_HEX));
      expect(await f.controller.writer.write(TB_LINK)).assertTrue();
      log.splice(0, log.length);
      f.consent = ClipboardReadPolicy.CONSENT_BASIC;
      f.controller.sync();
      expect(log[0]).assertEqual('salt');
      expect(log.indexOf('del:' + ClipboardRecords.KEY_WRITTEN) > 0).assertTrue();
      expect(log.indexOf('del:' + ClipboardRecords.KEY_PROMPTED) > 0).assertTrue();
      expect(f.saltStore.hasSalt).assertFalse();
      expect(f.store.dump().length).assertEqual(0);
      expect(f.controller.recordsClearPending).assertFalse();
      // 基本模式下的写入不生成盐
      expect(await f.controller.writer.write('样例复制内容')).assertTrue();
      expect(f.saltStore.hasSalt).assertFalse();
      // 再同意：同一内容不再被当成自写，重新可上传
      f.consent = ClipboardReadPolicy.CONSENT_AGREED;
      f.controller.sync();
      f.pasteboard.text = TB_LINK;
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
    });

    it('c3_withdraw_failure_keeps_pending_and_retries_on_foreground', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      expect(await f.controller.writer.write(TB_LINK)).assertTrue();
      f.saltStore.failWrites = true;
      f.consent = ClipboardReadPolicy.CONSENT_BASIC;
      f.controller.sync();
      expect(f.controller.recordsClearPending).assertTrue();
      f.saltStore.failWrites = false;
      f.controller.onBackground();
      f.controller.onForeground();
      expect(f.controller.recordsClearPending).assertFalse();
      expect(f.saltStore.hasSalt).assertFalse();
    });

    it('c3_environment_cleaner_also_removes_salt', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      expect(await f.controller.writer.write(TB_LINK)).assertTrue();
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      f.controller.installCleaner(registry);
      await registry.cleanAll();
      expect(f.saltStore.hasSalt).assertFalse();
      expect(f.store.dump().length).assertEqual(0);
    });

    it('c3_rotated_salt_drops_old_self_write_exclusion', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      expect(await f.controller.writer.write(TB_LINK)).assertTrue();
      f.saltStore.setSalt(bytes(OTHER_SALT_HEX));
      expect(f.controller.ledger.contains(TB_LINK)).assertFalse();
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
    });

    it('c3_salt_failure_blocks_system_write_and_never_falls_back', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.saltStore.failReads = true;
      f.saltStore.failWrites = true;
      expect(await f.controller.writer.write(TB_LINK)).assertFalse();
      expect(f.pasteboard.writes).assertEqual(0);
      expect(f.store.dump().length).assertEqual(0);
      // 随机源拿不到 32 字节同样按盐不可用
      const g: ShareFixture = new ShareFixture();
      g.salts = [];
      expect(await g.controller.writer.write(TB_LINK)).assertFalse();
      expect(g.pasteboard.writes).assertEqual(0);
      expect(g.storeText().indexOf(plainSha(TB_LINK)) < 0).assertTrue();
    });

    it('c3_upgrade_removes_legacy_unsalted_keys_with_retry', 0, async () => {
      const legacy: MemoryClipboardHashStore = new MemoryClipboardHashStore();
      legacy.write('self_written', plainSha(TB_LINK));
      legacy.write('prompted', plainSha('邀请码 K7M3QX') + '@1800000000000');
      legacy.failWrites = true;
      const f: ShareFixture = new ShareFixture(legacy);
      expect(f.controller.legacyRecordsPending).assertTrue();
      legacy.failWrites = false;
      f.controller.onBackground();
      f.controller.onForeground();
      expect(f.controller.legacyRecordsPending).assertFalse();
      expect(legacy.read('self_written') === null && legacy.read('prompted') === null).assertTrue();
      // 未同意时同样删
      const old: MemoryClipboardHashStore = new MemoryClipboardHashStore();
      old.write('self_written', plainSha(TB_LINK));
      const g: ShareFixture = new ShareFixture(old);
      expect(old.read('self_written')).assertEqual(null);
      expect(g.controller.legacyRecordsPending).assertFalse();
    });

    // ------------------------------------------------------------------ C4：鸿蒙 clipboard.read 不声明
    it('c4_harmony_bridge_clipboard_read_answers_90001_without_reading', 0, async () => {
      const board: CountingPasteboard = new CountingPasteboard();
      board.text = SHARE_TEXT;
      const host: BridgeHost = new BridgeHost(new FakeState(), new ManualClock());
      host.register('clipboard.read', async (_c: BridgeCall): Promise<BridgeResult> => {
        await board.readText();
        return BridgeResult.ok();
      });
      const reply: string | null = await host.handle(req('r1', 'clipboard.read'), MAIN_TAP);
      expect(wire(reply).code).assertEqual(90001);
      expect(board.reads).assertEqual(0);
      expect((reply ?? '').indexOf('m.tb.cn') < 0).assertTrue();
    });

    // ------------------------------------------------------------------ C6 / C7：系统分享导入
    it('c6_share_on_home_shows_platform_prompt_and_parses_only_after_tap', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      expect(f.controller.shareArrived(ShareImportAction.MIME_TEXT, SHARE_TEXT)).assertEqual(ShareImportAction.PROMPT);
      const p: ClipboardPromptView | null = f.prompt();
      expect(p !== null && p.kind === ClipboardPromptView.KIND_SHARE).assertTrue();
      const info: ClipboardPromptInfo | null = p === null ? null : p.info;
      expect(info !== null && info.display === 'm.tb.cn/…' && info.displayName === '淘宝').assertTrue();
      await flush();
      expect(f.parseCount()).assertEqual(0);
      expect(f.binding().confirm()).assertTrue();
      await flush();
      expect(f.parseCount()).assertEqual(1);
      expect(f.parseBody()['scene'] as string).assertEqual('share_ext');
      // 点击上传的就是显示的那一份候选（第一行就是显示的主机）
      const body: string = f.parseBody()['text'] as string;
      expect(body).assertEqual(TB_LINK + '\n降噪蓝牙耳机');
      expect(body.split('\n')[0].indexOf('m.tb.cn') >= 0).assertTrue();
      // 原文的其余部分不进快照、不进本机存储；系统剪贴板不读不写
      const visible: string = f.allVisible() + f.storeText();
      for (const fragment of ['13800138000', '482731', 'tk=Sample', 'Demo01', '分享给你']) {
        expect(visible.indexOf(fragment) < 0).assertTrue();
      }
      expect(f.pasteboard.reads + f.pasteboard.writes).assertEqual(0);
      // 不记提示历史、不碰盐（K21）
      expect(f.saltStore.hasSalt).assertFalse();
    });

    it('c6_share_from_search_returns_home_root_then_prompts', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.open('Search');
      expect(f.controller.homeRoot()).assertFalse();
      expect(f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK)).assertEqual(ShareImportAction.PROMPT);
      expect(f.controller.homeRoot()).assertTrue();
      expect(f.prompt() !== null).assertTrue();
    });

    it('c6_nonproduct_share_gives_local_30132_with_title_only', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      expect(f.controller.shareArrived(ShareImportAction.MIME_TEXT, '这不是首行商品名 https://example.com/a 「耳机」'))
        .assertEqual(ShareImportAction.SEARCH_PREFILL);
      const r: ClipboardResultView | null = f.controller.snapshot.result;
      expect(r !== null && r.kind === ClipboardResultView.UNRECOGNIZED && r.prefill === '耳机').assertTrue();
      const g: ShareFixture = new ShareFixture();
      g.controller.shareArrived(ShareImportAction.MIME_TEXT, '今天下午三点见面\n第二行文字');
      const s: ClipboardResultView | null = g.controller.snapshot.result;
      expect(s !== null && s.prefill === null).assertTrue();
      await flush();
      expect(f.parseCount() + g.parseCount()).assertEqual(0);
      // 空文本：只回首页，不提示
      const h: ShareFixture = new ShareFixture();
      h.open('Search');
      expect(h.controller.shareArrived(ShareImportAction.MIME_TEXT, '')).assertEqual(ShareImportAction.HOME_ONLY);
      expect(h.controller.homeRoot()).assertTrue();
      expect(h.prompt() === null && h.controller.snapshot.result === null).assertTrue();
      // 非文本类型：忽略
      expect(h.controller.shareArrived('general.image', TB_LINK)).assertEqual(ShareImportAction.IGNORE_MIME);
    });

    it('c6_basic_mode_privacy_dialog_and_sensitive_pages_drop_without_navigating', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.consent = ClipboardReadPolicy.CONSENT_BASIC;
      f.open('Search');
      expect(f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK)).assertEqual(ShareImportAction.DROP);
      expect(f.controller.currentRoute()).assertEqual('Search');
      const g: ShareFixture = new ShareFixture();
      g.standOn('Withdraw');
      expect(g.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK)).assertEqual(ShareImportAction.DROP);
      expect(g.controller.currentRoute()).assertEqual('Withdraw');
      const h: ShareFixture = new ShareFixture();
      h.overlay = ClipboardSensitive.OVERLAY_PRIVACY_FIRST_LAUNCH;
      expect(h.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK)).assertEqual(ShareImportAction.DROP);
      await flush();
      expect(f.parseCount() + g.parseCount() + h.parseCount()).assertEqual(0);
      expect(f.prompt() === null && g.prompt() === null && h.prompt() === null).assertTrue();
    });

    it('c6_background_arrival_is_handled_once_on_foreground', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.controller.onBackground();
      expect(f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK)).assertEqual('pending');
      expect(f.prompt() === null).assertTrue();
      f.controller.onForeground();
      const first: ClipboardPromptView | null = f.prompt();
      expect(first !== null).assertTrue();
      f.binding().close();
      f.controller.onBackground();
      f.controller.onForeground();
      expect(f.prompt() === null).assertTrue();
    });

    it('c6_k22_new_share_replaces_unclicked_prompt_and_old_callback_is_dead', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      const old: ClipboardPromptBinding = f.binding();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, 'https://u.jd.com/demo');
      const p: ClipboardPromptView | null = f.prompt();
      expect(p !== null && p.id !== old.promptId && p.info !== null && p.info.platform === 'jd').assertTrue();
      expect(old.confirm()).assertFalse();
      await flush();
      expect(f.parseCount()).assertEqual(0);
      expect(f.binding().confirm()).assertTrue();
      await flush();
      expect(f.parseBody()['text'] as string).assertEqual('https://u.jd.com/demo');
    });

    it('c5_c6_parse_in_flight_ignores_new_share_and_shared_busy_blocks_entries', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.reply = null;
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      expect(f.binding().confirm()).assertTrue();
      await flush();
      expect(f.parseCount()).assertEqual(1);
      expect(f.controller.snapshot.busy).assertTrue();
      // 在途：新分享忽略；PasteButton 入口不读不发
      expect(f.controller.shareArrived(ShareImportAction.MIME_TEXT, 'https://u.jd.com/demo'))
        .assertEqual(ShareImportAction.IGNORE_BUSY);
      f.pasteboard.text = 'https://u.jd.com/demo';
      expect(await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual('busy');
      await flush();
      expect(f.pasteboard.reads).assertEqual(0);
      expect(f.parseCount()).assertEqual(1);
      // 反过来：PasteButton 的 parse 在途时点分享提示条，不发
      const g: ShareFixture = new ShareFixture();
      g.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      const shareButton: ClipboardPromptBinding = g.binding();
      g.reply = null;
      g.pasteboard.text = 'https://u.jd.com/demo';
      expect(await g.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
      await flush();
      expect(shareButton.confirm()).assertFalse();
      await flush();
      expect(g.parseCount()).assertEqual(1);
    });

    it('c6_identity_fixed_at_arrival_tab_background_withdraw_invalidate_prompt', 0, async () => {
      // 切 Tab
      const f: ShareFixture = new ShareFixture();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      const a: ClipboardPromptBinding = f.binding();
      f.open('Me');
      expect(f.prompt() === null).assertTrue();
      f.open('Home');
      expect(a.confirm()).assertFalse();
      // 进后台
      const g: ShareFixture = new ShareFixture();
      g.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      const b: ClipboardPromptBinding = g.binding();
      g.controller.onBackground();
      g.controller.onForeground();
      expect(b.confirm()).assertFalse();
      // 撤回同意
      const h: ShareFixture = new ShareFixture();
      h.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      const c: ClipboardPromptBinding = h.binding();
      h.consent = ClipboardReadPolicy.CONSENT_BASIC;
      h.controller.sync();
      h.consent = ClipboardReadPolicy.CONSENT_AGREED;
      h.controller.sync();
      expect(c.confirm()).assertFalse();
      await flush();
      expect(f.parseCount() + g.parseCount() + h.parseCount()).assertEqual(0);
    });

    it('c6_late_share_parse_after_leaving_home_is_dropped', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.reply = null;
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      expect(f.binding().confirm()).assertTrue();
      await flush();
      f.open('Search');
      for (const d of f.held) {
        d.resolve(envelope(0, oneCard()));
      }
      await flush();
      await flush();
      expect(f.controller.snapshot.result === null).assertTrue();
      expect(f.controller.currentRoute()).assertEqual('Search');
    });

    it('c6_rules_tightened_after_prompt_drops_it_and_confirm_does_nothing', 0, async () => {
      const f: ShareFixture = new ShareFixture();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      const old: ClipboardPromptBinding = f.binding();
      f.flags['clipboard.enabled.taobao'] = false;
      // 不等配置通知，点击时也要复核
      expect(old.confirm()).assertFalse();
      const g: ShareFixture = new ShareFixture();
      g.controller.shareArrived(ShareImportAction.MIME_TEXT, TB_LINK);
      g.flags['clipboard.enabled.taobao'] = false;
      g.controller.rulesChanged();
      expect(g.prompt() === null).assertTrue();
      // 其他平台的提示不受影响
      const h: ShareFixture = new ShareFixture();
      h.controller.shareArrived(ShareImportAction.MIME_TEXT, 'https://u.jd.com/demo');
      h.flags['clipboard.enabled.taobao'] = false;
      h.controller.rulesChanged();
      expect(h.prompt() !== null).assertTrue();
      await flush();
      expect(f.parseCount() + g.parseCount()).assertEqual(0);
    });

    it('c7_share_prompt_texts_show_platform_and_short_host_without_path_or_query', 0, () => {
      const f: ShareFixture = new ShareFixture();
      f.controller.shareArrived(ShareImportAction.MIME_TEXT, SHARE_TEXT);
      const p: ClipboardPromptView | null = f.prompt();
      const info: ClipboardPromptInfo | null = p === null ? null : p.info;
      expect(info !== null).assertTrue();
      if (info === null) {
        return;
      }
      const t: SharePromptTexts = SharePromptTexts.of(info, draft);
      expect(t.title).assertEqual('收到分享的淘宝商品，查返利？');
      expect(t.detail).assertEqual('淘宝商品链接 m.tb.cn/…');
      expect(t.label).assertEqual('检测到淘宝商品链接，查返利');
      expect(t.badge).assertEqual('淘宝');
      const all: string = t.title + t.detail + t.label;
      expect(all.indexOf('Demo01') < 0 && all.indexOf('tk=') < 0 && all.indexOf('h.') < 0).assertTrue();
      // 口令、天猫、多个
      const g: ShareFixture = new ShareFixture();
      g.controller.shareArrived(ShareImportAction.MIME_TEXT, '￥AbCdEfGh12￥ https://u.jd.com/demo');
      const gp: ClipboardPromptView | null = g.prompt();
      if (gp !== null && gp.info !== null) {
        const tt: SharePromptTexts = SharePromptTexts.of(gp.info, draft);
        expect(tt.detail).assertEqual('淘宝口令等 2 个');
        expect(tt.label).assertEqual('检测到淘宝口令，查返利');
      } else {
        expect('tpwd prompt').assertEqual('missing');
      }
      const h: ShareFixture = new ShareFixture();
      h.controller.shareArrived(ShareImportAction.MIME_TEXT, 'https://detail.tmall.com/item.htm?id=1');
      const hp: ClipboardPromptView | null = h.prompt();
      if (hp !== null && hp.info !== null) {
        const th: SharePromptTexts = SharePromptTexts.of(hp.info, draft);
        expect(th.title).assertEqual('收到分享的天猫商品，查返利？');
        expect(th.detail).assertEqual('天猫商品链接 detail.tmall.com/…');
      } else {
        expect('tmall prompt').assertEqual('missing');
      }
    });
  });
}
