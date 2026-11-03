// HM-CLIP-BATCH / FU-X-CLIP-MANUAL（鸿蒙）：手动查返利不做自写排除、不读不写 24 小时自动去重记录；自动任务不变。
// 依据：08 `10_ID` BR-ID-16 细则（couli origin/main 37808a5 第 839 行）「去重与自写排除只对自动任务——排除本 App 最近 10 次写入剪贴板的
// 内容（按 hash）；同 hash 24 小时内只自动识别一次……手动任务不读不写这两项缓存，用户再次粘贴同一内容照常识别商品；邀请提示条『同一内容
// 24 小时只提示一次』是 BR-INV-04 的独立去重，对自动与手动读取都生效、不在本条缓存里」。任务书 NATIVE/FU-X-CLIP-MANUAL/brief.md 口径 1–4。
// 执行层集成：真实 ClipboardController + 真实 ApiClient + 本地假服务（NetworkTestRig，不连任何地址）、真实 Router / StackNavigator；
// 自动任务经鸿蒙适配器替身（eligible_granted，只在本测试里）走 ImportCoordinator，手动任务经 pasteProduct（PasteButton SUCCESS 后）。
// 盐用 000102…1f 这类样例字节；剪贴板样例都是演示文本，没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, ClipboardController, ClipboardDeps, ClipboardEligibility, ClipboardPromptView, ClipboardReadPolicy,
  ClipboardRecords, ClipboardSensitive, GuardState, ImportPreferenceStore, ImportReadResult, LaunchReadiness, ManualPasteAction,
  MemoryClipboardHashStore, MemoryClipboardSaltStore, MemoryPendingBackend, PasteboardPort, PasteOutcome, PendingActionStore,
  PrivacyState, RouteDestination, RouteRequest, RouteSource, Router, RouteTable, StackNavigator, TransportRequest,
  TransportResponse, UpdateCheckStatus, UpdateState
} from '../../Index';
import { RouteSpec } from 'generated';
import { MemoryPathStack } from './App05bFixture';
import { FakeAdapter, FakeImportBackend, RetryClock, versionConfig } from './Hm05rFixture';
import { envelope, flush, Rig } from './NetworkTestRig';

const PRODUCT_LINK: string = 'https://e.tb.cn/h.Demo01?tk=Sample';
const PRODUCT_TEXT: string = '分享好物 ' + PRODUCT_LINK + ' 「全脂纯牛奶 250ml」 其他说明文字不上传';
const PRODUCT_UPLOAD: string = PRODUCT_LINK + '\n全脂纯牛奶 250ml';
const INVITE_TEXT: string = '我在用凑狸，邀请码 K7M3QX';
const TAB_ROOTS: string[] = ['Home', 'AgentChat', 'OrderList', 'Me'];
const NOW: number = 1790661600 * 1000;
const SALT_HEX: string = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

function bytes(hex: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(hex.length / 2);
  for (let i: number = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function card(key: string): string {
  return '{"product_key":"' + key + '","item_ref":"ref-' + key + '","platform":"taobao","title":"降噪蓝牙耳机",'
    + '"image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
    + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"link-' + key + '","cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00",'
    + '"stale":false,"age_sec":12,"source":"taobao_union","disclaimer_keys":["price_basis"],"availability":"ok"}';
}

function oneCard(): string {
  return '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"' + PRODUCT_LINK + '"},"card":' + card('tb:1') + '}]}';
}

function same(label: string, actual: string | number | boolean | null, expected: string | number | boolean | null): void {
  expect(label + '=' + String(actual)).assertEqual(label + '=' + String(expected));
}

class CountingPasteboard implements PasteboardPort {
  text: string | null = null;
  reads: number = 0;
  writes: number = 0;

  readText(): Promise<string | null> {
    this.reads++;
    return Promise.resolve(this.text);
  }

  writeText(text: string): Promise<boolean> {
    this.writes++;
    this.text = text;
    return Promise.resolve(true);
  }
}

/**
 * 一套执行层（与 Hm05rIntegration 的 ImportRig 同一接线）：首页根页、窗口获焦、隐私已同意。适配器缺省 not_eligible（D1，自动任务只降级不读）；
 * autoReads(text) 后自动任务程序化读取到 text。手动粘贴读假系统剪贴板 pasteboard。guest 可切换（G01：已登录不出邀请确认）。
 */
class ManualRig {
  readonly rig: Rig;
  readonly pasteboard: CountingPasteboard = new CountingPasteboard();
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly store: MemoryClipboardHashStore = new MemoryClipboardHashStore();
  readonly saltStore: MemoryClipboardSaltStore = new MemoryClipboardSaltStore();
  readonly prefs: ImportPreferenceStore;
  readonly adapter: FakeAdapter = new FakeAdapter();
  readonly controller: ClipboardController;
  guest: boolean = true;
  homePage: number = 0;

  constructor() {
    this.adapter.probeResult = ClipboardEligibility.NOT_ELIGIBLE;
    this.rig = new Rig(null);
    this.rig.nowMillis = NOW;
    this.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      if (r.url.indexOf('/v1/inputs/parse') >= 0) {
        return Promise.resolve(envelope(0, oneCard()));
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
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => NOW),
      (): GuardState => new GuardState('consented', 'ok', 'guest', true, '1.0.0', false), this.navigator,
      (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
    this.prefs = new ImportPreferenceStore(new FakeImportBackend(), (): number => NOW, new RetryClock().schedule());
    const deps: ClipboardDeps = new ClipboardDeps(this.pasteboard, new ApiClientSearchPort(this.rig.client));
    deps.consent = (): string => ClipboardReadPolicy.CONSENT_AGREED;
    deps.overlay = (): string => ClipboardSensitive.OVERLAY_NONE;
    deps.scope = (): string => ClipboardController.scopeKey(this.rig.client.captureScope());
    deps.guest = (): boolean => this.guest;
    deps.config = (): Record<string, Object> => {
      const c: Record<string, Object> = {};
      c['share_domains'] = ['share.example.test'];
      c['clipboard'] = versionConfig('v1')['clipboard'];
      return c;
    };
    deps.open = (route: string, params: Record<string, Object>): boolean => {
      this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
      const names: string[] = this.stack.getAllPathName();
      return names.length > 0 && names[names.length - 1] === route;
    };
    deps.clock = (): number => NOW;
    deps.store = this.store;
    deps.saltStore = this.saltStore;
    deps.randomSalt = (): Uint8Array => bytes(SALT_HEX);
    deps.adapter = this.adapter;
    deps.importPrefs = this.prefs;
    this.controller = new ClipboardController(deps);
    this.navigator.onStackChanged = (names: string[]): void => this.controller.stackChanged(names);
    this.controller.sync();
  }

  /** 冷启动到首页根页（回前台、首页显示、窗口获焦），等排队的自动任务做完。 */
  async start(): Promise<void> {
    this.controller.onForeground();
    this.homePage = this.controller.pageInstance();
    this.controller.pageShown(this.homePage);
    this.controller.windowFocus(true);
    await flush();
    await flush();
  }

  /** 回到首页根页后退后台再回前台：新一轮自动任务。 */
  async nextRound(): Promise<void> {
    this.backHome();
    this.controller.onBackground();
    this.controller.onForeground();
    this.controller.pageShown(this.homePage);
    await flush();
    await flush();
  }

  /** 上一次结果可能已跳商品详情：回首页根页（自动任务只在首页根页，手动粘贴也从首页发起）。 */
  backHome(): void {
    if (this.stack.getAllPathName().length > 0) {
      this.stack.names = [];
      this.controller.stackChanged([]);
    }
  }

  autoReads(text: string): ManualRig {
    this.adapter.probeResult = ClipboardEligibility.ELIGIBLE_GRANTED;
    this.adapter.next = new ImportReadResult(ImportReadResult.KIND_TEXT, text);
    return this;
  }

  async manual(text: string): Promise<string> {
    this.backHome();
    this.pasteboard.text = text;
    const out: string = await this.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
    await flush();
    return out;
  }

  parses(): number {
    return this.rig.server.count('/v1/inputs/parse');
  }

  lastUpload(): string {
    return (JSON.parse(this.rig.server.last('/v1/inputs/parse').body ?? '{}') as Record<string, Object>)['text'] as string;
  }

  promptedRecord(): string | null {
    return this.store.read(ClipboardRecords.KEY_PROMPTED);
  }

  invitePrompt(): ClipboardPromptView | null {
    const p: ClipboardPromptView | null = this.controller.snapshot.prompt;
    return p !== null && p.inviteCode !== null ? p : null;
  }
}

export default function fuXClipManualTest() {
  describe('FuXClipManual', () => {
    // 口径 1 + 2；变异 ① 手动仍读台账（这里 parse=0 红）、③ 自动也去掉自写排除（后半 parse=2 红）
    it('manual_paste_of_self_written_product_uploads_while_auto_still_excludes_it', 0, async () => {
      const r: ManualRig = new ManualRig();
      await r.start();
      same('not eligible at start: no auto read', r.adapter.reads, 0);
      same('self write ok', await r.controller.writer.write(PRODUCT_TEXT), true);
      same('ledger holds it (writes unchanged, 口径 4)', r.controller.ledger.contains(PRODUCT_TEXT), true);
      // 手动：不读台账，照常候选提取 → 上传 parse
      same('manual outcome', await r.manual(PRODUCT_TEXT), ManualPasteAction.PARSE);
      same('manual parse once', r.parses(), 1);
      same('manual upload = link + title only', r.lastUpload(), PRODUCT_UPLOAD);
      same('manual did not drop ledger entry', r.controller.ledger.contains(PRODUCT_TEXT), true);
      // 自动：同一自写内容仍排除（读了，但不上传、不出卡）
      r.autoReads(PRODUCT_TEXT);
      await r.nextRound();
      same('auto read happened', r.adapter.reads, 1);
      same('auto excludes self-written: no extra parse', r.parses(), 1);
      // 再手动一次：照常上传（同一内容再次粘贴照常识别）
      same('manual again', await r.manual(PRODUCT_TEXT), ManualPasteAction.PARSE);
      same('manual again parses', r.parses(), 2);
    });

    // 口径 1：手动不写 24 小时自动去重记录；变异 ② 手动写了 prompted 记录（自动那次 parse 不发 → 红）
    it('manual_paste_does_not_write_24h_record_so_auto_recognizes_same_content_once', 0, async () => {
      const r: ManualRig = new ManualRig();
      await r.start();
      same('manual', await r.manual(PRODUCT_TEXT), ManualPasteAction.PARSE);
      same('manual parse', r.parses(), 1);
      same('manual wrote no prompted record', r.promptedRecord(), null);
      same('manual again (no dedup)', await r.manual(PRODUCT_TEXT), ManualPasteAction.PARSE);
      same('manual again parse', r.parses(), 2);
      same('still no prompted record', r.promptedRecord(), null);
      // 紧接着自动任务读到同一内容：仍自动识别一次
      r.autoReads(PRODUCT_TEXT);
      await r.nextRound();
      same('auto read', r.adapter.reads, 1);
      same('auto recognizes once after manual', r.parses(), 3);
      same('auto upload', r.lastUpload(), PRODUCT_UPLOAD);
      same('auto wrote its own 24h record', r.promptedRecord() !== null, true);
      // 自动任务自己的 24 小时去重照旧（口径 2）：下一轮同一内容不再上传
      await r.nextRound();
      same('auto read next round', r.adapter.reads, 2);
      same('auto 24h dedup unchanged', r.parses(), 3);
    });

    // 口径 1：手动不读 24 小时记录；变异 ④ 手动读了 24 小时记录（自动识别过后手动 parse 不发 → 红）
    it('manual_paste_after_auto_recognition_within_24h_still_uploads', 0, async () => {
      const r: ManualRig = new ManualRig().autoReads(PRODUCT_TEXT);
      await r.start();
      same('auto read', r.adapter.reads, 1);
      same('auto parse', r.parses(), 1);
      same('auto 24h record written', r.promptedRecord() !== null, true);
      const recorded: string | null = r.promptedRecord();
      same('manual within 24h', await r.manual(PRODUCT_TEXT), ManualPasteAction.PARSE);
      same('manual uploads despite auto record', r.parses(), 2);
      same('manual within 24h again', await r.manual(PRODUCT_TEXT), ManualPasteAction.PARSE);
      same('manual uploads again', r.parses(), 3);
      same('manual did not rewrite the 24h record', r.promptedRecord(), recorded);
      // 反例：自动任务仍按记录去重（证明记录确实在，上面两次手动不是因为记录没写）
      await r.nextRound();
      same('auto read next round', r.adapter.reads, 2);
      same('auto still deduped', r.parses(), 3);
    });

    // 口径 3：自写的纯邀请口令手动粘贴按 BR-INV-04 处理（不因自写台账提前丢弃）；自动任务对同一自写内容仍排除
    it('self_written_pure_invite_manual_paste_follows_BR_INV_04', 0, async () => {
      // 游客：出邀请确认条（不发 parse）
      const g: ManualRig = new ManualRig();
      await g.start();
      same('self write invite', await g.controller.writer.write(INVITE_TEXT), true);
      same('guest manual outcome', await g.manual(INVITE_TEXT), PasteOutcome.INVITE_PROMPT);
      const p: ClipboardPromptView | null = g.invitePrompt();
      same('guest invite prompt code', p === null ? null : p.inviteCode, 'K7M3QX');
      same('guest no parse', g.parses(), 0);
      same('ledger still holds invite', g.controller.ledger.contains(INVITE_TEXT), true);
      // 已登录（G01，与未自写的纯邀请内容相同）：静默结束，不出 30132、不出确认条
      const m: ManualRig = new ManualRig();
      m.guest = false;
      await m.start();
      await m.controller.writer.write(INVITE_TEXT);
      same('member manual outcome', await m.manual(INVITE_TEXT), PasteOutcome.IGNORED);
      same('member no prompt', m.controller.snapshot.prompt === null, true);
      same('member no result card', m.controller.snapshot.result === null, true);
      same('member no parse', m.parses(), 0);
      // 自动任务：自写的邀请口令仍排除（游客也不出确认条）
      const a: ManualRig = new ManualRig();
      await a.start();
      await a.controller.writer.write(INVITE_TEXT);
      a.autoReads(INVITE_TEXT);
      await a.nextRound();
      same('auto read invite', a.adapter.reads, 1);
      same('auto self-written invite: no prompt', a.invitePrompt() === null, true);
      same('auto self-written invite: no parse', a.parses(), 0);
    });

    // 口径 3：BR-INV-04「同一内容 24 小时只提示一次」对手动与自动都生效：手动出过邀请确认条后，自动任务 24 小时内同一内容不再出
    it('manual_invite_prompt_counts_for_BR_INV_04_so_auto_does_not_prompt_same_invite', 0, async () => {
      const r: ManualRig = new ManualRig();
      await r.start();
      same('manual invite', await r.manual(INVITE_TEXT), PasteOutcome.INVITE_PROMPT);
      const p: ClipboardPromptView | null = r.invitePrompt();
      same('prompt shown', p !== null, true);
      r.controller.closePrompt((p as ClipboardPromptView).id);
      same('closed', r.controller.snapshot.prompt === null, true);
      r.autoReads(INVITE_TEXT);
      await r.nextRound();
      same('auto read invite', r.adapter.reads, 1);
      same('auto does not re-prompt within 24h', r.invitePrompt() === null, true);
      same('no parse', r.parses(), 0);
      // 对照：没被手动提示过的邀请内容，自动任务照常出确认条（上面不是因为自动不出邀请条）
      const c: ManualRig = new ManualRig().autoReads(INVITE_TEXT);
      await c.start();
      same('control: auto invite prompt', c.invitePrompt() !== null, true);
    });
  });
}
