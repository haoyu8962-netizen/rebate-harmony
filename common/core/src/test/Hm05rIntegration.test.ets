// HM-05r 测试 v1：执行层集成（真实 ClipboardController + 真实 ApiClient + 本地假服务 NetworkTestRig，不连任何地址；真实 Router /
// StackNavigator 同步导航栈；生命周期走 onForeground / onBackground，与 EntryAbility 同一入口）。只替换系统能力：假剪贴板（可数读写）、
// 鸿蒙适配器替身（eligible_granted 只在「条件满足组」用，生产默认 not_eligible，D1）、可失败的本机偏好存储。
// 测试 v3（2026-10-30 默认开启：BR-ID-16 2026-10-30 版；docs/changes/20261030-剪贴板默认开启.md §2 / §3；任务书 FU-X-CLIP-DEFAULT-ON
// §1 C1–C9 / §2.1；编排 D10-423）：用途说明半屏（首页 / 手动 / 设置三种来源）、功能同意版本、clipboard_auto_import 上报与补报相关用例删除；
// 改为 C1 默认开启（回前台首页根页自动任务，不弹、不报）、C2 手动首次直接读、C3 不写 / 不补报同意记录、C4 consent_version 不作门槛、
// C5 关闭态（在途取消、零读取零上传、手动照常、重启仍关）、C6 升级迁移（执行层构造时迁移）、C7 撤回与重新同意、C8 设置开关直接生效；
// 普通互斥模态（S1-1）改为「自动任务等待、模态收起后经 modalChanged() 同轮再试」。逐条依据见 tests-harmony-v3-handback.md §1 / §2。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, ApiRequest, ApiResult, ClipboardAutoSwitch, ClipboardController, ClipboardDeps, ClipboardEligibility,
  ClipboardReadPolicy, ClipboardSensitive, GuardState, HarmonyClipboardAdapter, ImportPreferenceStore, ImportReadResult,
  InvitePasteOutcome, LaunchReadiness, LocalDataCleanerRegistry, ManualPasteAction, MemoryClipboardHashStore, MemoryPendingBackend,
  NetworkHeaders, PasteboardPort, PasteOutcome, PendingActionStore, PrivacyState, RouteDestination, RouteRequest, RouteSource, Router,
  RouteTable, StackNavigator, TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState
} from '../../Index';
import { RouteSpec } from 'generated';
import { MemoryPathStack } from './App05bFixture';
import { FakeAdapter, FakeImportBackend, RetryClock, versionConfig } from './Hm05rFixture';
import { envelope, flush, header, Rig } from './NetworkTestRig';

const PRODUCT_LINK: string = 'https://e.tb.cn/h.Demo01?tk=Sample';
const PRODUCT_TEXT: string = '分享好物 ' + PRODUCT_LINK + ' 「全脂纯牛奶 250ml」 其他说明文字不上传';
const INVITE_TEXT: string = '我在用凑狸，邀请码 K7M3QX';
const TAB_ROOTS: string[] = ['Home', 'AgentChat', 'OrderList', 'Me'];
const NOW: number = 1790661600 * 1000;

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
  text: string | null = PRODUCT_TEXT;
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

/** 程序化读取挂起的适配器替身（测试 v3 C5：读取在途时关闭开关）：read() 返回的 Promise 由测试决定何时、以什么结果完成。 */
class HoldAdapter implements HarmonyClipboardAdapter {
  reads: number = 0;
  private resolvers: ((r: ImportReadResult) => void)[] = [];

  probe(): string {
    return ClipboardEligibility.ELIGIBLE_GRANTED;
  }

  read(): Promise<ImportReadResult> {
    this.reads++;
    return new Promise<ImportReadResult>((resolve: (r: ImportReadResult) => void): void => {
      this.resolvers.push(resolve);
    });
  }

  release(text: string): void {
    const list: ((r: ImportReadResult) => void)[] = this.resolvers;
    this.resolvers = [];
    for (const r of list) {
      r(new ImportReadResult(ImportReadResult.KIND_TEXT, text));
    }
  }
}

/** r3（2026-10-17 口径）写过的本机旧键。 */
function r3State(state: string): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  if (state === 'not_now') {
    m.set('import.notice_seen_version', 'v1');
  } else if (state === 'settings_off') {
    m.set('import.enabled', 'off');
    m.set('import.consent_version', 'v1');
    m.set('import.consented_at', String(NOW - 86400000));
    m.set('import.notice_seen_version', 'v1');
  } else if (state === 'enabled') {
    m.set('import.enabled', 'on');
    m.set('import.consent_version', 'v1');
    m.set('import.consented_at', String(NOW - 86400000));
    m.set('import.notice_seen_version', 'v1');
    m.set('import.pending_consents', '[{"type":"clipboard_auto_import","version":"v1","accepted_at_ms":' + (NOW - 86400000) + '}]');
  }
  return m;
}

/**
 * 一套执行层：首页根页已显示、窗口获焦、隐私已同意；配置里仍带着 consent_version（v1，C4：有无都不影响）。适配器缺省 not_eligible（D1）；
 * adapter 参数换成可挂起的替身时用它。
 */
class ImportRig {
  readonly rig: Rig;
  readonly pasteboard: CountingPasteboard = new CountingPasteboard();
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly backend: FakeImportBackend;
  readonly retry: RetryClock = new RetryClock();
  readonly prefs: ImportPreferenceStore;
  readonly adapter: FakeAdapter = new FakeAdapter();
  readonly controller: ClipboardController;
  consent: string = ClipboardReadPolicy.CONSENT_AGREED;
  overlay: string = ClipboardSensitive.OVERLAY_NONE;
  config: Record<string, Object> = versionConfig('v1');
  homePage: number = 0;
  /** 普通互斥模态（deps.modal；entry 接 AppClipboard.modal()：更新提示 update_prompt、权限说明 other_dialog），缺省 none。 */
  modal: string = 'none';

  constructor(backend: FakeImportBackend = new FakeImportBackend(), injectPrefs: boolean = true,
    adapter: HarmonyClipboardAdapter | null = null) {
    this.backend = backend;
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
    this.prefs = new ImportPreferenceStore(backend, (): number => NOW, this.retry.schedule());
    const deps: ClipboardDeps = new ClipboardDeps(this.pasteboard, new ApiClientSearchPort(this.rig.client));
    deps.consent = (): string => this.consent;
    deps.overlay = (): string => this.overlay;
    deps.scope = (): string => ClipboardController.scopeKey(this.rig.client.captureScope());
    deps.config = (): Record<string, Object> => {
      const c: Record<string, Object> = {};
      c['share_domains'] = ['share.example.test'];
      const clip: Object | undefined = this.config['clipboard'];
      c['clipboard'] = clip !== undefined ? clip : versionConfig(null)['clipboard'];
      if (this.config['features'] !== undefined) {
        c['features'] = this.config['features'];
      }
      return c;
    };
    deps.modal = (): string => this.modal;
    deps.open = (route: string, params: Record<string, Object>): boolean => {
      this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
      const names: string[] = this.stack.getAllPathName();
      return names.length > 0 && names[names.length - 1] === route;
    };
    deps.clock = (): number => NOW;
    deps.store = new MemoryClipboardHashStore();
    deps.adapter = adapter !== null ? adapter : this.adapter;
    if (injectPrefs) {
      deps.importPrefs = this.prefs;
    }
    this.controller = new ClipboardController(deps);
    this.navigator.onStackChanged = (names: string[]): void => this.controller.stackChanged(names);
    this.controller.sync();
  }

  /** 冷启动到首页根页（真实入口：回前台、首页显示、窗口获焦），等排队的尝试执行完。 */
  async start(): Promise<void> {
    this.controller.onForeground();
    this.homePage = this.controller.pageInstance();
    this.controller.pageShown(this.homePage);
    this.controller.windowFocus(true);
    await flush();
  }

  async toBackgroundAndBack(): Promise<void> {
    // 上一轮的结果可能已经跳到商品详情：先回首页根页（自动任务只在首页根页，D6）
    if (this.stack.getAllPathName().length > 0) {
      this.stack.names = [];
      this.controller.stackChanged([]);
    }
    this.controller.onBackground();
    this.controller.onForeground();
    this.controller.pageShown(this.homePage);
    await flush();
  }

  eligible(text: string = PRODUCT_TEXT): ImportRig {
    this.adapter.probeResult = ClipboardEligibility.ELIGIBLE_GRANTED;
    this.adapter.next = new ImportReadResult(ImportReadResult.KIND_TEXT, text);
    return this;
  }

  /** 发往 /v1/consents 的请求（2026-10-30 起剪贴板不再写 clipboard_auto_import，C3）。 */
  consents(): TransportRequest[] {
    return this.rig.server.received.filter((r: TransportRequest): boolean => r.url.indexOf('/v1/consents') >= 0);
  }

  parses(): number {
    return this.rig.server.count('/v1/inputs/parse');
  }

  top(): string {
    const names: string[] = this.stack.getAllPathName();
    return names.length === 0 ? '' : names[names.length - 1];
  }
}

async function wait(ms: number): Promise<void> {
  await new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
  await flush();
}

export default function hm05rIntegrationTest() {
  describe('Hm05rIntegration', () => {
    // ---------------------------------------------------------------- C1 默认开启
    it('fresh_install_privacy_agreed_home_root_foreground_reads_once_no_notice_no_consent_report_C1', 0, async () => {
      const on: ImportRig = new ImportRig().eligible();
      await on.start();
      await flush();
      same('default on: adapter read once', on.adapter.reads, 1);
      same('default on: readCount', on.controller.readCount, 1);
      same('default on: pasteboard port untouched', on.pasteboard.reads, 0);
      same('default on: parse once', on.parses(), 1);
      same('default on: only link and title uploaded',
        (JSON.parse(on.rig.server.last('/v1/inputs/parse').body ?? '{}') as Record<string, Object>)['text'] as string,
        PRODUCT_LINK + '\n全脂纯牛奶 250ml');
      same('default on: no consent report', on.consents().length, 0);
      same('default on: never writes clipboard', on.pasteboard.writes, 0);
      same('default on: display on', on.controller.autoReadDisplayOn(), true);
      same('default on: switch not written by reading', on.prefs.snapshot().enabled === false, false);
      // 每轮 1 次
      on.controller.windowFocus(true);
      on.controller.pageShown(on.homePage);
      await flush();
      same('once per round', on.adapter.reads, 1);
      await on.toBackgroundAndBack();
      same('next round reads again', on.adapter.reads, 2);
      // 生产缺省不具备资格（D1）：自动任务照样走到资格这一步、降级为 PasteButton（fallback 计 1），不读、不弹、不报
      const prod: ImportRig = new ImportRig();
      await prod.start();
      same('not eligible: fallback once', prod.controller.fallbackCount, 1);
      same('not eligible: no read', prod.adapter.reads + prod.pasteboard.reads + prod.controller.readCount, 0);
      same('not eligible: no parse', prod.parses(), 0);
      same('not eligible: no consent report', prod.consents().length, 0);
      // 首启隐私浮层那一轮（敏感浮层）跳过：不读不降级
      const first: ImportRig = new ImportRig().eligible();
      first.overlay = ClipboardSensitive.OVERLAY_PRIVACY_FIRST_LAUNCH;
      await first.start();
      same('privacy first-launch round skipped', first.adapter.reads + first.controller.fallbackCount, 0);
      first.overlay = ClipboardSensitive.OVERLAY_NONE;
      await first.toBackgroundAndBack();
      same('after agreeing, next foreground reads', first.adapter.reads, 1);
      // AgentChat 根页：不读（D6）
      const a: ImportRig = new ImportRig().eligible();
      a.router.open(RouteRequest.of('AgentChat', RouteSource.IN_APP));
      await a.start();
      same('AgentChat no auto read', a.adapter.reads + a.pasteboard.reads + a.controller.fallbackCount, 0);
    });

    // ---------------------------------------------------------------- C2 手动粘贴首次直接读
    it('manual_first_paste_reads_directly_without_notice_and_does_not_touch_switch_C2', 0, async () => {
      const r: ImportRig = new ImportRig();
      r.overlay = ClipboardSensitive.OVERLAY_PRIVACY_FIRST_LAUNCH;
      await r.start();
      r.overlay = ClipboardSensitive.OVERLAY_NONE;
      // PasteButton 未成功：不读
      same('no auth', await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, false), PasteOutcome.NO_AUTH);
      same('no read without success', r.pasteboard.reads, 0);
      const out: string = await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      same('first paste parses directly', out, ManualPasteAction.PARSE);
      same('read once', r.pasteboard.reads, 1);
      same('parse once', r.parses(), 1);
      same('result → detail', r.top(), 'ProductDetail');
      same('no consent report', r.consents().length, 0);
      same('clipboard never written', r.pasteboard.writes, 0);
      same('switch untouched (still never chosen)', r.prefs.snapshot().enabled, null);
      // 再次粘贴同样直接读
      r.stack.names = [];
      r.controller.stackChanged([]);
      same('second paste parses', await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true), ManualPasteAction.PARSE);
      await flush();
      same('second paste read', r.pasteboard.reads, 2);
      // fill_input（登录页邀请码【粘贴】）照旧
      const l: ImportRig = new ImportRig();
      l.pasteboard.text = INVITE_TEXT;
      await l.start();
      l.router.open(RouteRequest.of('Login', RouteSource.IN_APP));
      const invite: InvitePasteOutcome = await l.controller.pasteInvite(true);
      same('fill_input reads', l.pasteboard.reads, 1);
      same('fill_input not skipped', invite.actionRaw !== InvitePasteOutcome.SKIPPED, true);
    });

    // ---------------------------------------------------------------- C3 不写、不补报 clipboard_auto_import
    it('no_clipboard_consent_posted_and_legacy_queue_never_resent_C3', 0, async () => {
      const backend: FakeImportBackend = new FakeImportBackend().seed(r3State('enabled'));
      const r: ImportRig = new ImportRig(backend);
      r.eligible();
      await r.start();
      await r.toBackgroundAndBack();
      r.controller.sync();
      await flush();
      same('legacy queue not resent', r.consents().length, 0);
      same('legacy queue cleared on disk', backend.disk.has('import.pending_consents'), false);
      same('still on', r.controller.autoReadDisplayOn(), true);
      same('reads each round', r.adapter.reads, 2);
      // 设置关 / 开、手动粘贴：都不发 /v1/consents
      r.controller.toggleAutoRead(false);
      r.controller.toggleAutoRead(true);
      await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      same('toggle / manual post nothing', r.consents().length, 0);
    });

    it('other_record_consent_types_stay_unsigned_regression', 0, async () => {
      const r: ImportRig = new ImportRig();
      const result: ApiResult = await r.rig.client.request(new ApiRequest('recordConsent', {}, '',
        '{"type":"personalization","version":3,"accepted":false,"channel":"privacy_center","client_at":"2026-10-30T10:00:00+08:00"}'));
      same('sent', result.ok, true);
      const req: TransportRequest = r.consents()[0];
      same('personalization not signed', header(req, NetworkHeaders.SIGN) === undefined, true);
      same('no timestamp', header(req, NetworkHeaders.TIMESTAMP) === undefined, true);
    });

    // ---------------------------------------------------------------- C4 consent_version 不作门槛
    it('consent_version_missing_or_changed_does_not_affect_auto_or_manual_C4', 0, async () => {
      for (const v of ['missing', 'empty', 'v2']) {
        const r: ImportRig = new ImportRig().eligible();
        r.config = versionConfig(v === 'missing' ? null : v === 'empty' ? '' : v);
        await r.start();
        same(v + ' auto read', r.adapter.reads, 1);
        r.config = versionConfig('v3');
        await r.toBackgroundAndBack();
        same(v + ' changed → next round reads', r.adapter.reads, 2);
        same(v + ' manual parses', await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true), ManualPasteAction.PARSE);
        same(v + ' no consent report', r.consents().length, 0);
      }
    });

    // ---------------------------------------------------------------- 回前台（D6 / 在途作废）
    it('auto_task_cancelled_when_backgrounded_before_parse_returns', 0, async () => {
      const r: ImportRig = new ImportRig().eligible();
      r.rig.server.handler = (q: TransportRequest): Promise<TransportResponse> => new Promise<TransportResponse>(
        (resolve: (v: TransportResponse) => void): void => {
          setTimeout((): void => resolve(q.url.indexOf('/v1/inputs/parse') >= 0 ? envelope(0, oneCard()) : envelope(0, '{}')), 50);
        });
      await r.start();
      r.controller.onBackground();
      await wait(120);
      same('late result dropped', r.top() === 'ProductDetail' || r.controller.snapshot.result !== null, false);
    });

    // ---------------------------------------------------------------- C5 关闭态
    it('settings_off_cancels_inflight_read_and_parse_then_zero_reads_uploads_manual_ok_restart_keeps_off_C5', 0, async () => {
      // 读取在途时关闭：迟到的读取结果丢弃，不提取、不上传
      const hold: HoldAdapter = new HoldAdapter();
      const backend: FakeImportBackend = new FakeImportBackend();
      const r: ImportRig = new ImportRig(backend, true, hold);
      await r.start();
      same('reading', hold.reads, 1);
      same('toggle off', r.controller.toggleAutoRead(false), ClipboardAutoSwitch.OFF);
      hold.release(PRODUCT_TEXT);
      await flush();
      same('late read discarded: no parse', r.parses(), 0);
      same('no result', r.controller.snapshot.result === null && r.top() !== 'ProductDetail', true);
      // 之后零读取零上传
      for (let i: number = 0; i < 3; i++) {
        await r.toBackgroundAndBack();
      }
      same('zero reads after off', hold.reads, 1);
      same('zero uploads after off', r.parses(), 0);
      same('display off', r.controller.autoReadDisplayOn(), false);
      // 手动粘贴照常
      same('manual still parses', await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true), ManualPasteAction.PARSE);
      await flush();
      same('manual read', r.pasteboard.reads, 1);
      same('manual upload', r.parses(), 1);
      // 重启（独立磁盘镜像）后仍关
      const restarted: ImportRig = new ImportRig(backend.reopen());
      restarted.eligible();
      await restarted.start();
      same('restart: display off', restarted.controller.autoReadDisplayOn(), false);
      same('restart: zero reads', restarted.adapter.reads + restarted.controller.fallbackCount, 0);
      // parse 在途时关闭：迟到的结果不出卡、不跳详情
      const p: ImportRig = new ImportRig().eligible();
      p.rig.server.handler = (q: TransportRequest): Promise<TransportResponse> => new Promise<TransportResponse>(
        (resolve: (v: TransportResponse) => void): void => {
          setTimeout((): void => resolve(q.url.indexOf('/v1/inputs/parse') >= 0 ? envelope(0, oneCard()) : envelope(0, '{}')), 50);
        });
      await p.start();
      same('parse in flight', p.parses(), 1);
      same('busy while parse in flight', p.controller.snapshot.busy, true);
      p.controller.toggleAutoRead(false);
      // 「立即取消请求等待」：关闭的同一刻自动任务撤销、共享 busy 释放，不等迟到的响应
      same('request wait cancelled at once', p.controller.snapshot.busy, false);
      await wait(120);
      same('late parse result dropped', p.top() === 'ProductDetail' || p.controller.snapshot.result !== null, false);
      // 服务端按端停用：不读，但不改用户开关（配置只能关不能开）
      const s: ImportRig = new ImportRig().eligible();
      const features: Record<string, Object> = {};
      features['clipboard'] = JSON.parse('{"auto_read":{"harmony":false}}') as Object;
      s.config['features'] = features;
      await s.start();
      same('server off: no read', s.adapter.reads, 0);
      same('server off: user switch still on', s.controller.autoReadDisplayOn(), true);
    });

    // ---------------------------------------------------------------- C6 升级迁移（执行层装配时）
    it('upgrade_from_r3_four_states_mapped_when_controller_is_built_C6', 0, async () => {
      const cases: string[] = ['never', 'not_now', 'settings_off', 'enabled'];
      for (const st of cases) {
        const backend: FakeImportBackend = new FakeImportBackend().seed(r3State(st));
        const r: ImportRig = new ImportRig(backend);
        r.eligible();
        const on: boolean = st === 'never' || st === 'enabled';
        same(st + ' display', r.controller.autoReadDisplayOn(), on);
        await r.start();
        same(st + ' reads', r.adapter.reads, on ? 1 : 0);
        same(st + ' no consent report', r.consents().length, 0);
        // 迁移只做一次：重启后（磁盘镜像）同一结论
        const again: ImportRig = new ImportRig(backend.reopen());
        same(st + ' restart same', again.controller.autoReadDisplayOn(), on);
      }
    });

    // ---------------------------------------------------------------- C7 撤回与重新同意
    it('privacy_withdraw_basic_mode_reads_nothing_reagree_default_on_unless_switched_off_C7', 0, async () => {
      for (const before of ['default', 'off']) {
        const r: ImportRig = new ImportRig().eligible();
        if (before === 'off') {
          r.controller.toggleAutoRead(false);
        }
        const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
        r.controller.installCleaner(registry);
        // 撤回：进入基本模式（状态同步 + 撤回钩子）
        r.consent = ClipboardReadPolicy.CONSENT_BASIC;
        r.controller.sync();
        registry.runWithdrawalHooks();
        await r.start();
        same(before + ' basic: no auto read', r.adapter.reads + r.controller.fallbackCount, 0);
        await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
        await flush();
        same(before + ' basic: no manual read', r.pasteboard.reads, 0);
        // 重新同意隐私政策
        r.consent = ClipboardReadPolicy.CONSENT_AGREED;
        r.controller.sync();
        await r.toBackgroundAndBack();
        const on: boolean = before !== 'off';
        same(before + ' re-agree display', r.controller.autoReadDisplayOn(), on);
        same(before + ' re-agree reads', r.adapter.reads, on ? 1 : 0);
        same(before + ' no consent report', r.consents().length, 0);
      }
      // 登录 / 退出 / 换号不改（设备级）
      const s: ImportRig = new ImportRig();
      s.controller.toggleAutoRead(false);
      s.controller.sync();
      s.rig.client.invalidate();
      s.controller.sync();
      same('session change keeps device-level off', s.controller.autoReadDisplayOn(), false);
    });

    it('environment_switch_clears_local_switch_back_to_default_on_D8', 0, async () => {
      const r: ImportRig = new ImportRig();
      r.controller.toggleAutoRead(false);
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      r.controller.installCleaner(registry);
      await registry.cleanAll();
      same('env switch → default on', r.controller.autoReadDisplayOn(), true);
      same('env switch salt / hash cleanup still runs', r.controller.recordsClearPending, false);
    });

    // ---------------------------------------------------------------- C8 设置开关
    it('settings_switch_default_on_off_and_on_take_effect_directly_without_notice_C8', 0, async () => {
      const r: ImportRig = new ImportRig().eligible();
      let changed: number = 0;
      r.controller.onAutoReadChanged = (): void => {
        changed++;
      };
      same('display on by default', r.controller.autoReadDisplayOn(), true);
      same('toggle off', r.controller.toggleAutoRead(false), ClipboardAutoSwitch.OFF);
      same('display off', r.controller.autoReadDisplayOn(), false);
      same('subscribers told', changed > 0, true);
      await r.start();
      same('off → no read', r.adapter.reads, 0);
      same('toggle on directly', r.controller.toggleAutoRead(true), ClipboardAutoSwitch.ON);
      same('display on', r.controller.autoReadDisplayOn(), true);
      await r.toBackgroundAndBack();
      same('on → next round reads', r.adapter.reads, 1);
      same('no consent posted', r.consents().length, 0);
      // 不具备资格时显示也不变（D7）
      const n: ImportRig = new ImportRig();
      same('display on while not eligible', n.controller.autoReadDisplayOn(), true);
    });

    it('default_wiring_without_injected_store_defaults_on_in_memory', 0, async () => {
      const r: ImportRig = new ImportRig(new FakeImportBackend(), false);
      same('default store: display on', r.controller.autoReadDisplayOn(), true);
      same('default store: off', r.controller.toggleAutoRead(false), ClipboardAutoSwitch.OFF);
      same('default store: display off', r.controller.autoReadDisplayOn(), false);
      same('injected backend untouched', r.backend.writes, 0);
    });

    it('settings_off_write_failure_is_off_in_memory_and_restart_reads_disk_mirror_C5_G42', 0, async () => {
      const backend: FakeImportBackend = new FakeImportBackend();
      const r: ImportRig = new ImportRig(backend);
      r.eligible();
      backend.failWrites = true;
      same('off despite write failure', r.controller.toggleAutoRead(false), ClipboardAutoSwitch.OFF);
      same('display off in memory', r.controller.autoReadDisplayOn(), false);
      await r.start();
      same('no read while off in memory', r.adapter.reads, 0);
      backend.failWrites = false;
      await r.toBackgroundAndBack();
      // 回前台补写成功后，重启读磁盘镜像仍关
      const restarted: ImportRig = new ImportRig(backend.reopen());
      same('restart sees off', restarted.controller.autoReadDisplayOn(), false);
    });

    // ---------------------------------------------------------------- 普通互斥模态（review-harmony-r1 S1-1，测试 v3 改写）
    // 生产里更新提示（AppUpdate showPrompt 且 BELOW_RECOMMENDED）与权限说明（PermissionPromptModel.visible）由 AppClipboard 订阅，显示状态每次
    // 变化都调执行层 modalChanged()；执行层按 deps.modal()（= AppClipboard.modal()）判定。2026-10-30 起没有半屏可让位，模态在时自动任务等待
    // （门控 WAIT），模态收起后经 modalChanged() 同一轮再试一次。entry 侧的订阅由宿主检查 W9 守。
    it('auto_task_waits_under_update_prompt_or_permission_prompt_and_runs_same_round_after_modal_closes_S1_1', 0, async () => {
      for (const modal of ['update_prompt', 'other_dialog']) {
        const r: ImportRig = new ImportRig().eligible();
        r.modal = modal;
        await r.start();
        same(modal + ' waits', r.adapter.reads, 0);
        r.controller.modalChanged();
        r.controller.windowFocus(true);
        r.controller.pageShown(r.homePage);
        await flush();
        same(modal + ' still waits while showing', r.adapter.reads, 0);
        r.modal = 'none';
        r.controller.modalChanged();
        await flush();
        same(modal + ' same round runs after close', r.adapter.reads, 1);
        r.controller.modalChanged();
        await flush();
        same(modal + ' once per round', r.adapter.reads, 1);
        same(modal + ' no consent report', r.consents().length, 0);
      }
    });
  });
}
