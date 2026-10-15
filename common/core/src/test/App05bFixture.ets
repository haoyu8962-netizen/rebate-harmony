// APP-05b 测试的公共装配：本地假服务（FakeServer，不连任何地址）+ 真实 ApiClient + 真实 Router / StackNavigator / RoutingSync +
// 生产的登录出口 RouterLoginHost（与 entry AppLogin 同一份代码）+ LoginService / OAuthLoginService / BindPhoneService。
// 第三方 SDK 用可控的假适配器（测试替身只替代 SDK，不替代被测的执行器）。
import {
  BindPhoneHost, BindPhoneService, ErrorEffect, GuardDecision, GuardState, LaunchReadiness, LegalVersions, LoginHost, LoginService,
  MemoryPendingBackend, MemorySessionTokens, OAuthLoginService, OAuthProvider, PathStack, PendingActionStore,
  PhoneBindingState, PrivacyState, RouteDestination, RouteRequest, RouteSource, Router, RouterLoginHost, RouteTable,
  RoutingSync, SessionTokenSet, StackNavigator, ThirdPartyAuthAdapter, ThirdPartyAuthKind, ThirdPartyAuthResult,
  TransportRequest, TransportResponse, UpdateCheckStatus, UpdateNetworkPort, UpdateState
} from '../../Index';
import { RouteSpec } from 'generated';
import { Deferred, envelope, Rig } from './NetworkTestRig';

/** 内存导航栈：与 NavPathStack 的同名方法同义。 */
export class MemoryPathStack implements PathStack {
  names: string[] = [];

  pushPathByName(name: string, _param: Object): void {
    this.names.push(name);
  }

  clear(): void {
    this.names = [];
  }

  removeByName(name: string): void {
    this.names = this.names.filter((n: string) => n !== name);
  }

  getAllPathName(): string[] {
    return this.names.slice();
  }
}

const TAB_ROOTS: string[] = ['Home', 'AgentChat', 'OrderList', 'Me'];

/** 只记录调用顺序、原样交给生产出口 RouterLoginHost。 */
export class RecordingRouterHost implements LoginHost {
  readonly calls: string[] = [];
  private readonly inner: RouterLoginHost;

  constructor(inner: RouterLoginHost) {
    this.inner = inner;
  }

  updateState(): string {
    return this.inner.updateState();
  }

  hasPendingAction(): boolean {
    return this.inner.hasPendingAction();
  }

  closeLogin(): void {
    this.calls.push('closeLogin');
    this.inner.closeLogin();
  }

  resumePending(): void {
    this.calls.push('resumePending');
    this.inner.resumePending();
  }

  discardPending(): void {
    this.calls.push('discardPending');
    this.inner.discardPending();
  }

  enterForceUpdate(): void {
    this.calls.push('enterForceUpdate');
    this.inner.enterForceUpdate();
  }

  sessionChanged(): void {
    this.calls.push('sessionChanged');
    this.inner.sessionChanged();
  }

  sessionEnded(): void {
    this.calls.push('sessionEnded');
    this.inner.sessionEnded();
  }

  sessionSynced(): void {
    this.calls.push('sessionSynced');
    this.inner.sessionSynced();
  }
}

/** 可控的第三方适配器（只替代 SDK）：authorize 交给 pending，由测试兑现。 */
export class FakeAuthAdapter implements ThirdPartyAuthAdapter {
  readonly provider: string = OAuthProvider.WECHAT;
  available: boolean = true;
  installedRaw: boolean | null = true;
  readonly nonces: string[] = [];
  /** 每次授权的结果；为 null 时挂起，等测试调 resolve。 */
  next: ThirdPartyAuthResult | null = null;
  private resolvers: ((r: ThirdPartyAuthResult) => void)[] = [];

  adapterAvailable(): boolean {
    return this.available;
  }

  installed(): boolean | null {
    return this.installedRaw;
  }

  authorize(nonce: string): Promise<ThirdPartyAuthResult> {
    this.nonces.push(nonce);
    const fixed: ThirdPartyAuthResult | null = this.next;
    if (fixed !== null) {
      return Promise.resolve(fixed);
    }
    return new Promise<ThirdPartyAuthResult>((resolve: (r: ThirdPartyAuthResult) => void): void => {
      this.resolvers.push(resolve);
    });
  }

  /** 兑现最早一个挂起的授权（迟到回调也从这里来）。 */
  resolve(result: ThirdPartyAuthResult): void {
    const first: ((r: ThirdPartyAuthResult) => void) | undefined = this.resolvers.shift();
    if (first !== undefined) {
      first(result);
    }
  }

  static credential(code: string, state: string): ThirdPartyAuthResult {
    return new ThirdPartyAuthResult(ThirdPartyAuthKind.CREDENTIAL, code, state);
  }
}

export class RecordingBindHost implements BindPhoneHost {
  bound: number = 0;

  phoneBound(): void {
    this.bound++;
  }
}

/** 第三方登录响应的 data。 */
export function oauthLoginData(isNew: boolean, userId: string = 'user-9'): string {
  return '{"user_id":"' + userId + '","is_new_user":' + isNew + ',"tokens":{"access_token":"oauth-access",'
    + '"access_expires_at":"2026-10-08T11:30:00+08:00","refresh_token":"oauth-refresh",'
    + '"refresh_expires_at":"2026-11-07T09:30:00+08:00","session_scope":"full"}}';
}

export class OAuthFixture {
  readonly rig: Rig;
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly store: PendingActionStore;
  readonly router: Router;
  readonly sync: RoutingSync;
  readonly inner: RouterLoginHost;
  readonly host: RecordingRouterHost;
  readonly service: LoginService;
  readonly phoneBinding: PhoneBindingState = new PhoneBindingState();
  readonly adapter: FakeAuthAdapter = new FakeAuthAdapter();
  readonly oauth: OAuthLoginService;
  readonly bindHost: RecordingBindHost = new RecordingBindHost();
  readonly bind: BindPhoneService;
  status: UpdateCheckStatus = UpdateCheckStatus.finished(UpdateState.OK);
  tab: string = 'Home';
  /** 授权等待的超时（OAuthLoginService.delay）：测试调 fireTimeout 才到期。 */
  private timeouts: (() => void)[] = [];
  /** 微信登录响应：is_new_user 与是否挂起。 */
  newUser: boolean = false;
  loginDeferred: Deferred | null = null;
  attemptCounter: number = 0;
  /** /v1/me 的 phone_bound。 */
  phoneBound: boolean = false;
  /** 持久化的 pending_action（冷启动测试把它交给新的装配，模拟进程重启后读到的记录）。 */
  readonly backend: MemoryPendingBackend;
  /** 状态同步前补查 phone_bound（与 AppRouting.syncSession → AppLogin.ensurePhoneBindingKnown 同义，R2-01）。 */
  verifyOnSync: boolean = false;
  /** 每次状态同步之后调用（与 AppRouting.stateChanged → syncMe → AppMe.sync 同义，FU-HM-0721 R1-01）；缺省什么都不做。 */
  syncMe: () => void = () => {
  };

  constructor(tokens: MemorySessionTokens | null = null, backend: MemoryPendingBackend | null = null) {
    const port: UpdateNetworkPort = new UpdateNetworkPort((): UpdateState => this.status.result ?? UpdateState.UNKNOWN,
      (_m: string | null): void => {
        this.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      });
    this.rig = new Rig(null, null, tokens, null, port);
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => {
      if (d.route === null || TAB_ROOTS.indexOf(d.route) < 0) {
        return false;
      }
      this.tab = d.route;
      return true;
    };
    this.backend = backend ?? new MemoryPendingBackend();
    this.store = new PendingActionStore(this.backend, (): number => this.rig.nowMillis);
    this.router = new Router(this.store, (): GuardState => this.guardState(), this.navigator,
      (name: string): RouteSpec | undefined => RouteTable.spec(name), (): LaunchReadiness => this.readiness());
    this.sync = new RoutingSync(this.router, this.navigator, (): boolean => true);
    this.inner = new RouterLoginHost(this.router, this.navigator, (): UpdateCheckStatus => this.status,
      (): void => {
        this.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      }, (resumePending: boolean): void => this.stateChanged(resumePending));
    this.host = new RecordingRouterHost(this.inner);
    this.service = new LoginService(this.rig.client, this.rig.tokens, this.host, new LegalVersions(3, 2),
      (): number => this.rig.nowMillis);
    this.inner.watchLoginPage(this.service);
    // 与 AppLogin 同：短信登录的账号记为已绑手机（R2-01）。
    this.service.onPhoneVerifiedSession = (account: string | null): void => this.phoneBinding.set(account, true);
    this.oauth = new OAuthLoginService(this.rig.client, this.service, [this.adapter], this.phoneBinding,
      new LegalVersions(3, 2), (_ms: number): Promise<void> => new Promise<void>((resolve: () => void): void => {
        this.timeouts.push(resolve);
      }));
    this.bind = new BindPhoneService(this.rig.client, this.service.deadlines, this.phoneBinding, this.bindHost,
      (): number => this.rig.nowMillis);
    // App 的会话级回调（AppNetwork）：Router 记下网络层清除原会话的分界（APP-05a 共性 25、26）。
    this.rig.onSessionEffect = (_e: ErrorEffect, clearedGeneration: number): void => {
      this.router.markSessionCleared(clearedGeneration);
    };
    this.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => this.answer(r);
  }

  answer(r: TransportRequest): Promise<TransportResponse> {
    if (r.url.indexOf('/v1/auth/oauth-attempts') >= 0) {
      this.attemptCounter++;
      return Promise.resolve(envelope(0, '{"attempt_id":"attempt-' + this.attemptCounter + '","nonce":"nonce-'
        + this.attemptCounter + '","expire_at":"2026-10-08T09:40:00+08:00"}'));
    }
    if (r.url.indexOf('/v1/auth/login/wechat') >= 0) {
      const deferred: Deferred | null = this.loginDeferred;
      if (deferred !== null) {
        return deferred.promise;
      }
      return Promise.resolve(envelope(0, oauthLoginData(this.newUser)));
    }
    if (r.url.indexOf('/v1/me/phone') >= 0) {
      const body: Record<string, Object> = JSON.parse(r.body ?? '{}') as Record<string, Object>;
      if (body['phone'] === '13800005678') {
        return Promise.resolve(envelope(30411, '{"reason":"mergeable","merge_ticket":"test-merge-ticket"}'));
      }
      if (body['phone'] === '13800001111') {
        return Promise.resolve(envelope(30411, '{}'));
      }
      if (body['code'] === '123456') {
        this.phoneBound = true;
        return Promise.resolve(envelope(0, '{}'));
      }
      return Promise.resolve(envelope(20002, '{}'));
    }
    if (r.url.indexOf('/v1/me') >= 0) {
      return Promise.resolve(envelope(0, '{"user_id":"user-9","phone_bound":' + this.phoneBound + '}'));
    }
    if (r.url.indexOf('/v1/auth/login/sms') >= 0) {
      return Promise.resolve(envelope(0, oauthLoginData(false, 'user-5')));
    }
    if (r.url.indexOf('/v1/auth/sms-codes') >= 0) {
      return Promise.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
    }
    return Promise.resolve(envelope(0, '{}'));
  }

  fireTimeout(): void {
    const list: (() => void)[] = this.timeouts;
    this.timeouts = [];
    for (const resolve of list) {
      resolve();
    }
  }

  readiness(): LaunchReadiness {
    return new LaunchReadiness(true, PrivacyState.CONSENTED, this.status);
  }

  guardState(): GuardState {
    return new GuardState('consented', this.status.result ?? UpdateState.UNKNOWN,
      RouterLoginHost.sessionState(this.rig.client, this.rig.tokens, this.phoneBinding), true, '1.0.0', false, false);
  }

  stateChanged(resumePending: boolean = true): void {
    if (this.verifyOnSync) {
      this.oauth.verifyPhoneBinding();
    }
    this.sync.sync(this.readiness(), this.rig.nowMillis, resumePending);
    this.syncMe();
  }

  openInApp(route: string): GuardDecision {
    return this.router.open(RouteRequest.of(route, RouteSource.IN_APP));
  }

  count(pathPart: string): number {
    return this.rig.server.count(pathPart);
  }

  bodyOf(pathPart: string): Record<string, Object> {
    return JSON.parse(this.rig.server.last(pathPart).body ?? '{}') as Record<string, Object>;
  }

  static session(account: string = 'user-1'): MemorySessionTokens {
    return new MemorySessionTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', account));
  }
}
