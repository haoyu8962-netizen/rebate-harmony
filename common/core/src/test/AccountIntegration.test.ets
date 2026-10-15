// APP-13a 鸿蒙注销账号、换手机号、BindPhone 待确认的本地假服务集成测试（brief §2 第 13 项）：真实 ApiClient（签名、幂等、未决键、step-up 头、
// 受限作用域都走网络层真实管线）+ 本地假服务（NetworkTestRig.FakeServer，不连任何地址、不做真实注销与换号）+ 真实 Router / StackNavigator
// （页面入口经 Router 打开）+ Core 执行器（页面按钮回调调用的同一套方法，按钮回调只带渲染时的版本）。
// 号码只用测试值：会话测试号 13800005678、新号 13900001234；测试里没有像密钥的字面量，失败信息不含令牌、验证码或请求体。
import { describe, it, expect } from '@ohos/hypium';
import {
  AccountDeps, AccountEntryPolicy, AccountMessage, RouteDestination, AccountRecord, AccountSession, ApiClientWalletPort, BindOutcome, BindPhoneAction,
  BindPhoneHost, BindPhoneService, ClipboardController, DeleteAccountController, Deletion10007, DeletionPresentation,
  DeletionSnapshot, DeletionSource, DeletionSourceHandoff, ForceUpdateDeletionEntry, GuardDecision, GuardDecisionKind,
  GuardReason, GuardState, LaunchReadiness, MemoryPendingBackend, MemoryPendingKeyBackend, MeLevel, MePlatform,
  PendingActionStore, PendingKeyStore, PhoneBindingState, PhoneChangeController, PhoneChangeStep, PrivacyState,
  PushReportState, PushTokenReporter, PushTokenSource, RetryAfterGate, RouteAvailability, RouteRequest, RouteSource, Router,
  RouteTable, SessionTokenSet, SettingsItems, SmsSendDeadlines, StackNavigator, StepUpController, StepUpSheetFit,
  TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState, WalletSession
} from '../../Index';
import { CouliFormat, StepUpPanelFit } from 'designsystem';
import { RouteSpec } from 'generated';
import { Deferred, envelope, flush, header, Rig, waitUntil } from './NetworkTestRig';
import { ParamStack, TAB_ROOTS } from './OrderIntegration.test';

export const NOW: number = Date.parse('2026-10-14T10:00:00+08:00');
export const PHONE: string = '13800005678';
export const NEW_PHONE: string = '13900001234';
const DELETE: string = 'DeleteAccount';

export function cooling(canCancel: boolean = true): string {
  return '{"status":"cooling","apply_at":"2026-10-14T10:00:00+08:00","cooling_until":"2026-10-21T10:00:00+08:00",'
    + '"can_cancel":' + canCancel + ',"cancelled_at":null,"cancel_reason":null,"processed_at":null}';
}

function cancelled(reason: string): string {
  return '{"status":"cancelled","apply_at":"2026-10-01T10:00:00+08:00","cooling_until":"2026-10-08T10:00:00+08:00",'
    + '"can_cancel":false,"cancelled_at":"2026-10-08T10:00:00+08:00","cancel_reason":"' + reason + '","processed_at":null}';
}

export function summary(neg: number = 0, withdrawable: number = 1234): string {
  return '{"available_fen":' + (withdrawable - neg) + ',"withdrawable_fen":' + withdrawable + ',"negative_fen":' + neg
    + ',"frozen_fen":0,"estimated_total_fen":5678,"estimated_fen":2222,"pending_credit_fen":0,"pending_credit_paused_fen":0,'
    + '"next_credit_period":"2026-10","credit_overdue":false,"withdrawn_fen":0,"risk_paused_reason":null,"withdraw_enabled":true}';
}

function pathOf(r: TransportRequest): string {
  const u: string = r.url.split('?')[0];
  return u.substring(u.indexOf('/v1/'));
}

/** 不带统一外壳的网关错误页（结果未知）。 */
export function gateway(): TransportResponse {
  return TransportResponse.ok(504, {}, '<html>gateway timeout</html>');
}

type Reply = (r: TransportRequest) => TransportResponse | null;

/** 账号执行层 + 真实 Router 的装配（与 entry AppAccount 同一接线）。 */
export class AccountFixture {
  readonly rig: Rig;
  readonly stack: ParamStack = new ParamStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly wallet: WalletSession;
  readonly meReadGate: RetryAfterGate;
  readonly session: AccountSession;
  replies: Map<string, Reply> = new Map<string, Reply>();
  held: Deferred[] = [];
  phone: string | null = PHONE;
  available: boolean = true;
  forced: number = 0;
  cs: number = 0;
  meLoaded: number = 0;
  deletionChanges: number = 0;
  opened: string[] = [];
  reconsents: string[] = [];
  dropped: string[] = [];
  update: string = 'ok';

  constructor(rig: Rig | null = null) {
    this.rig = rig ?? new Rig();
    this.rig.nowMillis = NOW;
    this.wallet = new WalletSession((): number => this.rig.nowMillis, (): string => this.walletScope());
    this.meReadGate = new RetryAfterGate((): number => this.rig.nowMillis, (): string => this.walletScope());
    this.session = new AccountSession((): number => this.rig.nowMillis, (): string => this.scope(), this.wallet.stepUp,
      this.wallet.readGate, this.meReadGate);
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => d.route !== null && TAB_ROOTS.indexOf(d.route) >= 0;
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => this.rig.nowMillis),
      (): GuardState => new GuardState('consented', this.update, 'phone_bound', true, '1.0.0', false, false, true),
      this.navigator, (name: string): RouteSpec | undefined => this.lookup(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
    this.router.onParamsDropped = (route: string, n: number): void => {
      this.dropped.push(route + ':' + n);
    };
    this.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, 'null'));
    this.reply('GET /v1/wallet/summary', (_r: TransportRequest) => envelope(0, summary()));
    this.reply('GET /v1/me', (_r: TransportRequest) => envelope(0, '{"user_id":"user-1","phone_bound":true}'));
    this.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
    this.reply('POST /v1/auth/step-up', (r: TransportRequest) => (r.body ?? '').indexOf('"123456"') >= 0
      ? envelope(0, '{"step_up_token":"fixture-step-token","expire_at":"2026-10-14T10:05:00+08:00"}')
      : envelope(20002, '{}'));
    this.reply('POST /v1/me/deletion', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
      ? envelope(10003, '{}') : envelope(0, cooling()));
    this.reply('POST /v1/me/deletion/cancel', (_r: TransportRequest) => envelope(0, cancelled('user')));
    this.reply('POST /v1/me/phone', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
      ? envelope(10003, '{}') : envelope(0, '{}'));
    this.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) =>
    envelope(0, '{"outcome":"abandoned","original":null}'));
    this.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      const reply: Reply | undefined = this.replies.get(r.method + ' ' + pathOf(r));
      const res: TransportResponse | null = reply === undefined ? envelope(0, '{}') : reply(r);
      if (res !== null) {
        return Promise.resolve(res);
      }
      const d: Deferred = new Deferred();
      this.held.push(d);
      return d.promise;
    };
  }

  lookup(name: string): RouteSpec | undefined {
    return RouteAvailability.overriding((n: string): RouteSpec | undefined => RouteTable.spec(n),
      this.available ? [DELETE] : [])(name);
  }

  reply(key: string, r: Reply): void {
    this.replies.set(key, r);
  }

  walletScope(): string {
    return ClipboardController.scopeKey(this.rig.client.captureScope());
  }

  scope(): string {
    return this.walletScope() + '|' + this.rig.client.sessionScope();
  }

  deps(): AccountDeps {
    const d: AccountDeps = new AccountDeps(new ApiClientWalletPort(this.rig.client), this.session);
    d.clock = (): number => this.rig.nowMillis;
    d.scope = (): string => this.scope();
    d.account = (): string | null => this.rig.client.sessionAccount();
    d.sessionScope = (): string => this.rig.client.sessionScope();
    d.stepUpRestricted = (): boolean => this.rig.client.sessionScope() === 'deletion_only';
    d.stepUpPhone = (_a: string): string | null => this.phone;
    d.forceUpdate = (): void => {
      this.forced++;
    };
    d.open = (route: string, params: Record<string, Object>): void => {
      this.opened.push(route);
      this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
    };
    d.customerService = (): void => {
      this.cs++;
    };
    d.reconsent = (t: string): void => {
      this.reconsents.push(t);
    };
    d.money = (fen: number): string => CouliFormat.money(fen);
    d.meLoaded = (_a: string, _m: AccountRecord): void => {
      this.meLoaded++;
    };
    d.deletionChanged = (): void => {
      this.deletionChanges++;
    };
    d.displayNow = (): number => this.rig.nowMillis;
    return d;
  }

  count(key: string): number {
    const parts: string[] = key.split(' ');
    return this.rig.server.received.filter((r: TransportRequest): boolean => pathOf(r) === parts[1]
      && r.method === parts[0]).length;
  }

  requests(key: string): TransportRequest[] {
    const parts: string[] = key.split(' ');
    return this.rig.server.received.filter((r: TransportRequest): boolean => pathOf(r) === parts[1]
      && r.method === parts[0]);
  }

  last(key: string): TransportRequest {
    const list: TransportRequest[] = this.requests(key);
    return list[list.length - 1];
  }

  /** 换账号 / 换作用域（登录保存新令牌）：ApiClient 会话换代；sync=false 模拟「清空通知还没到」。 */
  switchAccount(account: string, scope: string = 'full', sync: boolean = true): void {
    this.rig.tokens.save(new SessionTokenSet('access-' + account + '-' + scope, 'refresh-' + account, scope, account));
    this.rig.client.onSessionChanged();
    if (sync) {
      this.wallet.sync();
      this.session.sync();
    }
  }

  pendingKeys(op: string): number {
    return this.rig.client.pendingFor(op) === null ? 0 : 1;
  }
}

export async function settle(): Promise<void> {
  for (let i: number = 0; i < 6; i++) {
    await flush();
  }
}

/** 打开注销页（首轮三样读取完成）。 */
export async function openDeletion(f: AccountFixture, source: string = DeletionSource.SETTINGS): Promise<DeleteAccountController> {
  f.session.sync();
  const c: DeleteAccountController = new DeleteAccountController(f.deps(), source);
  c.onShown();
  await settle();
  return c;
}

/** 勾选 → 申请 → 10003 → 面板发码 → 123456 → 验证 → 沿用原键重放。 */
/**
 * 申请注销并走完二次验证。FU-HM-0721（对照 Android FU-AND-0716 R2-01）：原来固定 settle 轮次后看面板有没有出来、没出来就静默返回 null，
 * 响应晚于固定轮次时会跳过面板。改为等到「面板要打开」或本次申请的明确终态（不再提交中且已离开初始态 / 有错误条 / 不支持提示）；
 * 发码、验证同样等到明确结果。等不到按失败退出（上限只用于失败）。
 */
export async function applyWithStepUp(c: DeleteAccountController): Promise<StepUpController | null> {
  c.setChecked(c.snapshot.version, true);
  c.apply(c.snapshot.version);
  const decided: boolean = await waitUntil((): boolean => c.snapshot.stepUpAction !== null || (!c.snapshot.submitting
    && (stateOf(c) !== DeletionPresentation.INITIAL || c.snapshot.banner !== null || c.snapshot.unsupportedShown)));
  expect(decided).assertTrue();
  const s: StepUpController | null = c.createStepUp();
  if (s === null) {
    return null;
  }
  s.send();
  expect(await waitUntil((): boolean => !s.snapshot.sending && (s.snapshot.sent || s.snapshot.error !== null
    || s.snapshot.sendBlocked || s.snapshot.noPhone || s.snapshot.scopeDenied))).assertTrue();
  s.setCode('123456');
  s.verify();
  expect(await waitUntil((): boolean => (c.snapshot.stepUpAction === null && !c.snapshot.submitting)
    || (!s.snapshot.verifying && s.snapshot.error !== null))).assertTrue();
  await settle();
  return s;
}

export function stateOf(c: DeleteAccountController): string {
  return c.snapshot.view['stateRaw'] as string;
}

/** 让本账号留下一条结果未知的注销未决记录（申请时网关错误页）。 */
export async function pendingDeletion(f: AccountFixture): Promise<DeleteAccountController> {
  f.reply('POST /v1/me/deletion', (_r: TransportRequest) => gateway());
  const c: DeleteAccountController = await openDeletion(f);
  c.setChecked(c.snapshot.version, true);
  c.apply(c.snapshot.version);
  await settle();
  return c;
}

export class Host implements BindPhoneHost {
  bound: number = 0;

  phoneBound(): void {
    this.bound++;
  }
}

/** 换号走到第 2 步（第 1 步发码、验证成功）。 */
export async function toStep2(f: AccountFixture): Promise<PhoneChangeController> {
  f.session.sync();
  const p: PhoneChangeController = new PhoneChangeController(f.deps());
  p.onShown();
  p.sendStep1(p.snapshot.version);
  await settle();
  p.setStep1Code(p.snapshot.version, '123456');
  p.next(p.snapshot.version);
  await settle();
  return p;
}

export async function fillStep2(f: AccountFixture, p: PhoneChangeController, phone: string = NEW_PHONE,
  code: string = '654321'): Promise<void> {
  p.setNewPhone(p.snapshot.version, phone);
  p.sendBind(p.snapshot.version);
  await settle();
  p.setCode(p.snapshot.version, code);
}

export class FakePush implements PushTokenSource {
  start(): void {
  }

  stop(): void {
  }

  current(): string | null {
    return 'test-push-token-1';
  }

  subscribe(_l: () => void): () => void {
    return (): void => {
    };
  }
}

export class RestrictedPushState implements PushReportState {
  level(): string {
    return 'member';
  }

  sessionScope(): string {
    return 'deletion_only';
  }

  forceUpdate(): string {
    return 'below';
  }

  sessionKey(): string {
    return '1|user-1';
  }

  onForceUpdate(): void {
  }
}

export default function accountIntegrationTest() {
  describe('AccountIntegration', () => {
    // ---------------------------------------------------------------- 注销主链
    it('deletion_main_chain_initial_funds_checkbox_stepup_same_key_replay_cooling', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const c: DeleteAccountController = await openDeletion(f);
      expect(stateOf(c)).assertEqual(DeletionPresentation.INITIAL);
      // G35：资金区展示服务端字段，经 CouliFormat.money。
      expect(CouliFormat.money(c.snapshot.view['withdrawableFen'] as number)).assertEqual('¥12.34');
      expect(CouliFormat.money(c.snapshot.view['estimatedFen'] as number)).assertEqual('¥56.78');
      expect(c.snapshot.view['showGoWithdraw']).assertTrue();
      // 未勾选时【申请注销】不可用，点击不发请求。
      expect(c.canApply).assertFalse();
      expect(c.apply(c.snapshot.version)).assertFalse();
      expect(f.count('POST /v1/me/deletion')).assertEqual(0);
      const panel: StepUpController | null = await applyWithStepUp(c);
      expect(panel !== null).assertTrue();
      // 面板按 account_deletion 向会话号码发码。
      const sms: string = f.last('POST /v1/auth/sms-codes').body ?? '';
      expect(sms.indexOf('"action":"account_deletion"') >= 0 && sms.indexOf('"purpose":"step_up"') >= 0).assertTrue();
      expect(sms.indexOf(PHONE) >= 0).assertTrue();
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
      // 只有 1 个键、1 次业务受理：两次 POST 同一个 Idempotency-Key，第二次带 token。
      const posts: TransportRequest[] = f.requests('POST /v1/me/deletion');
      expect(posts.length).assertEqual(2);
      expect(header(posts[0], 'Idempotency-Key')).assertEqual(header(posts[1], 'Idempotency-Key'));
      expect(header(posts[0], 'X-Step-Up-Token') === undefined).assertTrue();
      expect(header(posts[1], 'X-Step-Up-Token') !== undefined).assertTrue();
      expect(posts[0].body === null || posts[0].body === '').assertTrue();
      expect(f.pendingKeys('requestDeletion')).assertEqual(0);
      // 申请成功不退出登录、不清会话（G19）。
      expect(f.rig.client.sessionAccount()).assertEqual('user-1');
      expect(f.deletionChanges > 0).assertTrue();
    });

    it('AC_S2_58_negative_on_entry_prompt_contact_cs_apply_disabled_no_request', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/wallet/summary', (_r: TransportRequest) => envelope(0, summary(200, 0)));
      const c: DeleteAccountController = await openDeletion(f);
      expect(stateOf(c)).assertEqual(DeletionPresentation.NEGATIVE);
      expect(c.snapshot.negativeText).assertEqual('账户有待扣回金额 ¥2，抵扣回正后才能注销');
      expect(c.setChecked(c.snapshot.version, true)).assertFalse();
      expect(c.apply(c.snapshot.version)).assertFalse();
      expect(c.contactCs(c.snapshot.version)).assertTrue();
      expect(f.cs).assertEqual(1);
      expect(f.count('POST /v1/me/deletion')).assertEqual(0);
    });

    it('AC_S2_58_apply_30416_same_sentence_key_ends_recovered_new_key', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(30416, '{"amount_fen":200}'));
      const c: DeleteAccountController = await openDeletion(f);
      c.setChecked(c.snapshot.version, true);
      c.apply(c.snapshot.version);
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.NEGATIVE);
      expect(c.snapshot.negativeText).assertEqual('账户有待扣回金额 ¥2，抵扣回正后才能注销');
      expect(f.pendingKeys('requestDeletion')).assertEqual(0);
      const first: string | undefined = header(f.last('POST /v1/me/deletion'), 'Idempotency-Key');
      // 回正后（重新进页按钱包摘要）可以申请，用新键。
      f.reply('POST /v1/me/deletion', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
        ? envelope(10003, '{}') : envelope(0, cooling()));
      c.onShown();
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.INITIAL);
      await applyWithStepUp(c);
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
      expect(header(f.requests('POST /v1/me/deletion')[1], 'Idempotency-Key') !== first).assertTrue();
    });

    it('apply_30416_without_amount_uses_fallback_sentence', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(30416, '{}'));
      const c: DeleteAccountController = await openDeletion(f);
      c.setChecked(c.snapshot.version, true);
      c.apply(c.snapshot.version);
      await settle();
      expect(c.snapshot.negativeText).assertEqual('账户有待扣回金额，抵扣回正后才能注销');
    });

    it('AC_S2_60_cancelled_negative_balance_negative_then_recovered_initial', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cancelled('negative_balance')));
      f.reply('GET /v1/wallet/summary', (_r: TransportRequest) => envelope(0, summary(300, 0)));
      const c: DeleteAccountController = await openDeletion(f);
      expect(stateOf(c)).assertEqual(DeletionPresentation.NEGATIVE);
      f.reply('GET /v1/wallet/summary', (_r: TransportRequest) => envelope(0, summary(0, 100)));
      c.onShown();
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.INITIAL);
    });

    it('apply_30412_banner_key_ends_checkbox_kept_next_click_new_key', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(30412, '{}'));
      const c: DeleteAccountController = await openDeletion(f);
      c.setChecked(c.snapshot.version, true);
      c.apply(c.snapshot.version);
      await settle();
      expect(c.snapshot.banner?.textKey).assertEqual('error.30412');
      expect(c.snapshot.checked).assertTrue();
      expect(f.pendingKeys('requestDeletion')).assertEqual(0);
      const k1: string | undefined = header(f.last('POST /v1/me/deletion'), 'Idempotency-Key');
      c.apply(c.snapshot.version);
      await settle();
      expect(header(f.last('POST /v1/me/deletion'), 'Idempotency-Key') !== k1).assertTrue();
    });

    it('load_failed_5xxxx_not_treated_as_never_applied_trace6_retry', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(50001, '{}'));
      const c: DeleteAccountController = await openDeletion(f);
      expect(stateOf(c)).assertEqual(DeletionPresentation.LOAD_FAILED);
      expect((c.snapshot.deletionError?.text ?? '').indexOf('123456') >= 0).assertTrue();
      expect(c.setChecked(c.snapshot.version, true)).assertFalse();
      expect(c.cancel(c.snapshot.version)).assertFalse();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      expect(c.retry(c.snapshot.version)).assertTrue();
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
    });

    it('funds_unavailable_disables_apply_until_wallet_read', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/wallet/summary', (_r: TransportRequest) => envelope(50401, '{}'));
      const c: DeleteAccountController = await openDeletion(f);
      expect(stateOf(c)).assertEqual(DeletionPresentation.FUNDS_UNAVAILABLE);
      expect(c.setChecked(c.snapshot.version, true)).assertFalse();
      expect(c.snapshot.walletError !== null).assertTrue();
    });

    it('G10_unbound_phone_only_prompt_no_request_full_bind_entry', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/me', (_r: TransportRequest) => envelope(0, '{"user_id":"user-1","phone_bound":false}'));
      const c: DeleteAccountController = await openDeletion(f);
      expect(stateOf(c)).assertEqual(DeletionPresentation.NO_PHONE);
      c.setChecked(c.snapshot.version, true);
      c.apply(c.snapshot.version);
      await settle();
      expect(c.snapshot.banner?.text).assertEqual('请先绑定手机号，或在支持该登录方式的设备上操作');
      expect(f.count('POST /v1/me/deletion')).assertEqual(0);
      expect(f.count('POST /v1/auth/oauth-attempts')).assertEqual(0);
      expect(c.bindPhone(c.snapshot.version)).assertTrue();
      expect(f.opened.indexOf('BindPhone') >= 0).assertTrue();
    });

    it('G10_unknown_phone_bound_refetches_getMe_before_apply', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      let meCalls: number = 0;
      f.reply('GET /v1/me', (_r: TransportRequest) => {
        meCalls++;
        return meCalls === 1 ? envelope(50001, '{}') : envelope(0, '{"user_id":"user-1","phone_bound":true}');
      });
      const c: DeleteAccountController = await openDeletion(f);
      expect(c.snapshot.phoneBound === null).assertTrue();
      c.setChecked(c.snapshot.version, true);
      c.apply(c.snapshot.version);
      await settle();
      expect(meCalls).assertEqual(2);
      expect(f.count('POST /v1/me/deletion')).assertEqual(1);
    });

    // ---------------------------------------------------------------- 冷静期与撤回
    it('cooling_time_BR_TEXT_11_and_can_cancel_false_hides_withdraw', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling(false)));
      const c: DeleteAccountController = await openDeletion(f);
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
      expect(c.snapshot.view['coolingUntilText']).assertEqual('10-21 10:00');
      expect(c.snapshot.view['showCancelDeletion']).assertFalse();
      expect(c.cancel(c.snapshot.version)).assertFalse();
      // 本机时钟远超冷静期也不自己推算（G15）：服务端 true 就给撤回。
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling(true)));
      f.rig.nowMillis = NOW + 40 * 24 * 3600 * 1000;
      c.onShown();
      await settle();
      expect(c.snapshot.view['showCancelDeletion']).assertTrue();
      expect(f.count('POST /v1/me/deletion/cancel')).assertEqual(0);
    });

    it('cancel_success_routes_by_source_settings_force_update_other', 0, async () => {
      const sources: string[] = [DeletionSource.SETTINGS, DeletionSource.FORCE_UPDATE, DeletionSource.ERROR_10007];
      for (const src of sources) {
        const f: AccountFixture = new AccountFixture();
        f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
        const c: DeleteAccountController = await openDeletion(f, src);
        let toSettings: string = '';
        let toForce: number = 0;
        c.exitToSettings = (m: AccountMessage): void => {
          toSettings = m.text;
        };
        c.exitToForceUpdate = (): void => {
          toForce++;
        };
        expect(c.cancel(c.snapshot.version)).assertTrue();
        await settle();
        expect(stateOf(c)).assertEqual(DeletionPresentation.INITIAL);
        expect(c.snapshot.checked).assertFalse();
        if (src === DeletionSource.SETTINGS) {
          expect(toSettings).assertEqual('已撤回注销申请，账号恢复正常使用。');
        } else if (src === DeletionSource.FORCE_UPDATE) {
          expect(toForce).assertEqual(1);
        } else {
          expect(c.snapshot.notice?.text).assertEqual('已撤回注销申请，账号恢复正常使用。');
          expect(toSettings.length + toForce).assertEqual(0);
        }
        // cancelDeletion 不签名、不写未决记录（网络层给所有写请求带幂等键头，但它不是 x-step-up 操作，不登记未决）。
        expect(header(f.last('POST /v1/me/deletion/cancel'), 'X-Sign') === undefined).assertTrue();
        expect(f.pendingKeys('cancelDeletion')).assertEqual(0);
      }
    });

    it('cancel_10007_stays_cooling_and_refetches', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      f.reply('POST /v1/me/deletion/cancel', (_r: TransportRequest) => envelope(10007, '{"stage":"processing"}'));
      const c: DeleteAccountController = await openDeletion(f);
      const reads: number = f.count('GET /v1/me/deletion');
      c.cancel(c.snapshot.version);
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
      expect(c.snapshot.coolingNotice?.textKey).assertEqual('deletion.cooling.cancel_expired');
      expect(f.count('GET /v1/me/deletion')).assertEqual(reads + 1);
    });

    it('cancel_unknown_result_no_auto_resend_refetch_user_retries', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      f.reply('POST /v1/me/deletion/cancel', (_r: TransportRequest) => gateway());
      const c: DeleteAccountController = await openDeletion(f);
      c.cancel(c.snapshot.version);
      await settle();
      expect(f.count('POST /v1/me/deletion/cancel')).assertEqual(1);
      expect(c.snapshot.coolingNotice?.text).assertEqual('暂时没有收到结果，请稍后再试');
      expect(c.snapshot.view['showCancelDeletion']).assertTrue();
      expect(f.pendingKeys('cancelDeletion')).assertEqual(0);
    });
  });
}
