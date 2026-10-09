// APP-09 鸿蒙钱包、提现、提现记录、实名、收款账号、劳务协议与二次验证的本地假服务集成测试（brief §2.16）：真实 ApiClient（签名、幂等、
// 未决键、step-up 头全走网络层真实管线）+ 本地假服务（NetworkTestRig.FakeServer，不连任何地址、不做真实提现）+ 真实 Router / StackNavigator
// （页面入口经 Router 打开，断言导航栈与参数值）+ 执行层的页面入口（钱包加载、提现页显示 / 输入 / 档位 / 提交 / 确认 / 放弃、二次验证面板、
// 收款账号保存、实名与签署、提现记录展开与复制）。假数据照 design-hifi sample-data §12（本机用户 138****5678 / **三；样例身份证号与卡号是
// 明显的测试值，不打印完整身份信息）。测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  AmountMaskStore, ApiClientWalletPort, ApiOutcome, ApiResult, ClipboardController, ClipboardWriteLedger,
  ClipboardWriter, GuardState, LaborAgreementController, LaunchReadiness, MemoryAmountMaskBackend,
  MemoryClipboardHashStore, MemoryOrderCacheStore, MemoryPendingBackend, PasteboardPort, PayoutAccountController,
  PayoutPhase, PendingActionStore, PrivacyState, RealNameController, RecordsPhase, RouteDestination, RouteRequest,
  RouteSource, Router, RouteTable, SessionTokenSet, StackNavigator, StepUpController, TransportFailure,
  TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState, WalletCacheCleaner, WalletContractPort,
  WalletController, WalletDeps, WalletDraftTexts, WalletPhase, WalletRecord, WalletSession, WalletStaleCache,
  WalletSummaryView, WithdrawController, WithdrawPhase, WithdrawRecordsController, LocalDataCleanerRegistry,
  CleanReport, WithdrawRecordsGrouping, PayoutAccountForm, WalletMessage, PendingView
} from '../../Index';
import { RouteSpec } from 'generated';
import { Deferred, envelope, flush, header, Rig } from './NetworkTestRig';
import { ParamStack, TAB_ROOTS } from './OrderIntegration.test';

export const NOW: number = Date.parse('2026-10-12T10:30:00+08:00');
export const TEST_PHONE: string = '13800005678';

export function summaryJson(over: string = ''): string {
  const base: Record<string, Object | null> = {};
  base['available_fen'] = 1000;
  base['withdrawable_fen'] = 1000;
  base['negative_fen'] = 0;
  base['frozen_fen'] = 200;
  base['estimated_total_fen'] = 1019;
  base['estimated_fen'] = 269;
  base['pending_credit_fen'] = 750;
  base['pending_credit_paused_fen'] = 450;
  base['next_credit_period'] = '2026-11';
  base['credit_overdue'] = false;
  base['withdrawn_fen'] = 0;
  base['risk_paused_reason'] = null;
  base['withdraw_enabled'] = true;
  if (over.length > 0) {
    const o: Record<string, Object | null> = JSON.parse(over) as Record<string, Object | null>;
    for (const k of Object.keys(o)) {
      base[k] = o[k];
    }
  }
  return JSON.stringify(base);
}

export function rulesJson(amount: number | null, over: string = ''): string {
  const r: Record<string, Object | null> = {};
  r['can_withdraw'] = true;
  r['block_code'] = null;
  r['block_reason'] = null;
  r['max_withdrawable_fen'] = 1200;
  r['withdrawable_fen'] = 1234;
  r['daily_remaining'] = 1;
  r['monthly_remaining'] = 10;
  r['est_fee_fen'] = amount === null ? null : 0;
  r['est_tax_fen'] = amount === null ? null : 0;
  r['est_net_fen'] = amount;
  r['quick_amounts_fen'] = [500, 1000];
  if (over.length > 0) {
    const o: Record<string, Object | null> = JSON.parse(over) as Record<string, Object | null>;
    for (const k of Object.keys(o)) {
      r[k] = o[k];
    }
  }
  return JSON.stringify(r);
}

export function withdrawal(id: string, status: string, amount: number, created: string, extra: string = ''): string {
  return '{"withdrawal_id":"' + id + '","status":"' + status + '","review_mode":"manual","amount_fen":' + amount
    + ',"fee_fen":0,"tax_fen":0,"net_fen":' + amount + ',"payout_channel":"alipay","payout_channel_name":"支付宝",'
    + '"masked_account":"138****5678","reason_code":null,"fail_action":null,"created_at":"' + created + '"' + extra + '}';
}

export const ALIPAY: string = '{"payout_method":"alipay","masked_account":"138****5678","masked_payee_name":"**三",'
  + '"change_remaining_this_month":2}';

export function pathOf(r: TransportRequest): string {
  const u: string = r.url.split('?')[0];
  return u.substring(u.indexOf('/v1/'));
}

export function queryOfReq(r: TransportRequest): string {
  return queryOf(r);
}

function queryOf(r: TransportRequest): string {
  const i: number = r.url.indexOf('?');
  return i < 0 ? '' : r.url.substring(i + 1);
}

class FakeBoard implements PasteboardPort {
  text: string | null = null;
  writes: number = 0;

  readText(): Promise<string | null> {
    return Promise.resolve(this.text);
  }

  writeText(text: string): Promise<boolean> {
    this.writes++;
    this.text = text;
    return Promise.resolve(true);
  }
}

class FailingHashStore extends MemoryClipboardHashStore {
  write(_key: string, _value: string | null): boolean {
    return false;
  }
}

/** 实名与劳务协议待定接口（G01、G02）的测试替身（只在测试与 Debug 假服务里有）。 */
class FakeContract implements WalletContractPort {
  realnameCode: number = 0;
  realnameCalls: number = 0;
  signCalls: number = 0;
  signedVersion: string = '';
  signedSha: string = '';

  private result(code: number, data: Record<string, Object>): Promise<ApiResult> {
    return Promise.resolve(new ApiResult(code === 0 ? ApiOutcome.SUCCESS : ApiOutcome.BUSINESS_ERROR, code, '', data,
      'trace-wallet-abc123', code === 0 ? 200 : 400, TransportFailure.NONE, null, null, null));
  }

  submitRealname(_name: string, _idNo: string): Promise<ApiResult> {
    this.realnameCalls++;
    return this.result(this.realnameCode, {});
  }

  getLaborAgreement(): Promise<ApiResult> {
    const d: Record<string, Object> = {};
    d['version'] = 'v1';
    d['text'] = 'fixture agreement text';
    d['text_sha256'] = 'fixture-sha';
    d['need_sign'] = true;
    return this.result(0, d);
  }

  signLaborAgreement(version: string, sha: string): Promise<ApiResult> {
    this.signCalls++;
    this.signedVersion = version;
    this.signedSha = sha;
    return this.result(0, {});
  }
}

type Reply = (r: TransportRequest) => TransportResponse | null;

/** 钱包执行层 + 真实 Router 的装配（与 entry AppWallet 同一接线）。 */
export class WalletFixture {
  readonly rig: Rig = new Rig();
  readonly stack: ParamStack = new ParamStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
  readonly cache: WalletStaleCache;
  readonly session: WalletSession;
  readonly board: FakeBoard = new FakeBoard();
  readonly ledger: ClipboardWriteLedger = new ClipboardWriteLedger(ClipboardWriteLedger.DEFAULT_CAPACITY,
    (t: string): string => 'h:' + t, new MemoryClipboardHashStore());
  writer: ClipboardWriter;
  nowMs: number = NOW;
  forced: number = 0;
  cs: number = 0;
  phone: string | null = TEST_PHONE;
  contract: WalletContractPort | null = null;
  dropped: string[] = [];
  held: Deferred[] = [];
  replies: Map<string, Reply> = new Map<string, Reply>();

  constructor() {
    this.cache = new WalletStaleCache(this.store, (): string | null => this.rig.client.sessionAccount(),
      (): number => this.nowMs);
    this.session = new WalletSession((): number => this.nowMs, (): string => this.scope());
    this.session.removePages = (route: string): void => this.navigator.remove(route);
    this.writer = new ClipboardWriter(this.board, this.ledger);
    this.rig.nowMillis = NOW;
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => d.route !== null
      && TAB_ROOTS.indexOf(d.route) >= 0;
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => this.nowMs),
      (): GuardState => new GuardState('consented', 'ok', 'phone_bound', true, '1.0.0', false, false, true),
      this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
    this.router.onParamsDropped = (route: string, n: number): void => {
      this.dropped.push(route + ':' + n);
    };
    this.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson()));
    this.reply('/v1/withdrawals/rules', (r: TransportRequest) => {
      const q: string = queryOf(r);
      const amount: number | null = q.indexOf('amount_fen=') >= 0
        ? Number.parseInt(q.substring(q.indexOf('amount_fen=') + 11), 10) : null;
      return envelope(0, rulesJson(amount));
    });
    this.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, ALIPAY));
    this.reply('/v1/me', (_r: TransportRequest) => envelope(0, '{"realname_status":"verified"}'));
    this.reply('/v1/auth/sms-codes', (_r: TransportRequest) => envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
    this.reply('/v1/auth/step-up', (r: TransportRequest) => (r.body ?? '').indexOf('"123456"') >= 0
      ? envelope(0, '{"step_up_token":"fixture-step-token","expire_at":"2026-10-12T10:35:00+08:00"}')
      : envelope(20002, '{}'));
    this.reply('POST /v1/withdrawals', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
      ? envelope(10003, '{}') : envelope(0, withdrawal('W1', 'PENDING_REVIEW', 1000, '2026-10-12T10:30:00+08:00',
        ',"channel_order_id":null')));
    this.reply('/v1/withdrawals', (_r: TransportRequest) => envelope(0, '{"items":[' + [
      withdrawal('W3', 'FAILED', 800, '2026-10-08T11:30:00+08:00').replace('"fail_action":null',
        '"fail_action":"change_payout_account"'),
      withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00')
    ].join(',') + '],"next_cursor":null}'));
    this.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      const path: string = pathOf(r);
      const reply: Reply | undefined = this.replies.get(r.method + ' ' + path) ?? this.replies.get(path)
        ?? (path.startsWith('/v1/withdrawals/') ? this.replies.get('/v1/withdrawals/:id') : undefined);
      const res: TransportResponse | null = reply === undefined ? envelope(0, '{}') : reply(r);
      if (res !== null) {
        return Promise.resolve(res);
      }
      const d: Deferred = new Deferred();
      this.held.push(d);
      return d.promise;
    };
  }

  reply(key: string, r: Reply): void {
    this.replies.set(key, r);
  }

  scope(): string {
    return ClipboardController.scopeKey(this.rig.client.captureScope());
  }

  deps(): WalletDeps {
    const d: WalletDeps = new WalletDeps(new ApiClientWalletPort(this.rig.client), this.session);
    d.clock = (): number => this.nowMs;
    d.scope = (): string => this.scope();
    d.account = (): string | null => this.rig.client.sessionAccount();
    d.cache = this.cache;
    d.contract = this.contract;
    d.open = (route: string, params: Record<string, Object>): void => {
      this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
    };
    d.replaceTop = (route: string, params: Record<string, Object>): void => {
      this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
      this.navigator.remove('Withdraw');
    };
    d.forceUpdate = (): void => {
      this.forced++;
    };
    d.customerService = (): void => {
      this.cs++;
      this.router.open(RouteRequest.of('Help', RouteSource.IN_APP));
    };
    d.stepUpPhone = (_a: string): string | null => this.phone;
    d.copyText = (t: string): Promise<boolean> => this.writer.write(t);
    return d;
  }

  count(key: string): number {
    const parts: string[] = key.split(' ');
    const method: string | null = parts.length > 1 ? parts[0] : null;
    const path: string = parts.length > 1 ? parts[1] : parts[0];
    return this.rig.server.received.filter((r: TransportRequest): boolean => pathOf(r) === path
      && (method === null || r.method === method)).length;
  }

  last(key: string): TransportRequest {
    const parts: string[] = key.split(' ');
    const list: TransportRequest[] = this.rig.server.received.filter((r: TransportRequest): boolean =>
    pathOf(r) === parts[parts.length - 1] && (parts.length === 1 || r.method === parts[0]));
    return list[list.length - 1];
  }

  /** 换账号（登录 B）：ApiClient 会话换代，钱包会话同步。 */
  switchAccount(account: string): void {
    this.rig.tokens.save(new SessionTokenSet('access-' + account, 'refresh-' + account, 'full', account));
    this.rig.client.onSessionChanged();
    this.session.sync();
  }
}

export async function settle(): Promise<void> {
  for (let i: number = 0; i < 4; i++) {
    await flush();
  }
}

export function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/** 打开提现页并完成首轮 rules / 收款账号读取。 */
export async function openWithdraw(f: WalletFixture): Promise<WithdrawController> {
  f.session.sync();
  const c: WithdrawController = new WithdrawController(f.deps());
  c.onShown();
  await settle();
  return c;
}

/** 走完二次验证（发码 → 输入 123456 → 验证），返回面板执行器。 */
export async function passStepUp(c: WithdrawController | PayoutAccountController): Promise<StepUpController> {
  const s: StepUpController = c.createStepUp() as StepUpController;
  s.send();
  await settle();
  s.setCode('123456');
  s.verify();
  await settle();
  return s;
}

export default function walletIntegrationTest() {
  describe('WalletIntegration', () => {
    // ---------------------------------------------------------------- 钱包（AC-S2-33、TECH-20）
    it('AC_S2_33_wallet_main_values_and_three_progress_items', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      const v: WalletRecord = WalletSummaryView.of(w.snapshot.summary as WalletRecord, false, NOW);
      expect(((v['hero'] as WalletRecord)['fen'] as number)).assertEqual(1000);
      expect(((v['frozen'] as WalletRecord)['fen'] as number)).assertEqual(200);
      expect(((v['estimated'] as WalletRecord)['fen'] as number)).assertEqual(1019);
      expect(((v['receivedLine'] as WalletRecord)['fen'] as number)).assertEqual(750);
      expect(((v['pausedLine'] as WalletRecord)['fen'] as number)).assertEqual(450);
      expect(w.withdrawAllowed).assertTrue();
      // 服务端合计不等于分项之和时照用服务端（改 estimated_fen 不影响「预估收益」）
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson('{"estimated_fen":1,"pending_credit_fen":2}')));
      w.refresh();
      await settle();
      const v2: WalletRecord = WalletSummaryView.of(w.snapshot.summary as WalletRecord, false, NOW);
      expect(((v2['estimated'] as WalletRecord)['fen'] as number)).assertEqual(1019);
      // 用户可见文案不出现「待入账」「累计」
      for (const t of WalletDraftTexts.allTexts()) {
        expect(t.indexOf('待入账') < 0 && t.indexOf('累计') < 0).assertTrue();
      }
      // 进入钱包时顺带取实名状态（Router 守卫用）
      expect(f.session.realname.verified('user-1')).assertTrue();
    });

    it('AC_S2_33_abc_withdraw_button_disabled', 0, async () => {
      // G11 更正：风控冻结不置灰（另见 WalletReviewR1 的 lesson22 用例）
      const cases: string[] = ['{"negative_fen":200,"withdrawable_fen":0}', '{"withdraw_enabled":false}'];
      for (const over of cases) {
        const f: WalletFixture = new WalletFixture();
        f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson(over)));
        f.session.sync();
        const w: WalletController = new WalletController(f.deps());
        w.load();
        await settle();
        expect(w.withdrawAllowed).assertFalse();
      }
    });

    it('TECH_20_stale_cache_transport_only_and_cleared_on_account_switch', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(f.store.files.size).assertEqual(1);
      // 断网：显示缓存（WalletStale），【提现】置灰
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      const w2: WalletController = new WalletController(f.deps());
      w2.load();
      await settle();
      expect(w2.snapshot.stale).assertTrue();
      expect(w2.snapshot.staleFetchedAt).assertEqual(NOW);
      expect(w2.withdrawAllowed).assertFalse();
      // 下拉成功后提示条消失
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson()));
      w2.refresh();
      await settle();
      expect(w2.snapshot.stale).assertFalse();
      // 5xxxx 不用缓存，带 trace6
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(50001, '{}'));
      const w3: WalletController = new WalletController(f.deps());
      w3.load();
      await settle();
      expect(w3.snapshot.stale).assertFalse();
      expect(w3.snapshot.phase).assertEqual(WalletPhase.ERROR);
      expect((w3.snapshot.error as WalletMessage).text).assertContain('123456');
      // 换账号：缓存删除（AppWallet.sync 同口径）
      expect(f.cache.clear()).assertTrue();
      expect(f.store.files.size).assertEqual(0);
      // 删除失败：保留待清理标记，清理完成前不读回旧数据
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson()));
      w.refresh();
      await settle();
      expect(f.store.files.size).assertEqual(1);
      f.store.failClear = true;
      expect(f.cache.clear()).assertFalse();
      expect(f.cache.load()).assertNull();
      f.store.failClear = false;
      expect(f.cache.retryPendingClear()).assertTrue();
      expect(f.store.files.size).assertEqual(0);
    });

    it('TECH_20_consent_withdrawal_cleaner_clears_cache_and_resets_pages', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      let resets: number = 0;
      WalletCacheCleaner.install(registry, f.cache, (): void => {
        resets++;
        f.session.reset();
      });
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(f.store.files.size).assertEqual(1);
      const report: CleanReport = await registry.cleanOnly([]);
      expect(report.cleaned.indexOf(WalletStaleCache.CLEANER_NAME) >= 0).assertTrue();
      expect(resets).assertEqual(1);
      expect(f.store.files.size).assertEqual(0);
      expect(w.snapshot.summary).assertNull();
      f.store.failClear = true;
      const failed: CleanReport = await registry.cleanOnly([]);
      expect(failed.ok).assertFalse();
    });

    it('wallet_42901_blocks_refresh_at_execution_layer', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '30' }));
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(f.session.readGate.active).assertTrue();
      expect(w.refresh()).assertFalse();
      expect(w.retry()).assertFalse();
      const before: number = f.count('/v1/wallet/summary');
      // 别的钱包读请求（提现页 rules）在执行层同样被拦（共享闸门）
      const c: WithdrawController = await openWithdraw(f);
      expect(f.count('/v1/withdrawals/rules')).assertEqual(0);
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.ERROR);
      expect(f.count('/v1/wallet/summary')).assertEqual(before);
    });

    // ---------------------------------------------------------------- 提现页（AC-S2-80）
    it('AC_S2_80_header_quick_all_and_estimate', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.EDITING);
      expect(c.snapshot.payoutLine).assertEqual('支付宝 138****5678');
      const v: WalletRecord = c.view() as WalletRecord;
      expect(((v['maxLine'] as WalletRecord)['fen'] as number)).assertEqual(1200);
      expect(c.fillAll(c.snapshot.version)).assertTrue();
      expect(c.snapshot.inputText).assertEqual('12');
      await settle();
      expect(queryOf(f.last('/v1/withdrawals/rules'))).assertEqual('amount_fen=1200');
      expect(((c.snapshot.estimate as WalletRecord)['net'] as number)).assertEqual(1200);
      expect((c.snapshot.estimate as WalletRecord)['key'] as string).assertEqual('withdraw.estimate.net_only');
      // 档位只认 rules 下发的
      expect(c.fillQuick(700, c.snapshot.version)).assertFalse();
      expect(c.fillQuick(500, c.snapshot.version)).assertTrue();
      expect(c.snapshot.inputText).assertEqual('5');
      expect(c.canSubmit).assertTrue();
    });

    it('AC_S2_80_10_late_estimate_not_applied_and_header_not_overwritten', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => null);
      c.fillQuick(1000, c.snapshot.version);
      c.fillQuick(500, c.snapshot.version);
      await settle();
      expect(f.held.length).assertEqual(2);
      // 新的（¥5）先回，旧的（¥10）后回：只显示 ¥5 的估算；旧序号不覆盖页头
      f.held[1].resolve(envelope(0, rulesJson(500, '{"daily_remaining":1}')));
      await settle();
      f.held[0].resolve(envelope(0, rulesJson(1000, '{"daily_remaining":0}')));
      await settle();
      expect(((c.snapshot.estimate as WalletRecord)['net'] as number)).assertEqual(500);
      expect((((c.view() as WalletRecord)['remaining'] as WalletRecord)['daily'] as number)).assertEqual(1);
    });

    it('AC_S2_80_11_12_clear_and_leave_drop_late_estimate', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => null);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      const sent: number = f.count('/v1/withdrawals/rules');
      expect(c.setInput('')).assertTrue();
      expect(c.snapshot.estimate as string).assertEqual('hidden');
      expect(f.count('/v1/withdrawals/rules')).assertEqual(sent);
      f.held[0].resolve(envelope(0, rulesJson(1000)));
      await settle();
      expect(c.snapshot.estimate as string).assertEqual('hidden');
      // 离开页面：在途请求作废（同步出口），迟到不改页面；重新进入是新实例
      c.fillQuick(500, c.snapshot.version);
      await settle();
      c.leave();
      expect(f.rig.server.cancelled.length > 0).assertTrue();
      await settle();
      expect(c.snapshot.estimate as string).assertEqual('calculating');
      const c2: WithdrawController = new WithdrawController(f.deps());
      expect(c2.snapshot.pageInstance !== c.snapshot.pageInstance).assertTrue();
      expect(c2.snapshot.inputText).assertEqual('');
    });

    it('G18_debounced_estimate_after_pause', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      const sent: number = f.count('/v1/withdrawals/rules');
      expect(c.setInput('10')).assertTrue();
      expect(c.snapshot.estimate as string).assertEqual('calculating');
      expect(c.setInput('10.555')).assertFalse();
      expect(c.snapshot.inputText).assertEqual('10');
      expect(f.count('/v1/withdrawals/rules')).assertEqual(sent);
      await sleep(650);
      await settle();
      expect(f.count('/v1/withdrawals/rules')).assertEqual(sent + 1);
      expect(((c.snapshot.estimate as WalletRecord)['net'] as number)).assertEqual(1000);
    });

    // ---------------------------------------------------------------- 提交、二次验证、成功（AC-S2-62、G19）
    it('AC_S2_62_submit_step_up_same_key_then_records_replaces_withdraw', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.router.open(RouteRequest.of('Wallet', RouteSource.IN_APP));
      f.router.open(RouteRequest.of('Withdraw', RouteSource.IN_APP));
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
      expect(f.count('POST /v1/withdrawals')).assertEqual(1);
      const firstKey: string | undefined = header(f.last('POST /v1/withdrawals'), 'Idempotency-Key');
      expect(firstKey !== undefined).assertTrue();
      const s: StepUpController = await passStepUp(c);
      // 发码：本机号码、purpose=step_up、action=withdraw
      const sms: Record<string, Object> = JSON.parse(f.last('/v1/auth/sms-codes').body ?? '{}') as Record<string, Object>;
      expect(sms['purpose'] as string).assertEqual('step_up');
      expect(sms['action'] as string).assertEqual('withdraw');
      expect(sms['phone'] as string).assertEqual(TEST_PHONE);
      expect(s.open).assertFalse();
      // 拿到 token 后沿用原键重放 1 次，带 X-Step-Up-Token，不进请求体
      expect(f.count('POST /v1/withdrawals')).assertEqual(2);
      const replay: TransportRequest = f.last('POST /v1/withdrawals');
      expect(header(replay, 'Idempotency-Key') as string).assertEqual(firstKey as string);
      expect(header(replay, 'X-Step-Up-Token') as string).assertEqual('fixture-step-token');
      expect(replay.body as string).assertEqual('{"amount_fen":1000}');
      // 成功：WithdrawRecords {withdrawal_id} 替换 Withdraw，钱包标记刷新
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.DONE);
      expect(JSON.stringify(f.stack.names)).assertEqual('["Wallet","WithdrawRecords"]');
      expect(f.stack.topParams()['withdrawal_id'] as string).assertEqual('W1');
      expect(f.session.walletNeedsRefresh).assertTrue();
      // token 已核销：再提交不复用
      expect(f.session.tokens.take('withdraw', 'user-1', NOW)).assertNull();
      expect(f.rig.client.pendingFor('createWithdrawal')).assertNull();
    });

    it('step_up_no_phone_wrong_code_and_separate_gates', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      // G31：取不到本账号号码时不发码
      f.phone = null;
      const s0: StepUpController = c.createStepUp() as StepUpController;
      expect(s0.send()).assertFalse();
      expect(s0.snapshot.noPhone).assertTrue();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(0);
      s0.close();
      f.phone = TEST_PHONE;
      // 20002：清空并提示；42901 发码与验证分开限流
      f.reply('/v1/auth/sms-codes', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '60' }));
      const s: StepUpController = c.createStepUp() as StepUpController;
      s.send();
      await settle();
      expect(f.session.smsGate.active).assertTrue();
      expect(f.session.verifyGate.active).assertFalse();
      s.setCode('654321');
      s.verify();
      await settle();
      expect(s.snapshot.code).assertEqual('');
      expect(s.snapshot.clearSeq).assertEqual(1);
      expect((s.snapshot.error as WalletMessage).textKey).assertEqual('error.20002');
      // 关闭面板：回到 editing，本次键不再使用（从未结果未知，下次新键）
      s.close();
      c.stepUpClosed();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.EDITING);
      expect(f.rig.client.pendingFor('createWithdrawal')).assertNull();
    });

    // ---------------------------------------------------------------- 结果未知与待确认（AC-S2-62 ⑦–⑳）
    it('AC_S2_62_unknown_result_pending_survives_reentry_midnight_and_24h', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.TIMEOUT));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
      expect((c.snapshot.pending as PendingView).amountFen as number).assertEqual(1000);
      expect(c.canSubmit).assertFalse();
      expect(f.count('POST /v1/withdrawals')).assertEqual(1);
      // 不自动重发；跨午夜、超过 24 小时不解除；重新进入仍是待确认
      f.rig.nowMillis = NOW + 25 * 3600 * 1000;
      f.nowMs = f.rig.nowMillis;
      const c2: WithdrawController = await openWithdraw(f);
      expect(c2.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
      expect(f.count('POST /v1/withdrawals')).assertEqual(1);
      // 确认：原键、原请求体重发
      const key: string = (c2.snapshot.pending as PendingView).key;
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(0, withdrawal('W9', 'PENDING_REVIEW', 1000,
        '2026-10-12T10:30:00+08:00', ',"channel_order_id":null')));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', f.nowMs + 300000);
      expect(c2.confirm(c2.snapshot.pendingVersion)).assertTrue();
      expect(c2.snapshot.pendingBusy).assertTrue();
      expect(c2.abandon(c2.snapshot.pendingVersion)).assertFalse();
      await settle();
      const resend: TransportRequest = f.last('POST /v1/withdrawals');
      expect(header(resend, 'Idempotency-Key') as string).assertEqual(key);
      expect(resend.body as string).assertEqual('{"amount_fen":1000}');
      expect(c2.snapshot.phase).assertEqual(WithdrawPhase.DONE);
      expect(f.rig.client.pendingFor('createWithdrawal')).assertNull();
    });

    it('AC_S2_62_confirm_outcomes_3xxxx_ends_2xxxx_keeps_42901_gates', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
      // 20901：按上一次的内容暂时确认不了，键不结束
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(20901, '{}'));
      c.confirm(c.snapshot.pendingVersion);
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
      expect((c.snapshot.banner as WalletMessage).textKey)
        .assertEqual('pending_confirm.cannot_confirm');
      // 42901：保持待确认、retry_later；提交 / 确认 / 放弃共用截止时间，在执行层拦截
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '20' }));
      c.confirm(c.snapshot.pendingVersion);
      await settle();
      expect(f.session.withdrawGate.active).assertTrue();
      expect((c.snapshot.banner as WalletMessage).textKey)
        .assertEqual('pending_confirm.retry_later');
      const sent: number = f.count('POST /v1/withdrawals');
      expect(c.confirm(c.snapshot.pendingVersion)).assertFalse();
      expect(c.abandon(c.snapshot.pendingVersion)).assertFalse();
      const direct = await c.flow.abandon((c.snapshot.pending as PendingView).key);
      expect(direct.action).assertEqual('pending_confirm');
      expect(direct.textKey as string).assertEqual('pending_confirm.retry_later');
      expect(f.count('/v1/idempotency-keys/abandon')).assertEqual(0);
      expect(f.count('POST /v1/withdrawals')).assertEqual(sent);
      // 闸门过期后：30301 结束键，恢复【提交】
      f.nowMs += 21000;
      f.rig.nowMillis = f.nowMs;
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(30301, '{}'));
      c.confirm(c.snapshot.pendingVersion);
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.EDITING);
      expect(f.rig.client.pendingFor('createWithdrawal')).assertNull();
      expect((c.snapshot.banner as WalletMessage).textKey).assertEqual('error.30301');
    });

    it('AC_S2_62_abandon_abandoned_busy_and_completed', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.router.open(RouteRequest.of('Withdraw', RouteSource.IN_APP));
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      // 40901：上一次提交正在处理，保持待确认
      f.reply('/v1/idempotency-keys/abandon', (_r: TransportRequest) => envelope(40901, '{}'));
      c.abandon(c.snapshot.pendingVersion);
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
      expect((c.snapshot.banner as WalletMessage).textKey)
        .assertEqual('pending_confirm.abandon_busy');
      const body: Record<string, Object> = JSON.parse(f.last('/v1/idempotency-keys/abandon').body ?? '{}') as
      Record<string, Object>;
      expect(body['action'] as string).assertEqual('withdraw');
      expect(header(f.last('/v1/idempotency-keys/abandon'), 'Idempotency-Key')).assertUndefined();
      // completed + 原结果成功：已处理完成，按成功进入记录页
      f.reply('/v1/idempotency-keys/abandon', (_r: TransportRequest) => envelope(0,
        '{"outcome":"completed","original":{"code":0,"msg":"","data":' + withdrawal('W7', 'PENDING_REVIEW', 1000,
          '2026-10-12T10:30:00+08:00', ',"channel_order_id":null') + '}}'));
      c.abandon(c.snapshot.pendingVersion);
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.DONE);
      expect(f.stack.topParams()['withdrawal_id'] as string).assertEqual('W7');
      expect((c.snapshot.notice as WalletMessage).textKey)
        .assertEqual('pending_confirm.already_done');
    });

    it('AC_S2_62_abandon_abandoned_restores_form', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      f.reply('/v1/idempotency-keys/abandon', (_r: TransportRequest) => envelope(0, '{"outcome":"abandoned","original":null}'));
      c.abandon(c.snapshot.pendingVersion);
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.EDITING);
      expect(c.snapshot.pending).assertNull();
      expect((c.snapshot.notice as WalletMessage).textKey)
        .assertEqual('pending_confirm.abandoned');
      expect(c.canSubmit).assertTrue();
      // 再提交用新键
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(30301, '{}'));
      const oldKey: string | undefined = header(f.rig.server.received.filter((r: TransportRequest) =>
      pathOf(r) === '/v1/withdrawals' && r.method === 'POST')[0], 'Idempotency-Key');
      c.submit();
      await settle();
      expect(header(f.last('POST /v1/withdrawals'), 'Idempotency-Key') !== oldKey).assertTrue();
    });

    it('AC_S2_62_account_switch_hides_and_restores_pending', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.router.open(RouteRequest.of('Withdraw', RouteSource.IN_APP));
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
      // A 会话失效 → 登录 B：旧页面清空并移出导航栈，B 看不到 A 的待确认与金额，也不发 A 的键
      f.switchAccount('user-2');
      expect(c.snapshot.inputText).assertEqual('');
      expect(c.snapshot.pending).assertNull();
      expect(f.stack.names.indexOf('Withdraw')).assertEqual(-1);
      expect(f.session.tokens.size).assertEqual(0);
      const b: WithdrawController = await openWithdraw(f);
      expect(b.snapshot.pending).assertNull();
      expect(b.snapshot.phase).assertEqual(WithdrawPhase.EDITING);
      const sent: number = f.count('POST /v1/withdrawals');
      expect(b.confirm(b.snapshot.pendingVersion)).assertFalse();
      expect(f.count('POST /v1/withdrawals')).assertEqual(sent);
      // 原账号再登录：恢复待确认
      f.switchAccount('user-1');
      const a: WithdrawController = await openWithdraw(f);
      expect(a.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
    });

    it('AC_S2_62_10405_keeps_pending_and_forces_update', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(10405, '{"min_supported_version":"9.0.0"}'));
      c.confirm(c.snapshot.pendingVersion);
      await settle();
      expect(f.forced).assertEqual(1);
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
      expect(f.rig.client.pendingFor('createWithdrawal') !== null).assertTrue();
    });

    // ---------------------------------------------------------------- 前置补办与回流（AC-S2-21、AC-S2-55、AC-S2-62 ①–⑥）
    it('AC_S2_62_prereq_30305_opens_payout_no_replay_new_key_after', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(30305, '{}'));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.router.open(RouteRequest.of('Withdraw', RouteSource.IN_APP));
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(500, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('PayoutAccount');
      expect(c.snapshot.inputText).assertEqual('5');
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.EDITING);
      const firstKey: string | undefined = header(f.last('POST /v1/withdrawals'), 'Idempotency-Key');
      // 回到发起页：重取 rules，不自动提交
      const before: number = f.count('POST /v1/withdrawals');
      c.onShown();
      await settle();
      expect(f.count('POST /v1/withdrawals')).assertEqual(before);
      expect(queryOf(f.last('/v1/withdrawals/rules'))).assertEqual('amount_fen=500');
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(0, withdrawal('W2', 'PENDING_REVIEW', 500,
        '2026-10-12T10:30:00+08:00', ',"channel_order_id":null')));
      c.submit();
      await settle();
      expect(header(f.last('POST /v1/withdrawals'), 'Idempotency-Key') !== firstKey).assertTrue();
    });

    it('AC_S2_55_labor_block_guide_sign_returns_without_submit', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const contract: FakeContract = new FakeContract();
      f.contract = contract;
      let signed: boolean = false;
      f.reply('/v1/withdrawals/rules', (r: TransportRequest) => signed ? envelope(0, rulesJson(null))
        : envelope(0, rulesJson(null, '{"can_withdraw":false,"block_code":10004,"max_withdrawable_fen":0,"quick_amounts_fen":[]}')));
      f.router.open(RouteRequest.of('Withdraw', RouteSource.IN_APP));
      const c: WithdrawController = await openWithdraw(f);
      expect(c.setInput('5')).assertTrue();
      expect(c.canSubmit).assertFalse();
      expect(c.guide()?.['route'] as string).assertEqual('LaborAgreement');
      expect(c.openGuide(c.snapshot.version)).assertTrue();
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('LaborAgreement');
      const l: LaborAgreementController = new LaborAgreementController(f.deps());
      let done: number = 0;
      l.onDone = (): void => {
        done++;
      };
      l.load();
      await settle();
      expect(l.canSign).assertFalse();
      l.setChecked(true);
      expect(l.sign()).assertTrue();
      await settle();
      signed = true;
      expect(done).assertEqual(1);
      expect(contract.signedVersion).assertEqual('v1');
      expect(contract.signedSha).assertEqual('fixture-sha');
      c.onShown();
      await settle();
      expect(c.snapshot.inputText).assertEqual('5');
      expect(f.count('POST /v1/withdrawals')).assertEqual(0);
      expect(c.canSubmit).assertTrue();
    });

    it('AC_S2_62_44001_blocked_dialog_and_appeal', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(44001, '{}'));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      expect((c.snapshot.riskDialog as WalletMessage).textKey).assertEqual('error.44001');
      expect(c.snapshot.inputText).assertEqual('10');
      c.appeal();
      expect(f.cs).assertEqual(1);
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('Help');
    });

    it('AC_S2_22_30303_and_30302_texts', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(30303, '{"reason":"below_min"}'));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(500, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      expect((c.snapshot.banner as WalletMessage).text).assertEqual('提现金额低于单笔最低金额');
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => envelope(0, rulesJson(null,
        '{"can_withdraw":false,"block_code":30302,"max_withdrawable_fen":0,"quick_amounts_fen":[]}')));
      const c2: WithdrawController = await openWithdraw(f);
      expect(c2.guide()?.['textKey'] as string).assertEqual('error.30302');
      expect(c2.canSubmit).assertFalse();
    });

    it('AC_S2_62_left_page_response_only_settles_pending_record', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      c.leave();
      // 提交离开页面不取消（B 类）
      expect(f.rig.server.cancelled.filter((r: TransportRequest) => pathOf(r) === '/v1/withdrawals').length)
        .assertEqual(0);
      f.held[f.held.length - 1].resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.SUBMITTING);
      expect(f.rig.client.pendingFor('createWithdrawal') !== null).assertTrue();
    });

    // ---------------------------------------------------------------- 收款账号（AC-S2-21、AC-S2-54 ①、AC-S2-62 ⑰㉒）
    it('AC_S2_54_payout_bound_view_change_form_and_first_save_step_up', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('PUT /v1/me/payout-account', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
        ? envelope(10003, '{}') : envelope(0, '{"payout_method":"bank_card","masked_account":"尾号 0009",'
          + '"bank_name":"示例银行","masked_payee_name":"**三","change_remaining_this_month":1}'));
      f.router.open(RouteRequest.of('Withdraw', RouteSource.IN_APP));
      f.router.open(RouteRequest.of('PayoutAccount', RouteSource.IN_APP));
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      let saved: number = 0;
      p.onSaved = (): void => {
        saved++;
      };
      p.onShown();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.VIEW);
      expect(p.startChange(p.snapshot.version)).assertTrue();
      p.setMethod('bank_card');
      expect(p.setField('card_no', '6222 0000-0000 0009x')).assertFalse();
      p.setField('card_no', ' 6222 0000-0000 0009 ');
      p.setField('payee_name', ' 测试三 ');
      // 开户行必填（G12）：本地字段错误，不发请求
      expect(p.save()).assertFalse();
      expect(p.snapshot.fieldErrors.has('bank_name')).assertTrue();
      expect(f.count('PUT /v1/me/payout-account')).assertEqual(0);
      p.setField('bank_name', ' 示例银行 ');
      expect(p.save()).assertTrue();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.STEP_UP);
      await passStepUp(p);
      const put: TransportRequest = f.last('PUT /v1/me/payout-account');
      expect(put.body as string).assertEqual(
        '{"payout_method":"bank_card","card_no":"6222 0000-0000 0009","bank_name":"示例银行","payee_name":"测试三"}');
      expect(header(put, 'X-Step-Up-Token') as string).assertEqual('fixture-step-token');
      expect(saved).assertEqual(1);
      expect(p.snapshot.form.cardNo).assertEqual('');
      expect(p.snapshot.account?.['masked_account'] as string).assertEqual('尾号 0009');
      const sms: Record<string, Object> = JSON.parse(f.last('/v1/auth/sms-codes').body ?? '{}') as Record<string, Object>;
      expect(sms['action'] as string).assertEqual('payout_account_change');
    });

    it('AC_S2_62_17_22_payout_pending_summary_masked_and_errors', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      p.setField('alipay_logon_id', 'zhangsan@example.com');
      p.setField('payee_name', '测试三');
      p.save();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.PENDING);
      const summary: WalletRecord = (p.snapshot.pending as PendingView).summary as WalletRecord;
      expect(summary['account'] as string).assertEqual('zh***@example.com');
      expect(summary['payee'] as string).assertEqual('**三');
      // 存储里的摘要不含完整登录号（完整请求体只在未决记录的 body 里）
      expect((f.rig.client.pendingFor('savePayoutAccount')?.summary ?? '').indexOf('zhangsan')).assertEqual(-1);
      // 确认得到 20001（payout_method 已关闭）：暂时确认不了，键不结束（㉒）
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => envelope(20001, '{"fields":["payout_method"]}'));
      p.confirm(p.snapshot.pendingVersion);
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.PENDING);
      expect(f.rig.client.pendingFor('savePayoutAccount') !== null).assertTrue();
    });

    it('AC_S2_21_payout_30304_opens_realname_keeps_form_and_field_errors', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => envelope(30304, '{}'));
      f.router.open(RouteRequest.of('PayoutAccount', RouteSource.IN_APP));
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      p.setField('alipay_logon_id', '13800135678');
      p.setField('payee_name', '测试三');
      p.save();
      await settle();
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('RealName');
      expect(p.snapshot.form.alipayLogonId).assertEqual('13800135678');
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      // 20001（card_no）在卡号旁提示
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => envelope(20001, '{"fields":["alipay_logon_id"],'
        + '"reason":"phone_invalid"}'));
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      p.save();
      await settle();
      expect(p.snapshot.fieldErrors.get('alipay_logon_id')?.textKey as string).assertEqual('error.20001.phone_invalid');
      // 30303 change_limit：页内提示
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => envelope(30303,
        '{"reason":"payout_account_change_limit"}'));
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      p.save();
      await settle();
      expect(p.snapshot.banner?.textKey as string).assertEqual('error.30303.payout_account_change_limit');
      expect(PayoutAccountForm.acceptCardNo('a')).assertNull();
    });

    // ---------------------------------------------------------------- 实名（G01、AC-S2-21）
    it('G01_realname_release_unavailable_and_debug_consent_flow', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const r0: RealNameController = new RealNameController(f.deps());
      r0.setName('测试三');
      r0.setIdNo('00000000000000000x');
      expect(r0.snapshot.unavailable).assertTrue();
      expect(r0.requestSubmit()).assertFalse();
      const contract: FakeContract = new FakeContract();
      f.contract = contract;
      const r: RealNameController = new RealNameController(f.deps());
      let done: number = 0;
      r.onDone = (): void => {
        done++;
      };
      r.setName(' 测试三 ');
      expect(r.setIdNo('00000000000000000a')).assertFalse();
      r.setIdNo('00000000000000000x');
      expect(r.snapshot.idNo).assertEqual('00000000000000000X');
      expect(r.requestSubmit()).assertTrue();
      expect(r.snapshot.consentChecked).assertFalse();
      expect(r.agreeAndSubmit()).assertFalse();
      expect(contract.realnameCalls).assertEqual(0);
      r.setConsentChecked(true);
      contract.realnameCode = 30406;
      expect(r.agreeAndSubmit()).assertTrue();
      await settle();
      expect(r.snapshot.banner?.textKey as string).assertEqual('error.30406');
      contract.realnameCode = 30410;
      r.requestSubmit();
      r.setConsentChecked(true);
      r.agreeAndSubmit();
      await settle();
      expect(r.snapshot.lockedToday).assertTrue();
      expect(r.canSubmit).assertFalse();
      const r2: RealNameController = new RealNameController(f.deps());
      r2.onDone = (): void => {
        done++;
      };
      r2.setName('测试三');
      r2.setIdNo('000000000000000000');
      contract.realnameCode = 0;
      r2.requestSubmit();
      r2.setConsentChecked(true);
      r2.agreeAndSubmit();
      await settle();
      expect(done).assertEqual(1);
      expect(r2.snapshot.idNo).assertEqual('');
    });

    // ---------------------------------------------------------------- 提现记录（AC-S2-20、AC-S2-25、G27、G30）
    it('AC_S2_25_records_focus_copy_change_account', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/withdrawals/:id', (r: TransportRequest) => pathOf(r).endsWith('/W2')
        ? envelope(0, withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00',
          ',"channel_order_id":"20260928200040011100"'))
        : envelope(30701, '{}'));
      f.router.open(RouteRequest.of('WithdrawRecords', RouteSource.IN_APP));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open('W2');
      await settle();
      expect(c.snapshot.phase).assertEqual(RecordsPhase.CONTENT);
      expect(c.snapshot.items[0]['withdrawal_id'] as string).assertEqual('W2');
      expect(c.isExpanded('W2')).assertTrue();
      expect(WithdrawRecordsGrouping.monthKey(c.snapshot.items[0])).assertEqual('2026-09');
      expect(c.tradeNo('W2')['copyText'] as string).assertEqual('20260928200040011100');
      expect(await c.copy('W2', c.snapshot.version)).assertEqual('done');
      expect(f.board.text as string).assertEqual('20260928200040011100');
      expect(f.ledger.contains('20260928200040011100')).assertTrue();
      // 自写 hash 记录失败：不写剪贴板
      f.writer = new ClipboardWriter(f.board, new ClipboardWriteLedger(ClipboardWriteLedger.DEFAULT_CAPACITY,
        (t: string): string => 'h:' + t, new FailingHashStore()));
      const c2: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c2.open('W2');
      await settle();
      expect(await c2.copy('W2', c2.snapshot.version)).assertEqual('failed');
      expect(f.board.writes).assertEqual(1);
      // FAILED + change_payout_account → 【修改收款账号】→ PayoutAccount；其他单不出
      expect(c.changeAccount('W2', c.snapshot.version)).assertFalse();
      expect(c.changeAccount('W3', c.snapshot.version)).assertTrue();
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('PayoutAccount');
      // 30701：只显示列表，不提示
      const c3: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c3.open('W404');
      await settle();
      expect(c3.snapshot.notice).assertNull();
      expect(c3.snapshot.items[0]['withdrawal_id'] as string).assertEqual('W3');
    });

    // ---------------------------------------------------------------- 路由参数（AC-S1-81 ⑫）与金额隐藏（AC-S1-105）
    it('AC_S1_81_12_fund_routes_drop_params_and_record_event', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const p: Record<string, Object> = {};
      p['amount_fen'] = 500;
      p['payee_name'] = 'x';
      f.router.open(RouteRequest.of('Withdraw', RouteSource.IN_APP, p));
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('Withdraw');
      expect(Object.keys(f.stack.topParams()).length).assertEqual(0);
      expect(JSON.stringify(f.dropped)).assertEqual('["Withdraw:2"]');
      const q: Record<string, Object> = {};
      q['withdrawal_id'] = 'W1';
      f.router.open(RouteRequest.of('WithdrawRecords', RouteSource.IN_APP, q));
      expect(f.stack.topParams()['withdrawal_id'] as string).assertEqual('W1');
      expect(f.dropped.length).assertEqual(1);
      // 页面没有任何预填
      const c: WithdrawController = await openWithdraw(f);
      expect(c.snapshot.inputText).assertEqual('');
    });

    it('AC_S1_105_mask_shared_with_orders_and_not_uploaded', 0, async () => {
      const backend: MemoryAmountMaskBackend = new MemoryAmountMaskBackend();
      AmountMaskStore.shared.attach(backend);
      AmountMaskStore.shared.set(false);
      let ordersSeen: boolean = false;
      const off: () => void = AmountMaskStore.shared.subscribe((h: boolean): void => {
        ordersSeen = h;
      });
      const f: WalletFixture = new WalletFixture();
      const before: number = f.rig.server.received.length;
      AmountMaskStore.shared.toggle();
      expect(ordersSeen).assertTrue();
      expect(backend.hidden).assertTrue();
      expect(f.rig.server.received.length).assertEqual(before);
      // 换账号仍隐藏（本机偏好，不随账号）
      f.switchAccount('user-2');
      expect(AmountMaskStore.shared.hidden).assertTrue();
      AmountMaskStore.shared.set(false);
      off();
    });
  });
}
