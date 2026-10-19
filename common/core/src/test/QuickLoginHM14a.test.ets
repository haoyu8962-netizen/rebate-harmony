// HM-14a 华为账号一键登录端口 + 假实现 + 首屏决策 + 普通华为授权适配器（HM-14 闸前部分）。依据：couli-runs/NATIVE/HM-13/scope.md
// §1 R11–R13、§4「HM-14a」（给测试作者）、§5 G09 / G10 / G11 / G13 / G17；decision.md；规划/08 BR-ID-04 正文与细则「登录注册改版」、
// BR-ID-11；规划/04 §6.1 POST /v1/auth/login/one-tap；规划/10 AC-S1-184 ①②⑤⑦ 的逻辑部分（③④⑥ 只验 R13 的分流）。
// 生产入口：QuickLoginFlow（登录首屏：预取 → 首屏决策 → 组件事件 → 一键登录提交）、LoginFirstScreen.decide（首屏决策纯函数）、
// OAuthLoginService.visibleProviders / loginWith（普通华为授权）、Debug 假实现 DebugHuaweiQuickLogin / DebugHuaweiAuthAdapter
// （core staging，Debug 包由 entry 一行转发）、InviteLinkDispatcher.dispatch（待绑定码来源，HM-13c）。
// 替身只替代 SDK 与时钟：FakeQuickPort（华为一键登录组件：预取、协议状态、continueLogin、按钮点击与结果回调）、FakeDelay（5 秒预取超时）、
// FakeHuaweiAdapter（普通华为授权 SDK）。网络走真实 ApiClient 的记录子类（LoggingApiClient：在 request 入口同步记录）+ 本地假服务。
// 组件事件、端口调用与 request 入口记录写进同一条事件日志，用来断言先后顺序（点击 → 取授权尝试 → 凭证 → 提交；同意 → continueLogin）。
// 接口约定见 couli-runs/NATIVE/HM-13/tests-14a-handback.md §2。
// 第 2 版（tests-14a-review-r1，口径 decision.md G26–G29）：服务端失败转手机号页 + 通用提示；取消勾选撤销同意；经生产 otherPhone() 切换后迟到凭证丢弃；
// confirmAgree() 与 prefetchSettled() 作完成信号（不再让出宏任务）。
// 第 3 版（tests-14a-review-r2）：凭证等待授权尝试期间取消勾选 / 切到手机号页，放行后不提交。
// 第 4 版（mutations-14a-results.md 幸存变异补测）：不换会话的 STALE 后重复回调不重交（M34）；预取途中撤回隐私 / 离页 / 换环境不进一键（M24）；
// 旧一轮迟到预取不覆盖新一轮首屏（M23）；同一 VM 重启重置同意并作废旧尝试与在途登录（M69）；取到尝试后换会话 / 环境不提交（M30）；
// 受限入口一键登录不带也不消费待绑定码（M33）。
import { describe, expect, it } from '@ohos/hypium';
import {
  AgreementConfirmKeys, ApiClient, ApiClientDeps, ApiRequest, ApiResult, HuaweiQuickLoginPort, InviteLinkDispatcher, InviteLinkInput,
  LastLoginMethodBackend, LastLoginMethodStore, LegalVersions, LoginFirstScreen, LoginOutcome, OAuthLoginOutcome,
  OAuthLoginService, OAuthProvider, OneTapLoginPort, PendingInviteCode, QuickLoginCredential, QuickLoginCredentialKind,
  QuickLoginDeps, QuickLoginFallback, QuickLoginFlow, QuickLoginPrefetch, SessionState, SessionTokenSet, ThirdPartyAuthAdapter,
  ThirdPartyAuthKind, ThirdPartyAuthResult, TransportRequest, TransportResponse, UnavailableHuaweiAdapter
} from '../../Index';
import {
  DebugHuaweiAuthAdapter, DebugHuaweiQuickLogin, DebugHuaweiQuickLoginScene
} from '../staging/ets/login/DebugHuaweiLogin';
import { Deferred, envelope, waitUntil } from './NetworkTestRig';
import { OAuthFixture } from './App05bFixture';
import { same } from './AgentTransportIntegration.test';

/** 04 §6.1 的路径（契约线落地时可改名；改名时同步这里与 OneTapLoginPort）。 */
const ONE_TAP_PATH: string = '/v1/auth/login/one-tap';
const API_BASE: string = 'https://api.test.invalid';
const ATTEMPTS_PATH: string = '/v1/auth/oauth-attempts';
const HUAWEI_LOGIN_PATH: string = '/v1/auth/login/huawei';
const CREATE_OP: string = 'createOauthAttempt';
const HUAWEI_OP: string = 'loginByHuawei';
const ANON_PHONE: string = '138****5678';
const HW_CODE: string = 'hw-one-tap-code-1';
const CODE_K: string = 'K7M2QX';
const CODE_P: string = 'P3N8WZ';
const GENERIC_KEY: string = 'error.50001';
const CONFIRM_LOGIN_KEY: string = 'login.agree_confirm.btn_login';
const CONFIRM_DISAGREE_KEY: string = 'login.agree_confirm.btn_disagree';
const ONE_TAP_FIELDS: string[] = ['attempt_id', 'authorization_code', 'consent_at', 'legal_versions', 'provider'];
const ALL_FALLBACKS: string[] = [QuickLoginFallback.NOT_LOGGED_IN, QuickLoginFallback.NO_PHONE,
  QuickLoginFallback.NO_PERMISSION, QuickLoginFallback.UNSUPPORTED, QuickLoginFallback.ERROR];

// ---------------------------------------------------------------- 替身与记录

/** 在 ApiClient.request 入口同步记录（含本地拒绝的调用），再原样交给真实客户端。 */
class LoggingApiClient extends ApiClient {
  readonly calls: ApiRequest[] = [];
  private readonly log: string[];

  constructor(deps: ApiClientDeps, log: string[]) {
    super(deps);
    this.log = log;
  }

  request(request: ApiRequest): Promise<ApiResult> {
    this.calls.push(request);
    this.log.push('request:' + request.operationId);
    return super.request(request);
  }
}

/** 华为账号一键登录组件的替身（只替代 SDK）：调用写进事件日志；预取可挂起；点击与结果回调由测试触发。 */
class FakeQuickPort implements HuaweiQuickLoginPort {
  private readonly log: string[];
  prefetchCalls: number = 0;
  /** 非 null 时预取立即返回它；null 时挂起，等 resolvePrefetch。 */
  nextPrefetch: QuickLoginPrefetch | null = null;
  /** 最近一次交给被测方的预取 Promise（结算点：等它兑现后再让出一个宏任务）。 */
  lastPrefetch: Promise<QuickLoginPrefetch> | null = null;
  listenCalls: number = 0;
  private resolvers: ((p: QuickLoginPrefetch) => void)[] = [];
  private clickListener: (() => Promise<void>) | null = null;
  private credentialListener: ((r: QuickLoginCredential) => Promise<void>) | null = null;

  constructor(log: string[]) {
    this.log = log;
  }

  prefetchAnonymousPhone(): Promise<QuickLoginPrefetch> {
    this.prefetchCalls++;
    this.log.push('prefetch');
    const fixed: QuickLoginPrefetch | null = this.nextPrefetch;
    const p: Promise<QuickLoginPrefetch> = fixed !== null ? Promise.resolve(fixed) :
      new Promise<QuickLoginPrefetch>((resolve: (p: QuickLoginPrefetch) => void): void => {
        this.resolvers.push(resolve);
      });
    this.lastPrefetch = p;
    return p;
  }

  resolvePrefetch(p: QuickLoginPrefetch): void {
    const first: ((p: QuickLoginPrefetch) => void) | undefined = this.resolvers.shift();
    if (first !== undefined) {
      first(p);
    }
  }

  setAgreement(accepted: boolean): void {
    this.log.push(accepted ? 'agreement:true' : 'agreement:false');
  }

  continueLogin(): void {
    this.log.push('continueLogin');
  }

  listen(onClick: () => Promise<void>, onCredential: (result: QuickLoginCredential) => Promise<void>): void {
    this.listenCalls++;
    this.clickListener = onClick;
    this.credentialListener = onCredential;
  }

  /** 用户点组件按钮（onClickEvent）。返回被测方的处理 Promise（接口约定：处理完才兑现）。 */
  click(): Promise<void> {
    this.log.push('click');
    const l: (() => Promise<void>) | null = this.clickListener;
    return l === null ? Promise.resolve() : l();
  }

  /** 组件按钮的结果回调（onClickLoginWithHuaweiIDButton）。返回被测方的处理 Promise（含一键登录请求结算）。 */
  credential(r: QuickLoginCredential): Promise<void> {
    this.log.push('credential:' + r.kind);
    const l: ((r: QuickLoginCredential) => Promise<void>) | null = this.credentialListener;
    return l === null ? Promise.resolve() : l(r);
  }
}

/** 预取超时的计时器替身：记下请求的毫秒数，fire 才到期。 */
class FakeDelay {
  readonly requested: number[] = [];
  private pending: (() => void)[] = [];

  delay(millis: number): Promise<void> {
    this.requested.push(millis);
    return new Promise<void>((resolve: () => void): void => {
      this.pending.push(resolve);
    });
  }

  fire(): void {
    const list: (() => void)[] = this.pending;
    this.pending = [];
    for (const resolve of list) {
      resolve();
    }
  }
}

/** 普通华为授权 SDK 的替身（只替代 SDK；形状同微信适配器）。 */
class FakeHuaweiAdapter implements ThirdPartyAuthAdapter {
  readonly provider: string = OAuthProvider.HUAWEI;
  available: boolean = true;
  readonly nonces: string[] = [];

  adapterAvailable(): boolean {
    return this.available;
  }

  installed(): boolean | null {
    return true;
  }

  authorize(nonce: string): Promise<ThirdPartyAuthResult> {
    this.nonces.push(nonce);
    return Promise.resolve(new ThirdPartyAuthResult(ThirdPartyAuthKind.CREDENTIAL, null, null, null, 'hw-normal-code'));
  }
}

class MemoryMethodBackend implements LastLoginMethodBackend {
  value: string | null = null;

  read(): string | null {
    return this.value;
  }

  write(method: string | null): boolean {
    this.value = method;
    return true;
  }
}

function loginData(isNew: boolean): string {
  return '{"user_id":"user-7","is_new_user":' + (isNew ? 'true' : 'false') + ',"tokens":{"access_token":"one-tap-access",'
    + '"access_expires_at":"2026-10-08T11:30:00+08:00","refresh_token":"one-tap-refresh",'
    + '"refresh_expires_at":"2026-11-07T09:30:00+08:00","session_scope":"full"}}';
}

function attemptEnvelope(n: number): TransportResponse {
  return envelope(0, '{"attempt_id":"attempt-' + n + '","nonce":"nonce-' + n + '","expire_at":"2026-10-08T09:40:00+08:00"}');
}

/** 第三方授权等待的 600 秒超时：测试里不到期（不留真实计时器）。 */
function never(_millis: number): Promise<void> {
  return new Promise<void>((_resolve: () => void): void => {
  });
}

function bodyOf(r: ApiRequest): Record<string, Object> {
  return JSON.parse(r.body ?? '{}') as Record<string, Object>;
}

function sortedKeys(body: Record<string, Object>): string[] {
  return Object.keys(body).sort();
}

/**
 * 装配：OAuthFixture（真实 ApiClient 记录子类 / Router / RouterLoginHost / LoginService）+ 第二个 OAuthLoginService
 * （微信假适配器 + 华为假适配器，供首屏第三方行）+ 生产的 QuickLoginFlow。待绑定码与上次登录方式按 entry 的做法挂到 LoginService 上。
 */
class QuickRig {
  readonly log: string[] = [];
  readonly fx: OAuthFixture;
  readonly client: LoggingApiClient;
  readonly port: FakeQuickPort;
  readonly delay: FakeDelay = new FakeDelay();
  readonly pending: PendingInviteCode = new PendingInviteCode();
  readonly huawei: FakeHuaweiAdapter = new FakeHuaweiAdapter();
  readonly methods: MemoryMethodBackend = new MemoryMethodBackend();
  readonly methodStore: LastLoginMethodStore;
  readonly oauth: OAuthLoginService;
  readonly deps: QuickLoginDeps;
  readonly flow: QuickLoginFlow;
  capable: boolean = true;
  privacy: boolean = true;
  holdAttempts: boolean = false;
  readonly heldAttempts: Deferred[] = [];
  private readonly heldAttemptNumbers: number[] = [];
  holdOneTap: boolean = false;
  readonly heldOneTaps: Deferred[] = [];
  oneTapReply: () => TransportResponse = (): TransportResponse => envelope(0, loginData(false));
  attempts: number = 0;

  /** restricted：强更入口的受限一键登录（第 4 版，M33）；在构造 QuickLoginFlow 之前写进 deps，与 entry 装配一致。 */
  constructor(port: HuaweiQuickLoginPort | null = null, restricted: boolean = false) {
    const log: string[] = this.log;
    this.fx = new OAuthFixture(null, null, (d: ApiClientDeps): ApiClient => new LoggingApiClient(d, log));
    this.client = this.fx.rig.client as LoggingApiClient;
    this.port = new FakeQuickPort(log);
    this.fx.service.pendingInvite = this.pending;
    this.methodStore = new LastLoginMethodStore(this.methods);
    this.fx.service.lastLoginMethod = this.methodStore;
    this.oauth = new OAuthLoginService(this.fx.rig.client, this.fx.service, [this.fx.adapter, this.huawei],
      this.fx.phoneBinding, new LegalVersions(3, 2), never);
    this.fx.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => this.answer(r);
    this.deps = new QuickLoginDeps(port ?? this.port, this.fx.rig.client, this.fx.service, this.oauth,
      (): boolean => this.capable, (): boolean => this.privacy);
    this.deps.legal = new LegalVersions(3, 2);
    this.deps.delay = (millis: number): Promise<void> => this.delay.delay(millis);
    this.deps.clock = (): number => this.fx.rig.nowMillis;
    this.deps.restricted = restricted;
    this.flow = new QuickLoginFlow(this.deps);
  }

  private answer(r: TransportRequest): Promise<TransportResponse> {
    if (r.url.indexOf(ATTEMPTS_PATH) >= 0) {
      this.attempts++;
      if (this.holdAttempts) {
        const d: Deferred = new Deferred();
        this.heldAttempts.push(d);
        this.heldAttemptNumbers.push(this.attempts);
        return d.promise;
      }
      return Promise.resolve(attemptEnvelope(this.attempts));
    }
    if (r.url.indexOf(ONE_TAP_PATH) >= 0) {
      if (this.holdOneTap) {
        const d: Deferred = new Deferred();
        this.heldOneTaps.push(d);
        return d.promise;
      }
      return Promise.resolve(this.oneTapReply());
    }
    if (r.url.indexOf(HUAWEI_LOGIN_PATH) >= 0) {
      return Promise.resolve(envelope(0, loginData(false)));
    }
    return this.fx.answer(r);
  }

  releaseAttempt(index: number): void {
    this.heldAttempts[index].resolve(attemptEnvelope(this.heldAttemptNumbers[index]));
  }

  callsOf(operationId: string): ApiRequest[] {
    return this.client.calls.filter((r: ApiRequest): boolean => r.operationId === operationId);
  }

  oneTapCalls(): ApiRequest[] {
    return this.callsOf(OneTapLoginPort.OPERATION_ID);
  }

  oneTapBodies(): Record<string, Object>[] {
    return this.oneTapCalls().map((r: ApiRequest): Record<string, Object> => bodyOf(r));
  }

  createBodies(): Record<string, Object>[] {
    return this.callsOf(CREATE_OP).map((r: ApiRequest): Record<string, Object> => bodyOf(r));
  }

  /** 事件日志里第一次出现的位置；没有为 -1。 */
  at(entry: string): number {
    return this.log.indexOf(entry);
  }

  count(entry: string): number {
    return this.log.filter((e: string): boolean => e === entry).length;
  }

  /** 生产的邀请链接入口（游客，已同意）写入待绑定码（HM-13c）。 */
  linkCode(code: string): void {
    InviteLinkDispatcher.dispatch(new InviteLinkInput(code, true, true, null, false), this.pending,
      (_route: string, _params: Record<string, Object>): boolean => true);
  }

  /** 打开一键首屏：预取立即返回匿名号码，start 兑现后断言首屏是一键登录。 */
  async openQuick(): Promise<void> {
    this.port.nextPrefetch = QuickLoginPrefetch.phone(ANON_PHONE);
    await this.flow.start();
    same('quick screen opened', this.flow.screen, LoginFirstScreen.QUICK_LOGIN);
  }

  consentIso(millis: number): string {
    return new Date(millis).toISOString();
  }
}

class DecideCase {
  readonly name: string;
  readonly capable: boolean;
  readonly prefetch: QuickLoginPrefetch | null;
  readonly providers: string[];
  readonly screen: string;
  readonly thirdParty: string[];

  constructor(name: string, capable: boolean, prefetch: QuickLoginPrefetch | null, providers: string[], screen: string,
    thirdParty: string[]) {
    this.name = name;
    this.capable = capable;
    this.prefetch = prefetch;
    this.providers = providers;
    this.screen = screen;
    this.thirdParty = thirdParty;
  }
}

function decideCases(): DecideCase[] {
  const phone: QuickLoginPrefetch = QuickLoginPrefetch.phone(ANON_PHONE);
  const W: string = OAuthProvider.WECHAT;
  const H: string = OAuthProvider.HUAWEI;
  const Q: string = LoginFirstScreen.QUICK_LOGIN;
  const P: string = LoginFirstScreen.PHONE_PAGE;
  const out: DecideCase[] = [
    new DecideCase('quick_with_wechat_drops_normal_huawei', true, phone, [W, H], Q, [W]),
    new DecideCase('quick_with_huawei_only', true, phone, [H], Q, []),
    new DecideCase('quick_without_providers', true, phone, [], Q, []),
    new DecideCase('not_capable_huawei_first', false, null, [W, H], P, [H, W]),
    new DecideCase('not_capable_huawei_first_given_first', false, null, [H, W], P, [H, W]),
    new DecideCase('not_capable_ignores_prefetched_phone', false, phone, [W, H], P, [H, W]),
    new DecideCase('not_capable_huawei_unavailable_not_invented', false, null, [W], P, [W]),
    new DecideCase('timeout_or_not_run_huawei_first', true, null, [W, H], P, [H, W])
  ];
  for (const f of ALL_FALLBACKS) {
    out.push(new DecideCase('fallback_' + f + '_huawei_first', true, QuickLoginPrefetch.failed(f), [W, H], P, [H, W]));
  }
  return out;
}

export default function quickLoginHM14aTest() {
  describe('QuickLoginHM14a', () => {
    // ============================================================ 首屏决策（R11 / R12 / AC-S1-184 ①⑤⑦）

    it('decide_vectors_first_screen_and_third_party_row', 0, () => {
      for (const c of decideCases()) {
        const d: LoginFirstScreen = LoginFirstScreen.decide(c.capable, c.prefetch, c.providers);
        same(c.name + ' screen', d.screen, c.screen);
        same(c.name + ' thirdParty', d.thirdParty, c.thirdParty);
      }
    });

    it('ac_s1_184_7_capable_false_build_opens_phone_page_with_normal_huawei_first', 0, async () => {
      const q: QuickRig = new QuickRig();
      q.capable = false;
      q.port.nextPrefetch = QuickLoginPrefetch.phone(ANON_PHONE);
      await q.flow.start();
      same('screen', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
      same('third party row: normal huawei first, then wechat', q.flow.thirdParty,
        [OAuthProvider.HUAWEI, OAuthProvider.WECHAT]);
      same('no anonymous phone on phone page', q.flow.anonymousPhone, null);
      same('no request on opening', q.client.calls.length, 0);
    });

    it('ac_s1_184_1_prefetched_phone_opens_quick_login_without_normal_huawei', 0, async () => {
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      same('anonymous phone shown by component', q.flow.anonymousPhone, ANON_PHONE);
      same('third party row: only wechat', q.flow.thirdParty, [OAuthProvider.WECHAT]);
      same('one prefetch', q.port.prefetchCalls, 1);
      same('opening sends nothing', q.client.calls.length, 0);
    });

    it('ac_s1_184_5_prefetch_fallbacks_open_phone_page', 0, async () => {
      for (const f of ALL_FALLBACKS) {
        const q: QuickRig = new QuickRig();
        q.port.nextPrefetch = QuickLoginPrefetch.failed(f);
        await q.flow.start();
        same(f + ' screen', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
        same(f + ' huawei first', q.flow.thirdParty, [OAuthProvider.HUAWEI, OAuthProvider.WECHAT]);
        same(f + ' prefetched once', q.port.prefetchCalls, 1);
      }
    });

    // ============================================================ 预取 5 秒超时

    it('prefetch_timeout_is_5s_then_phone_page_and_late_phone_is_ignored', 0, async () => {
      const q: QuickRig = new QuickRig();
      let started: boolean = false;
      const running: Promise<void> = q.flow.start().then((): void => {
        started = true;
      });
      same('prefetch issued', await waitUntil((): boolean => q.port.prefetchCalls === 1), true);
      same('timeout requested', await waitUntil((): boolean => q.delay.requested.length >= 1), true);
      same('timeout is exactly 5000 ms', q.delay.requested, [QuickLoginFlow.PREFETCH_TIMEOUT_MILLIS]);
      same('PREFETCH_TIMEOUT_MILLIS', QuickLoginFlow.PREFETCH_TIMEOUT_MILLIS, 5000);
      same('not decided before the timeout fires', started, false);
      q.delay.fire();
      await running;
      same('timeout -> phone page', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
      same('timeout -> huawei first', q.flow.thirdParty, [OAuthProvider.HUAWEI, OAuthProvider.WECHAT]);
      // 迟到的号码：等生产的完成信号（预取与超时两个事件都已到达并处理完，含其中异步步骤）后断言首屏不变。
      q.port.resolvePrefetch(QuickLoginPrefetch.phone(ANON_PHONE));
      await q.flow.prefetchSettled();
      same('late phone does not flip back', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
      same('late phone not shown', q.flow.anonymousPhone, null);
      same('nothing sent', q.client.calls.length, 0);
    });

    it('prefetch_before_timeout_wins_and_late_timer_does_not_flip', 0, async () => {
      const q: QuickRig = new QuickRig();
      const running: Promise<void> = q.flow.start();
      same('prefetch issued', await waitUntil((): boolean => q.port.prefetchCalls === 1), true);
      q.port.resolvePrefetch(QuickLoginPrefetch.phone(ANON_PHONE));
      await running;
      same('quick login', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
      q.delay.fire();
      // 迟到的计时器：等生产的完成信号后断言首屏不变。
      await q.flow.prefetchSettled();
      same('late timer does not flip', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
      same('phone kept', q.flow.anonymousPhone, ANON_PHONE);
    });

    // ============================================================ G17：同意隐私前 / 基本模式不预取

    it('g17_no_prefetch_before_privacy_consent_or_in_basic_mode', 0, async () => {
      const q: QuickRig = new QuickRig();
      q.privacy = false; // 未同意当前隐私政策，或处于基本模式（同一个判定）
      q.port.nextPrefetch = QuickLoginPrefetch.phone(ANON_PHONE);
      await q.flow.start();
      same('no prefetch', q.port.prefetchCalls, 0);
      same('no prefetch in log', q.at('prefetch'), -1);
      same('phone page', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
      same('nothing sent', q.client.calls.length, 0);
      // 对照：判定在打开登录页时取（之后同意了，再打开就预取）。
      q.privacy = true;
      await q.flow.start();
      same('prefetch after consent', q.port.prefetchCalls, 1);
      same('quick login after consent', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
    });

    // ============================================================ G11：不做静默登录；G09：点击时取授权尝试

    it('g11_no_silent_login_checked_quick_screen_waits_for_user_click', 0, async () => {
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      q.flow.check();
      same('no continueLogin without user action', q.at('continueLogin'), -1);
      same('no attempt before click', q.callsOf(CREATE_OP).length, 0);
      same('no one-tap before click', q.oneTapCalls().length, 0);
      // 后续已知操作作结算点：点击 → 凭证 → 提交结算之后，整个过程只有这一次尝试与这一次提交，都在点击之后。
      await q.port.click();
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('exactly one attempt', q.callsOf(CREATE_OP).length, 1);
      same('exactly one one-tap', q.oneTapCalls().length, 1);
      same('attempt after click', q.at('request:' + CREATE_OP) > q.at('click'), true);
      same('never continueLogin', q.count('continueLogin'), 0);
    });

    it('g09_click_takes_huawei_login_attempt_and_one_tap_carries_it', 0, async () => {
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      const checkedAt: number = q.fx.rig.nowMillis;
      q.flow.check();
      same('component told agreement accepted', q.log[q.log.length - 1], 'agreement:true');
      same('checkbox checked', q.flow.agreement.checked, true);
      q.fx.rig.nowMillis += 30000;
      await q.port.click();
      same('attempt requested at click', q.callsOf(CREATE_OP).length, 1);
      const create: Record<string, Object> = q.createBodies()[0];
      same('attempt provider', create['provider'], 'huawei');
      same('attempt purpose', create['purpose'], 'login');
      same('no one-tap before credential', q.oneTapCalls().length, 0);
      q.fx.rig.nowMillis += 1000;
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      // 顺序：同意 → 点击 → 取尝试 → 凭证 → 提交
      same('order', q.at('agreement:true') < q.at('click') && q.at('click') < q.at('request:' + CREATE_OP)
        && q.at('request:' + CREATE_OP) < q.at('credential:' + QuickLoginCredentialKind.CREDENTIAL)
        && q.at('credential:' + QuickLoginCredentialKind.CREDENTIAL) < q.at('request:' + OneTapLoginPort.OPERATION_ID), true);
      same('one one-tap', q.oneTapCalls().length, 1);
      const body: Record<string, Object> = q.oneTapBodies()[0];
      same('body fields (no phone, no identity, no invite without pending)', sortedKeys(body), ONE_TAP_FIELDS);
      same('provider', body['provider'], 'huawei');
      same('attempt_id', body['attempt_id'], 'attempt-1');
      same('authorization_code', body['authorization_code'], HW_CODE);
      const legal: Record<string, Object> = body['legal_versions'] as Record<string, Object>;
      same('legal_versions fields', sortedKeys(legal), ['agreement', 'privacy']);
      same('legal privacy version', legal['privacy'], 3);
      same('legal agreement version', legal['agreement'], 2);
      same('consent_at = checkbox time', body['consent_at'], q.consentIso(checkedAt));
      // OneTapLoginPort：路径与操作名集中一处；真实 ApiClient 按它发出 POST。
      same('PATH', OneTapLoginPort.PATH, ONE_TAP_PATH);
      const sent: TransportRequest[] = q.fx.rig.server.received.filter((r: TransportRequest): boolean =>
        r.url.indexOf(ONE_TAP_PATH) >= 0);
      same('transport one-tap count', sent.length, 1);
      same('transport url', sent[0].url, API_BASE + ONE_TAP_PATH);
      same('transport method', sent[0].method, 'POST');
      same('transport body is the recorded body', sent[0].body, q.oneTapCalls()[0].body);
      // 会话由 ApiClient 保存（签发会话的操作），登录后计划执行。
      const outcome: LoginOutcome | null = q.flow.outcome;
      same('outcome', outcome === null ? null : outcome.stateRaw, LoginOutcome.LOGGED_IN);
      same('session saved', q.fx.rig.client.sessionAccount(), 'user-7');
      same('login closed', q.fx.host.calls.indexOf('closeLogin') >= 0, true);
    });

    it('credential_before_attempt_response_waits_and_uses_that_attempt', 0, async () => {
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      q.flow.check();
      q.holdAttempts = true;
      const clicked: Promise<void> = q.port.click();
      same('attempt request reached transport', await waitUntil((): boolean => q.heldAttempts.length === 1), true);
      const handled: Promise<void> = q.port.credential(QuickLoginCredential.code(HW_CODE));
      q.releaseAttempt(0);
      await clicked;
      await handled;
      same('one one-tap', q.oneTapCalls().length, 1);
      same('submitted with the click attempt', q.oneTapBodies()[0]['attempt_id'], 'attempt-1');
      same('one attempt', q.callsOf(CREATE_OP).length, 1);
    });

    // ============================================================ 协议未同意（1005300001）→ 我们的确认框（G10）

    it('ac_s1_184_2_agreement_not_accepted_confirm_btn_login_then_continue_and_consent_at_is_confirm_time', 0, async () => {
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      q.linkCode(CODE_K);
      await q.port.click();
      await q.port.credential(QuickLoginCredential.of(QuickLoginCredentialKind.AGREEMENT_NOT_ACCEPTED));
      const keys: AgreementConfirmKeys | null = q.flow.confirm;
      same('confirm shown', keys !== null, true);
      if (keys !== null) {
        same('primary = btn_login', keys.primaryKey, CONFIRM_LOGIN_KEY);
        same('secondary = btn_disagree', keys.secondaryKey, CONFIRM_DISAGREE_KEY);
      }
      same('nothing submitted yet', q.oneTapCalls().length, 0);
      same('pending kept while confirming', q.pending.peek(), CODE_K);
      same('component never told accepted before confirm', q.at('agreement:true'), -1);
      same('no continueLogin before confirm', q.at('continueLogin'), -1);
      q.fx.rig.nowMillis += 20000;
      const confirmedAt: number = q.fx.rig.nowMillis;
      // 确认处理的完成信号：兑现后组件已收到协议状态与 continueLogin（之间可以先取新的授权尝试）。
      await q.flow.confirmAgree();
      same('confirm closed', q.flow.confirm, null);
      same('checkbox synced to checked', q.flow.agreement.checked, true);
      same('setAgreement(true) then continueLogin', q.at('agreement:true') >= 0
        && q.at('agreement:true') < q.at('continueLogin'), true);
      same('continueLogin once', q.count('continueLogin'), 1);
      q.fx.rig.nowMillis += 5000;
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('one one-tap', q.oneTapCalls().length, 1);
      const body: Record<string, Object> = q.oneTapBodies()[0];
      same('consent_at = confirm click time', body['consent_at'], q.consentIso(confirmedAt));
      const creates: Record<string, Object>[] = q.createBodies();
      same('attempt_id from the last attempt taken', body['attempt_id'], 'attempt-' + creates.length);
      same('first attempt taken at the button click', q.at('request:' + CREATE_OP) > q.at('click')
        && q.at('request:' + CREATE_OP) < q.at('credential:' + QuickLoginCredentialKind.AGREEMENT_NOT_ACCEPTED), true);
      same('invite carried', body['invite_code'], CODE_K);
      same('logged in', q.fx.rig.client.sessionAccount(), 'user-7');
    });

    it('cancelled_confirm_keeps_unchecked_no_continue_no_request', 0, async () => {
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      q.linkCode(CODE_K);
      await q.port.click();
      await q.port.credential(QuickLoginCredential.of(QuickLoginCredentialKind.AGREEMENT_NOT_ACCEPTED));
      same('confirm shown', q.flow.confirm !== null, true);
      q.flow.cancelAgree();
      same('confirm closed', q.flow.confirm, null);
      same('still unchecked', q.flow.agreement.checked, false);
      same('no consent time', q.flow.agreement.consentAtMillis, null);
      same('no continueLogin', q.at('continueLogin'), -1);
      same('component never told accepted', q.at('agreement:true'), -1);
      same('stays on quick screen', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
      // 结算点：再点一次仍按未同意走确认框，期间没有提交。
      await q.port.click();
      await q.port.credential(QuickLoginCredential.of(QuickLoginCredentialKind.AGREEMENT_NOT_ACCEPTED));
      same('confirm again', q.flow.confirm !== null, true);
      same('no one-tap', q.oneTapCalls().length, 0);
      same('pending kept', q.pending.peek(), CODE_K);
    });

    // ============================================================ 用户取消 / 组件报错

    it('user_cancel_1001502012_no_prompt_stays_on_quick_screen_and_retry_works', 0, async () => {
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      q.linkCode(CODE_K);
      q.flow.check();
      await q.port.click();
      await q.port.credential(QuickLoginCredential.of(QuickLoginCredentialKind.CANCELLED));
      same('no feedback text', q.flow.feedbackKey, null);
      same('no confirm', q.flow.confirm, null);
      same('stays on quick screen', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
      same('no one-tap', q.oneTapCalls().length, 0);
      same('pending kept', q.pending.peek(), CODE_K);
      same('no outcome', q.flow.outcome, null);
      // 对照：再点一次照常登录，用新的点击取的尝试，带上待绑定码。
      await q.port.click();
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('one one-tap', q.oneTapCalls().length, 1);
      const body: Record<string, Object> = q.oneTapBodies()[0];
      same('attempt of the second click', body['attempt_id'], 'attempt-' + q.callsOf(CREATE_OP).length);
      same('two clicks, two attempts', q.callsOf(CREATE_OP).length, 2);
      same('invite carried', body['invite_code'], CODE_K);
      same('feedback still none', q.flow.feedbackKey, null);
    });

    it('component_errors_go_to_phone_page_without_request', 0, async () => {
      const kinds: string[] = [QuickLoginCredentialKind.NETWORK_ERROR, QuickLoginCredentialKind.ERROR];
      for (const kind of kinds) {
        const q: QuickRig = new QuickRig();
        await q.openQuick();
        q.linkCode(CODE_K);
        q.flow.check();
        await q.port.click();
        await q.port.credential(QuickLoginCredential.of(kind));
        same(kind + ' -> phone page', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
        same(kind + ' no one-tap', q.oneTapCalls().length, 0);
        same(kind + ' pending kept', q.pending.peek(), CODE_K);
      }
    });

    it('credential_without_consent_is_not_submitted', 0, async () => {
      // 组件与页面状态不一致（页面没勾选、也没在确认框同意）时，凭证不提交，待绑定码不动。
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      q.linkCode(CODE_K);
      await q.port.click();
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('no one-tap without consent', q.oneTapCalls().length, 0);
      same('pending kept', q.pending.peek(), CODE_K);
      same('not logged in', q.fx.rig.client.sessionAccount(), null);
    });

    // ============================================================ 待绑定码：随一键登录带上、只消费一次（复用 HM-13c 规则）

    it('one_tap_carries_pending_invite_once_and_duplicate_callback_is_not_resubmitted', 0, async () => {
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      q.linkCode(CODE_K);
      q.flow.check();
      await q.port.click();
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('one one-tap', q.oneTapCalls().length, 1);
      same('invite_code', q.oneTapBodies()[0]['invite_code'], CODE_K);
      same('body fields with invite', sortedKeys(q.oneTapBodies()[0]), ONE_TAP_FIELDS.concat(['invite_code']).sort());
      same('pending cleared after submit', q.pending.peek(), null);
      // 组件重复回调同一凭证：不再提交（同一次点击的尝试只提交一次）。
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('still one one-tap', q.oneTapCalls().length, 1);
      same('pending still empty', q.pending.peek(), null);
    });

    it('code_arriving_while_one_tap_in_flight_survives_settlement', 0, async () => {
      const replies: TransportResponse[] = [envelope(0, loginData(false)), envelope(20004, '{}')];
      for (const reply of replies) {
        for (const first of [CODE_K, '']) {
          const label: string = (first === '' ? 'no-code' : 'with-code') + '/' + reply.status;
          const q: QuickRig = new QuickRig();
          await q.openQuick();
          if (first !== '') {
            q.linkCode(first);
          }
          q.flow.check();
          await q.port.click();
          q.holdOneTap = true;
          const handled: Promise<void> = q.port.credential(QuickLoginCredential.code(HW_CODE));
          same(label + ' one-tap in flight', await waitUntil((): boolean => q.heldOneTaps.length === 1), true);
          same(label + ' submitted code', q.oneTapBodies()[0]['invite_code'], first === '' ? undefined : first);
          q.linkCode(CODE_P);
          q.heldOneTaps[0].resolve(reply);
          await handled;
          same(label + ' code arriving in flight survives', q.pending.peek(), CODE_P);
          same(label + ' one one-tap', q.oneTapCalls().length, 1);
        }
      }
    });

    // ============================================================ R13：华为一键登录的新号不出绑手机页

    it('r13_one_tap_new_or_existing_user_no_bind_phone_and_pending_route_resumes', 0, async () => {
      for (const isNew of [true, false]) {
        const label: string = isNew ? 'new user' : 'existing user';
        const q: QuickRig = new QuickRig();
        q.oneTapReply = (): TransportResponse => envelope(0, loginData(isNew));
        // 游客点了需要手机号的页面 → 守卫先进登录页，记下待办。
        q.fx.openInApp('InviteShare');
        same(label + ' pending action recorded', q.fx.router.hasPendingAction, true);
        await q.openQuick();
        q.flow.check();
        await q.port.click();
        await q.port.credential(QuickLoginCredential.code(HW_CODE));
        const outcome: LoginOutcome | null = q.flow.outcome;
        same(label + ' logged in', outcome === null ? null : outcome.stateRaw, LoginOutcome.LOGGED_IN);
        same(label + ' account has phone', q.fx.phoneBinding.get('user-7'), true);
        same(label + ' guard sees phone bound', q.fx.guardState().sessionState, SessionState.PHONE_BOUND);
        same(label + ' no BindPhone', q.fx.stack.names.indexOf('BindPhone'), -1);
        same(label + ' pending route resumed', q.fx.stack.names.indexOf('InviteShare') >= 0, true);
        same(label + ' pending consumed', q.fx.router.hasPendingAction, false);
        same(label + ' not held', q.fx.service.pendingHeld(), false);
        same(label + ' last method', q.methodStore.read(), LastLoginMethodStore.HUAWEI_ONE_TAP);
      }
    });

    // ============================================================ 第 2 版（tests-14a-review-r1）

    it('g26_server_failures_go_to_phone_page_with_generic_prompt_not_logged_in', 0, async () => {
      // G26：一键登录服务端失败（20004 / 50305 / 网络）转手机号页并给通用提示；不登录、不记上次登录方式。
      const labels: string[] = ['20004', '50305', 'network'];
      for (const label of labels) {
        const q: QuickRig = new QuickRig();
        q.oneTapReply = (): TransportResponse => label === 'network' ? TransportResponse.failed('disconnect') :
          envelope(Number(label), label === '50305' ? '{"provider":"huawei"}' : '{}');
        await q.openQuick();
        q.linkCode(CODE_K);
        q.flow.check();
        await q.port.click();
        await q.port.credential(QuickLoginCredential.code(HW_CODE));
        same(label + ' one one-tap', q.oneTapCalls().length, 1);
        same(label + ' -> phone page', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
        same(label + ' generic prompt', q.flow.feedbackKey, GENERIC_KEY);
        same(label + ' not logged in', q.fx.rig.client.sessionAccount(), null);
        same(label + ' last method not recorded', q.methodStore.read(), null);
        same(label + ' submitted code is not restored (G18)', q.pending.peek(), null);
      }
    });

    it('uncheck_after_click_revokes_consent_and_late_credential_is_not_submitted', 0, async () => {
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      q.linkCode(CODE_K);
      q.flow.check();
      await q.port.click();
      q.fx.rig.nowMillis += 10000;
      q.flow.uncheck();
      same('page unchecked', q.flow.agreement.checked, false);
      same('consent time cleared', q.flow.agreement.consentAtMillis, null);
      same('component told not accepted', q.log[q.log.length - 1], 'agreement:false');
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('no one-tap after uncheck', q.oneTapCalls().length, 0);
      same('pending kept', q.pending.peek(), CODE_K);
      same('not logged in', q.fx.rig.client.sessionAccount(), null);
      // 对照：重新勾选（新的同意时刻）再点，照常登录，consent_at 取新时刻。
      q.fx.rig.nowMillis += 10000;
      const recheckedAt: number = q.fx.rig.nowMillis;
      q.flow.check();
      same('component told accepted again', q.log[q.log.length - 1], 'agreement:true');
      q.fx.rig.nowMillis += 5000;
      await q.port.click();
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('one one-tap', q.oneTapCalls().length, 1);
      const body: Record<string, Object> = q.oneTapBodies()[0];
      same('consent_at = new check time', body['consent_at'], q.consentIso(recheckedAt));
      same('attempt of the new click', body['attempt_id'], 'attempt-' + q.callsOf(CREATE_OP).length);
      same('invite carried', body['invite_code'], CODE_K);
      same('logged in', q.fx.rig.client.sessionAccount(), 'user-7');
    });

    it('other_phone_entry_switches_and_late_credential_is_dropped', 0, async () => {
      // 生产入口「其他手机号登录」：授权尝试未返回 / 已返回两个窗口都切换，迟到凭证不提交、待绑定码不消费。测试不替它作废尝试。
      const windows: string[] = ['attempt_pending', 'attempt_returned'];
      for (const w of windows) {
        const q: QuickRig = new QuickRig();
        await q.openQuick();
        q.linkCode(CODE_K);
        q.flow.check();
        q.holdAttempts = w === 'attempt_pending';
        const clicked: Promise<void> = q.port.click();
        if (w === 'attempt_pending') {
          same(w + ' attempt in flight', await waitUntil((): boolean => q.heldAttempts.length === 1), true);
        } else {
          await clicked;
          same(w + ' attempt returned', q.callsOf(CREATE_OP).length, 1);
        }
        q.flow.otherPhone();
        same(w + ' phone page', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
        same(w + ' huawei first', q.flow.thirdParty, [OAuthProvider.HUAWEI, OAuthProvider.WECHAT]);
        const late: Promise<void> = q.port.credential(QuickLoginCredential.code(HW_CODE));
        if (w === 'attempt_pending') {
          q.releaseAttempt(0);
        }
        await clicked;
        await late;
        same(w + ' no one-tap', q.oneTapCalls().length, 0);
        same(w + ' pending kept', q.pending.peek(), CODE_K);
        same(w + ' not logged in', q.fx.rig.client.sessionAccount(), null);
        same(w + ' still phone page', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
      }
    });

    // ============================================================ 第 3 版（tests-14a-review-r2）

    it('uncheck_or_other_phone_while_credential_waits_for_attempt_is_not_submitted', 0, async () => {
      // 挂起授权尝试 → 凭证到达并开始等待 → 经生产入口取消勾选 / 切到手机号页 → 放行尝试：结算后不提交、码保留、未登录。
      const actions: string[] = ['uncheck', 'other_phone'];
      for (const action of actions) {
        const q: QuickRig = new QuickRig();
        await q.openQuick();
        q.linkCode(CODE_K);
        q.flow.check();
        q.holdAttempts = true;
        const clicked: Promise<void> = q.port.click();
        same(action + ' attempt in flight', await waitUntil((): boolean => q.heldAttempts.length === 1), true);
        const handled: Promise<void> = q.port.credential(QuickLoginCredential.code(HW_CODE));
        if (action === 'uncheck') {
          q.flow.uncheck();
          same(action + ' consent cleared', q.flow.agreement.consentAtMillis, null);
        } else {
          q.flow.otherPhone();
          same(action + ' phone page', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
        }
        q.releaseAttempt(0);
        await clicked;
        await handled;
        same(action + ' no one-tap', q.oneTapCalls().length, 0);
        same(action + ' pending kept', q.pending.peek(), CODE_K);
        same(action + ' not logged in', q.fx.rig.client.sessionAccount(), null);
        same(action + ' last method not recorded', q.methodStore.read(), null);
      }
    });

    it('credential_after_leaving_login_page_is_not_submitted', 0, async () => {
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      q.linkCode(CODE_K);
      q.flow.check();
      await q.port.click();
      same('attempt taken', q.callsOf(CREATE_OP).length, 1);
      // 离开登录页 / 换方式：LoginService 作废本次尝试（同短信与第三方登录）。
      q.fx.service.invalidateAttempt();
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('no one-tap after leaving', q.oneTapCalls().length, 0);
      same('pending kept', q.pending.peek(), CODE_K);
      same('not logged in', q.fx.rig.client.sessionAccount(), null);
    });

    // ============================================================ 第 4 版（变异补测：会话归属与隐私）

    it('stale_one_tap_then_duplicate_credential_is_not_resubmitted_and_new_code_kept', 0, async () => {
      // M34：第一次提交落在不换会话的 STALE（设备签名材料暂缺 → 本地拒绝），页面仍在一键首屏、票据与归属都还有效；
      // 组件再回调同一凭证不得用同一尝试再发一键登录，之后才到的待绑定码不被消费。
      const q: QuickRig = new QuickRig();
      await q.openQuick();
      q.flow.check();
      await q.port.click();
      same('attempt taken', q.callsOf(CREATE_OP).length, 1);
      const secret: string | null = q.fx.rig.credentials.secret;
      q.fx.rig.credentials.secret = null;
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      const first: LoginOutcome | null = q.flow.outcome;
      same('first submit is stale', first === null ? null : first.stateRaw, LoginOutcome.STALE);
      same('first one-tap entered the client', q.oneTapCalls().length, 1);
      same('nothing reached transport', q.fx.rig.server.count(ONE_TAP_PATH), 0);
      same('still quick screen', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
      same('session unchanged (guest)', q.fx.rig.client.sessionAccount(), null);
      same('not busy after settlement', q.flow.busy, false);
      q.fx.rig.credentials.secret = secret;
      q.linkCode(CODE_P);
      // 组件重复回调同一凭证（同一次点击）：结算后断言没有第二次请求、新码未被消费、未登录。
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('still one one-tap', q.oneTapCalls().length, 1);
      same('still nothing on transport', q.fx.rig.server.count(ONE_TAP_PATH), 0);
      same('code arriving after stale is kept', q.pending.peek(), CODE_P);
      same('not logged in', q.fx.rig.client.sessionAccount(), null);
      same('no tokens saved', q.fx.rig.tokens.accessToken(), null);
      // 对照：重新点击取新尝试，照常登录并带上这个码。
      await q.port.click();
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('control: second one-tap', q.oneTapCalls().length, 2);
      const body: Record<string, Object> = q.oneTapBodies()[1];
      same('control: attempt of the new click', body['attempt_id'], 'attempt-2');
      same('control: invite carried', body['invite_code'], CODE_P);
      same('control: pending consumed once', q.pending.peek(), null);
      same('control: logged in', q.fx.rig.client.sessionAccount(), 'user-7');
    });

    it('prefetch_resolving_after_privacy_revoked_leave_or_env_switch_does_not_open_quick_login', 0, async () => {
      // M24：预取挂起期间撤回隐私（基本模式）/ 离开登录页 / 环境变化，再交付号码：不得进入一键首屏，不展示匿名号码，点击也不取授权尝试。
      const changes: string[] = ['none', 'privacy_revoked', 'left_page', 'environment'];
      for (const change of changes) {
        const q: QuickRig = new QuickRig();
        const started: Promise<void> = q.flow.start();
        same(change + ' prefetch pending', await waitUntil((): boolean => q.port.prefetchCalls === 1), true);
        if (change === 'privacy_revoked') {
          q.privacy = false;
        } else if (change === 'left_page') {
          q.fx.service.invalidateAttempt();
        } else if (change === 'environment') {
          q.fx.rig.context.settled = false;
        }
        q.port.resolvePrefetch(QuickLoginPrefetch.phone(ANON_PHONE));
        await started;
        q.delay.fire();
        await q.flow.prefetchSettled();
        if (change === 'none') {
          same('control: quick screen', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
          same('control: phone shown', q.flow.anonymousPhone, ANON_PHONE);
          continue;
        }
        same(change + ' phone page', q.flow.screen, LoginFirstScreen.PHONE_PAGE);
        same(change + ' anonymous phone not exposed', q.flow.anonymousPhone, null);
        same(change + ' huawei first', q.flow.thirdParty, [OAuthProvider.HUAWEI, OAuthProvider.WECHAT]);
        q.flow.check();
        await q.port.click();
        await q.port.credential(QuickLoginCredential.code(HW_CODE));
        same(change + ' no attempt', q.callsOf(CREATE_OP).length, 0);
        same(change + ' no one-tap', q.oneTapCalls().length, 0);
        same(change + ' not logged in', q.fx.rig.tokens.accessToken(), null);
      }
    });

    it('late_prefetch_of_previous_start_does_not_override_new_first_screen', 0, async () => {
      // M23：第一轮 start 的预取挂起，第二轮 start 已定为一键首屏；之后第一轮的号码与计时器迟到，首屏与号码保持第二轮。
      const q: QuickRig = new QuickRig();
      const startA: Promise<void> = q.flow.start();
      const settledA: Promise<void> = q.flow.prefetchSettled();
      same('first prefetch pending', await waitUntil((): boolean => q.port.prefetchCalls === 1), true);
      q.port.nextPrefetch = QuickLoginPrefetch.phone(ANON_PHONE);
      await q.flow.start();
      same('second start: quick screen', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
      same('two prefetches', q.port.prefetchCalls, 2);
      // 先放行 A 轮的号码与计时器，再等 A 轮的 start / 完成信号（实现可以让 A 轮等自己的事件到达后才结算）。
      q.port.resolvePrefetch(QuickLoginPrefetch.phone('139****0001'));
      q.delay.fire();
      await settledA;
      await startA;
      await q.flow.prefetchSettled();
      same('late first-round prefetch does not flip', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
      same('phone of the second round kept', q.flow.anonymousPhone, ANON_PHONE);
      same('third party row of quick screen', q.flow.thirdParty, [OAuthProvider.WECHAT]);
      // 对照：第二轮首屏照常登录。
      q.flow.check();
      await q.port.click();
      await q.port.credential(QuickLoginCredential.code(HW_CODE));
      same('control: one one-tap', q.oneTapCalls().length, 1);
      same('control: logged in', q.fx.rig.client.sessionAccount(), 'user-7');
    });

    it('restart_resets_consent_and_drops_old_attempt_and_in_flight_login', 0, async () => {
      // M69：同一 VM 再次 start（重新打开登录页）：默认未勾选；旧点击的尝试不再可用；在途的一键登录不保存会话、不改变新页面。
      const windows: string[] = ['attempt_taken', 'one_tap_in_flight'];
      for (const w of windows) {
        const q: QuickRig = new QuickRig();
        await q.openQuick();
        q.linkCode(CODE_K);
        q.flow.check();
        await q.port.click();
        let handled: Promise<void> = Promise.resolve();
        if (w === 'one_tap_in_flight') {
          q.holdOneTap = true;
          handled = q.port.credential(QuickLoginCredential.code(HW_CODE));
          same(w + ' one-tap in flight', await waitUntil((): boolean => q.heldOneTaps.length === 1), true);
        }
        await q.openQuick();
        same(w + ' unchecked after restart', q.flow.agreement.checked, false);
        same(w + ' no consent time after restart', q.flow.agreement.consentAtMillis, null);
        same(w + ' component told not accepted', q.log.lastIndexOf('agreement:false') > q.log.lastIndexOf('agreement:true'),
          true);
        if (w === 'one_tap_in_flight') {
          q.heldOneTaps[0].resolve(envelope(0, loginData(false)));
          await handled;
          same(w + ' old login not saved', q.fx.rig.client.sessionAccount(), null);
          same(w + ' no tokens on disk', q.fx.rig.tokens.accessToken(), null);
          same(w + ' no outcome on new page', q.flow.outcome, null);
          same(w + ' last method not recorded', q.methodStore.read(), null);
          same(w + ' login page not closed', q.fx.host.calls.indexOf('closeLogin'), -1);
          same(w + ' not busy', q.flow.busy, false);
        } else {
          // 新页面上用户重新勾选，此时上一轮点击的凭证才迟到：旧尝试已作废，不提交。
          q.flow.check();
          await q.port.credential(QuickLoginCredential.code(HW_CODE));
          same(w + ' old attempt not submitted', q.oneTapCalls().length, 0);
          same(w + ' pending kept', q.pending.peek(), CODE_K);
          same(w + ' not logged in', q.fx.rig.client.sessionAccount(), null);
        }
        same(w + ' still quick screen', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
        // 对照：新一轮勾选 → 点击 → 凭证，用新尝试照常登录。
        q.holdOneTap = false;
        const before: number = q.oneTapCalls().length;
        q.flow.check();
        await q.port.click();
        await q.port.credential(QuickLoginCredential.code(HW_CODE));
        same(w + ' control: one more one-tap', q.oneTapCalls().length, before + 1);
        same(w + ' control: attempt of the new click', q.oneTapBodies()[before]['attempt_id'], 'attempt-2');
        same(w + ' control: logged in', q.fx.rig.client.sessionAccount(), 'user-7');
      }
    });

    it('session_or_environment_changed_after_attempt_returned_is_not_submitted', 0, async () => {
      // M30：取到授权尝试后换了会话（别处登录了另一个账号）或环境，再交付凭证：不发一键登录、不消费码、不覆盖当前账号的会话。
      const changes: string[] = ['none', 'session', 'environment'];
      for (const change of changes) {
        const q: QuickRig = new QuickRig();
        await q.openQuick();
        q.linkCode(CODE_K);
        q.flow.check();
        await q.port.click();
        same(change + ' attempt returned', q.callsOf(CREATE_OP).length, 1);
        if (change === 'session') {
          q.fx.rig.tokens.save(new SessionTokenSet('other-access', 'other-refresh', 'full', 'user-9'));
        } else if (change === 'environment') {
          q.fx.rig.context.settled = false;
        }
        await q.port.credential(QuickLoginCredential.code(HW_CODE));
        if (change === 'none') {
          same('control: one one-tap', q.oneTapCalls().length, 1);
          same('control: invite carried', q.oneTapBodies()[0]['invite_code'], CODE_K);
          same('control: logged in', q.fx.rig.client.sessionAccount(), 'user-7');
          continue;
        }
        same(change + ' no one-tap', q.oneTapCalls().length, 0);
        same(change + ' pending kept', q.pending.peek(), CODE_K);
        same(change + ' last method not recorded', q.methodStore.read(), null);
        same(change + ' login page not closed', q.fx.host.calls.indexOf('closeLogin'), -1);
        if (change === 'session') {
          same('current account session untouched', q.fx.rig.tokens.accessToken(), 'other-access');
          same('current account kept', q.fx.rig.tokens.account(), 'user-9');
        } else {
          same(change + ' no tokens saved', q.fx.rig.tokens.accessToken(), null);
        }
      }
    });

    it('restricted_entry_one_tap_carries_no_invite_and_keeps_pending', 0, async () => {
      // M33：强更入口（受限）的一键登录请求不带待绑定码，码保留；对照：普通入口带上并消费一次。
      for (const restricted of [false, true]) {
        const label: string = restricted ? 'restricted' : 'control';
        const q: QuickRig = new QuickRig(null, restricted);
        await q.openQuick();
        q.linkCode(CODE_K);
        q.flow.check();
        await q.port.click();
        await q.port.credential(QuickLoginCredential.code(HW_CODE));
        same(label + ' one one-tap', q.oneTapCalls().length, 1);
        const body: Record<string, Object> = q.oneTapBodies()[0];
        if (restricted) {
          same(label + ' no invite_code', body['invite_code'], undefined);
          same(label + ' body fields', sortedKeys(body), ONE_TAP_FIELDS);
          same(label + ' pending kept', q.pending.peek(), CODE_K);
        } else {
          same(label + ' invite carried', body['invite_code'], CODE_K);
          same(label + ' pending consumed', q.pending.peek(), null);
        }
      }
    });

    // ============================================================ Debug 假实现（core staging；entry 一行转发）

    it('debug_quick_login_fake_six_scenes', 0, async () => {
      const prefetchExpect: string[][] = [
        [DebugHuaweiQuickLoginScene.PHONE, ''],
        [DebugHuaweiQuickLoginScene.NOT_LOGGED_IN, QuickLoginFallback.NOT_LOGGED_IN],
        [DebugHuaweiQuickLoginScene.NO_PERMISSION, QuickLoginFallback.NO_PERMISSION],
        [DebugHuaweiQuickLoginScene.AGREEMENT_NOT_ACCEPTED, ''],
        [DebugHuaweiQuickLoginScene.USER_CANCEL, ''],
        [DebugHuaweiQuickLoginScene.NETWORK_ERROR, '']
      ];
      same('scene ids', [DebugHuaweiQuickLoginScene.NOT_LOGGED_IN, DebugHuaweiQuickLoginScene.NO_PERMISSION,
        DebugHuaweiQuickLoginScene.AGREEMENT_NOT_ACCEPTED, DebugHuaweiQuickLoginScene.USER_CANCEL],
        ['1001502001', '1001502014', '1005300001', '1001502012']);
      for (const row of prefetchExpect) {
        const scene: string = row[0];
        const fake: DebugHuaweiQuickLogin = new DebugHuaweiQuickLogin((): string => scene);
        const p: QuickLoginPrefetch = await fake.prefetchAnonymousPhone();
        if (row[1] === '') {
          same(scene + ' has phone', p.anonymousPhone !== null && (p.anonymousPhone as string).length > 0, true);
          same(scene + ' no fallback', p.fallback, null);
        } else {
          same(scene + ' fallback', p.fallback, row[1]);
          same(scene + ' no phone', p.anonymousPhone, null);
        }
      }
      // 按钮结果：点击先于结果回调；有号码 / 取消 / 网络错误在协议已同意时各回一种；协议未同意回 1005300001，同意后 continueLogin 拿到凭证。
      const tapExpect: string[][] = [
        [DebugHuaweiQuickLoginScene.PHONE, QuickLoginCredentialKind.CREDENTIAL],
        [DebugHuaweiQuickLoginScene.USER_CANCEL, QuickLoginCredentialKind.CANCELLED],
        [DebugHuaweiQuickLoginScene.NETWORK_ERROR, QuickLoginCredentialKind.NETWORK_ERROR]
      ];
      for (const row of tapExpect) {
        const scene: string = row[0];
        const fake: DebugHuaweiQuickLogin = new DebugHuaweiQuickLogin((): string => scene);
        const events: string[] = [];
        const codes: (string | null)[] = [];
        fake.listen((): Promise<void> => {
          events.push('click');
          return Promise.resolve();
        }, (r: QuickLoginCredential): Promise<void> => {
          events.push(r.kind);
          codes.push(r.authorizationCode);
          return Promise.resolve();
        });
        fake.setAgreement(true);
        await fake.tap();
        same(scene + ' events', events, ['click', row[1]]);
        if (row[1] === QuickLoginCredentialKind.CREDENTIAL) {
          same(scene + ' code present', codes[0] !== null && (codes[0] as string).length > 0, true);
        } else {
          same(scene + ' no code', codes[0], null);
        }
      }
      const agree: DebugHuaweiQuickLogin = new DebugHuaweiQuickLogin((): string =>
      DebugHuaweiQuickLoginScene.AGREEMENT_NOT_ACCEPTED);
      const seen: string[] = [];
      agree.listen((): Promise<void> => {
        seen.push('click');
        return Promise.resolve();
      }, (r: QuickLoginCredential): Promise<void> => {
        seen.push(r.kind);
        return Promise.resolve();
      });
      await agree.tap();
      same('1005300001 events', seen, ['click', QuickLoginCredentialKind.AGREEMENT_NOT_ACCEPTED]);
      agree.setAgreement(true);
      agree.continueLogin();
      same('continueLogin delivers credential', await waitUntil((): boolean => seen.length === 3), true);
      same('1005300001 then credential', seen[2], QuickLoginCredentialKind.CREDENTIAL);
    });

    it('debug_quick_login_fake_drives_flow_phone_and_not_logged_in', 0, async () => {
      const phone: DebugHuaweiQuickLogin = new DebugHuaweiQuickLogin((): string => DebugHuaweiQuickLoginScene.PHONE);
      const q: QuickRig = new QuickRig(phone);
      await q.flow.start();
      same('debug phone -> quick login', q.flow.screen, LoginFirstScreen.QUICK_LOGIN);
      q.flow.check();
      await phone.tap();
      same('one attempt', q.callsOf(CREATE_OP).length, 1);
      same('one one-tap', q.oneTapCalls().length, 1);
      const body: Record<string, Object> = q.oneTapBodies()[0];
      same('attempt id', body['attempt_id'], 'attempt-1');
      same('code from fake', typeof body['authorization_code'] === 'string'
        && (body['authorization_code'] as string).length > 0, true);
      const outcome: LoginOutcome | null = q.flow.outcome;
      same('logged in', outcome === null ? null : outcome.stateRaw, LoginOutcome.LOGGED_IN);

      const out: DebugHuaweiQuickLogin = new DebugHuaweiQuickLogin((): string => DebugHuaweiQuickLoginScene.NOT_LOGGED_IN);
      const q2: QuickRig = new QuickRig(out);
      await q2.flow.start();
      same('debug 1001502001 -> phone page', q2.flow.screen, LoginFirstScreen.PHONE_PAGE);
      same('huawei first', q2.flow.thirdParty, [OAuthProvider.HUAWEI, OAuthProvider.WECHAT]);
    });

    // ============================================================ 普通华为授权适配器（R05 / R12）

    it('normal_huawei_debug_adapter_logs_in_by_huawei_without_invite', 0, async () => {
      const q: QuickRig = new QuickRig();
      const service: OAuthLoginService = new OAuthLoginService(q.fx.rig.client, q.fx.service,
        [new DebugHuaweiAuthAdapter()], q.fx.phoneBinding, new LegalVersions(3, 2), never);
      same('debug huawei visible', service.visibleProviders().indexOf(OAuthProvider.HUAWEI) >= 0, true);
      q.linkCode(CODE_K);
      const consentAt: number = q.fx.rig.nowMillis;
      const outcome: OAuthLoginOutcome = await service.loginWith(OAuthProvider.HUAWEI, consentAt);
      same('logged in', outcome.stateRaw, OAuthLoginOutcome.LOGGED_IN);
      same('attempt provider huawei', q.createBodies()[0]['provider'], 'huawei');
      const calls: ApiRequest[] = q.callsOf(HUAWEI_OP);
      same('one loginByHuawei', calls.length, 1);
      const body: Record<string, Object> = bodyOf(calls[0]);
      same('loginByHuawei fields', sortedKeys(body), ['attempt_id', 'authorization_code', 'consent_at', 'legal_versions']);
      same('authorization code present', typeof body['authorization_code'] === 'string'
        && (body['authorization_code'] as string).length > 0, true);
      same('no one-tap', q.oneTapCalls().length, 0);
      same('pending kept for backfill prefill', q.pending.peek(), CODE_K);
    });

    it('release_huawei_adapter_hidden_and_sends_nothing', 0, async () => {
      const q: QuickRig = new QuickRig();
      const adapter: UnavailableHuaweiAdapter = new UnavailableHuaweiAdapter();
      same('provider', adapter.provider, OAuthProvider.HUAWEI);
      same('not available', adapter.adapterAvailable(), false);
      const service: OAuthLoginService = new OAuthLoginService(q.fx.rig.client, q.fx.service, [adapter],
        q.fx.phoneBinding, new LegalVersions(3, 2), never);
      same('hidden', service.visibleProviders().indexOf(OAuthProvider.HUAWEI), -1);
      const outcome: OAuthLoginOutcome = await service.loginWith(OAuthProvider.HUAWEI, q.fx.rig.nowMillis);
      same('unavailable', outcome.stateRaw, OAuthLoginOutcome.UNAVAILABLE);
      same('nothing sent', q.client.calls.length, 0);
      // 对照：同一装配里可用的华为适配器会出现在第三方行里（QuickRig.huawei），不可用时隐藏。
      same('available fake visible', q.oauth.visibleProviders().indexOf(OAuthProvider.HUAWEI) >= 0, true);
      q.huawei.available = false;
      same('unavailable fake hidden', q.oauth.visibleProviders().indexOf(OAuthProvider.HUAWEI), -1);
      q.capable = false;
      q.port.nextPrefetch = QuickLoginPrefetch.phone(ANON_PHONE);
      await q.flow.start();
      same('phone page without huawei when unavailable', q.flow.thirdParty, [OAuthProvider.WECHAT]);
    });
  });
}
