import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, BindPhoneHost, BindPhoneService, ConfigStore, LoginOutcome, LoginService, OAuthLoginOutcome, OAuthLoginRoute,
  OAuthLoginService, OAuthProvider, PhoneBindingState, RouterLoginHost, RoutePolicy, SessionState, SessionTokens
} from 'core';
import { CouliDialog, CouliDialogOptions, CouliToast } from 'designsystem';
import { BindPhonePageConfig, LoginPageConfig, LoginTexts } from 'auth';
import { AppClientCore } from '../clientcore/AppClientCore';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppNetwork } from '../network/AppNetwork';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';
import { AppClipboard } from '../clipboard/AppClipboard';
import { LoginDraftTexts } from './LoginDraftTexts';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliLogin';
const AGREEMENT_ROUTE: string = 'Agreement';
const SETTINGS_ROUTE: string = 'Settings';
const HELP_ROUTE: string = 'Help';
const ME_ROUTE: string = 'Me';

/** 绑手机成功（getMe 已刷新）：会话状态变化，并按「完成了前置步骤」恢复待办（Router.prerequisiteCompleted）。 */
class AppBindPhoneHost implements BindPhoneHost {
  phoneBound(): void {
    AppLogin.shared.phoneBound();
  }
}

/** 登录页的文案来源：契约字典 → 草稿表（LoginDraftTexts，待定稿不得提审）。 */
class AppLoginTexts implements LoginTexts {
  text(key: string): string {
    return LoginDraftTexts.text(key);
  }

  format(key: string, vars: Map<string, string>): string {
    return LoginDraftTexts.format(key, vars);
  }
}

/**
 * App 侧的登录（APP-05a）：组合 LoginService（ApiClient、会话令牌、Router 出口），给登录页配置，给守卫会话状态，登出。
 * 会话状态见 RouterLoginHost.sessionState（游客 / 受限 / 已绑手机）。
 */
export class AppLogin {
  static readonly shared: AppLogin = new AppLogin();

  private service: LoginService | null = null;
  private oauth: OAuthLoginService | null = null;
  private bindService: BindPhoneService | null = null;
  /** 本机已知的「是否绑了手机」（第三方登录未绑手机的会话 → 守卫的 LOGGED_IN）。 */
  readonly phoneBinding: PhoneBindingState = new PhoneBindingState();
  /** 第三方新号登录后保留着待办、等绑手机引导结束（【暂不】、绑定完成、离开绑手机页）再恢复。 */
  private guideHolding: boolean = false;
  /** 最近一次第三方登录的方式（并号确认文案 {provider_name}）。 */
  private lastProvider: string = OAuthProvider.WECHAT;
  private hostInstance: RouterLoginHost | null = null;
  private readonly texts: AppLoginTexts = new AppLoginTexts();
  /** 刷新失败清会话后跳登录（LoginSessionExpired）：下一次打开的登录页提示一次。 */
  private sessionExpiredPending: boolean = false;
  /** 登录成功后显示邀请结果要用的界面上下文（RootPage 挂上）。 */
  private ui: UIContext | null = null;

  attachUi(ui: UIContext): void {
    this.ui = ui;
  }

  /**
   * LoginService 的出口：Core RouterLoginHost（与登录集成测试同一份代码，harmony-review-r1 R1-01 / R1-02）。
   * 「状态变化」接 AppRouting.stateChanged（Router 与强更页同步在 Core RoutingSync）。
   */
  private get host(): RouterLoginHost {
    if (this.hostInstance === null) {
      const routing: AppRouting = AppRouting.shared;
      this.hostInstance = new RouterLoginHost(routing.router, routing.navigator, () => AppUpdate.shared.routerStatus(),
        () => AppUpdate.shared.on10405(null), (resumePending: boolean) => routing.stateChanged(resumePending));
    }
    return this.hostInstance;
  }

  /** 网络组合之后才有；之前为 null（登录页显示占位）。 */
  loginService(): LoginService | null {
    if (this.service !== null) {
      return this.service;
    }
    const client: ApiClient | null = AppNetwork.client;
    const tokens: SessionTokens | null = AppNetwork.tokens;
    if (client === null || tokens === null) {
      return null;
    }
    const service: LoginService = new LoginService(client, tokens, this.host);
    // R2-01：登录页确定出栈（关闭、清栈、强更替换导航栈）的同步出口立即作废本次尝试；系统返回由页面 onWillDisappear 兜住。
    this.host.watchLoginPage(service);
    // R2-01：短信登录的账号一定有手机号；其余（第三方登录、冷启动未知）要等 getMe 查清。
    service.onPhoneVerifiedSession = (account: string | null): void => this.phoneBinding.set(account, true);
    this.service = service;
    return service;
  }

  /**
   * 第三方登录执行器（APP-05b）：微信适配器由构建变体给（Release 恒为不可用实现，按钮不显示；Debug / Staging 打开本机假服务时
   * 用假适配器，供测试与截图）。网络组合之后才有。
   */
  oauthService(): OAuthLoginService | null {
    if (this.oauth !== null) {
      return this.oauth;
    }
    const login: LoginService | null = this.loginService();
    const client: ApiClient | null = AppNetwork.client;
    if (login === null || client === null) {
      return null;
    }
    const oauth: OAuthLoginService = new OAuthLoginService(client, login, [BuildVariant.wechatAdapter()],
      this.phoneBinding);
    // /v1/config.invite.bind_phone_guide（缺省 on，BR-INV-21）。
    oauth.guideEnabled = (): boolean => AppLogin.inviteFlag('bind_phone_guide');
    this.oauth = oauth;
    return oauth;
  }

  /** 绑手机页执行器（与短信登录共用按号码的发码截止时间）。 */
  bindPhoneService(): BindPhoneService | null {
    if (this.bindService !== null) {
      return this.bindService;
    }
    const login: LoginService | null = this.loginService();
    const client: ApiClient | null = AppNetwork.client;
    if (login === null || client === null) {
      return null;
    }
    this.bindService = new BindPhoneService(client, login.deadlines, this.phoneBinding, new AppBindPhoneHost());
    return this.bindService;
  }

  /** /v1/config.invite.<name> 开关（当前 → LKG → 包内）；取不到按缺省 on（BR-INV-21）。 */
  static inviteFlag(name: string): boolean {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const text: string | null = store === null ? null : store.value('invite');
    if (text === null) {
      return true;
    }
    try {
      const invite: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      return invite[name] !== false;
    } catch (e) {
      return true;
    }
  }

  /**
   * 状态同步前（AppRouting.stateChanged 开头）调用（R2-01，共性 8）：有会话但 phone_bound 不知道（冷启动）或待查时查一次 getMe；
   * 查清后经 Router 守卫按冷启动口径恢复待办，失败保留待办、下次同步再查。没有会话、已查清或正在查时什么都不做。
   */
  ensurePhoneBindingKnown(): void {
    const oauth: OAuthLoginService | null = this.oauthService();
    if (oauth === null) {
      return;
    }
    oauth.verifyPhoneBinding().catch((): boolean => false);
  }

  /** 守卫用的会话状态。 */
  sessionState(): SessionState {
    return RouterLoginHost.sessionState(AppNetwork.client, AppNetwork.tokens, this.phoneBinding);
  }

  get loggedIn(): boolean {
    return this.sessionState() !== SessionState.GUEST;
  }

  /** 网络层刷新失败清会话、要跳登录（clear_session_login）：记下，登录页出现时提示 error.10404。 */
  markSessionExpired(): void {
    this.sessionExpiredPending = true;
    // 会话已由网络层清除：Router 清 pending 之外的状态由守卫现算；这里只让守卫重算一次。
    AppRouting.shared.stateChanged();
  }

  /** 登录页配置（RootPage 的 Login 路由用）。restricted：从强更页进入（APP-02c 标记）。 */
  pageConfig(restricted: boolean): LoginPageConfig | null {
    const service: LoginService | null = this.loginService();
    if (service === null) {
      return null;
    }
    const config: LoginPageConfig = new LoginPageConfig(service, this.texts);
    config.restricted = restricted;
    // APP-07：邀请码行【粘贴】（PasteButton）与游客邀请确认的预填（进入验证码页时取一次）。
    AppClipboard.shared.bindLogin(config, restricted);
    config.sessionExpired = this.sessionExpiredPending;
    this.sessionExpiredPending = false;
    // LoginPublicHarmony 的【华为账号登录】：HM-08 / APP-13 才做，只在 Debug / Staging 构建显示占位（版式比对用），Release 不显示。
    config.showThirdPartySlot = BuildVariant.IS_DEBUG_BUILD;
    // 第三方登录（APP-05b）：按钮由适配器决定（Release 微信适配器不可用 → 不显示）。
    config.oauth = this.oauthService();
    config.onOAuthLoggedIn = (outcome: OAuthLoginOutcome): void => {
      this.lastProvider = OAuthProvider.WECHAT;
      if (outcome.routeRaw === OAuthLoginRoute.BIND_PHONE_GUIDE) {
        this.guideHolding = true;
        // 等登录页出栈、页面同步之后再弹（同邀请结果）。
        setTimeout(() => this.showBindPhoneGuide(), 350);
      }
    };
    config.onClose = (): void => {
      AppRouting.shared.navigator.remove(RoutePolicy.LOGIN);
    };
    config.onForceUpdate = (): void => {
      AppRouting.shared.navigator.remove(RoutePolicy.LOGIN);
      AppRouting.shared.stateChanged();
    };
    config.onSettings = (): void => {
      AppRouting.shared.openInApp(SETTINGS_ROUTE);
    };
    config.onHelp = (): void => {
      // login.help_entry：help_links.login_help 未配置时打开帮助中心首页（BR-TEXT-14 表 C）。TODO(N-26)：接 help_links.login_help。
      AppRouting.shared.openInApp(HELP_ROUTE);
    };
    config.onAgreement = (type: string): void => {
      const params: Record<string, Object> = {};
      params['type'] = type;
      if (restricted) {
        AppRouting.shared.openFromForceUpdatePage(AGREEMENT_ROUTE, params);
      } else {
        AppRouting.shared.openInApp(AGREEMENT_ROUTE, params);
      }
    };
    config.onCustomerService = (): void => AppLogin.openCustomerService();
    config.onLoggedIn = (outcome: LoginOutcome): void => {
      this.showInviteResult(outcome);
    };
    return config;
  }

  /**
   * 登录成功后的邀请绑定结果（LoginInviteBound / LoginInviteFailed；BR-INV-06 细则）：bound → 轻提示；failed → 弹窗，
   * 【去补填】打开「我的」（补填页另有任务）；ignored_existing_user 不提示。不改变登录后的路由计划（AFTER-03）。
   */
  private showInviteResult(outcome: LoginOutcome): void {
    const ui: UIContext | null = this.ui;
    if (ui === null || outcome.inviteResult === null) {
      return;
    }
    if (outcome.inviteResult === 'bound') {
      CouliToast.show(ui, LoginDraftTexts.text('login.invite_bound'));
      return;
    }
    if (outcome.inviteResult !== 'failed') {
      return;
    }
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = LoginDraftTexts.text('login.invite_failed.title');
    options.message = LoginDraftTexts.text(outcome.inviteCode === 42901 ? 'login.invite_failed.rate_limited' :
      'login.invite_failed.body');
    options.primaryText = LoginDraftTexts.text('login.invite_failed.backfill');
    options.secondaryText = LoginDraftTexts.text('login.invite_failed.ok');
    options.onPrimary = (): void => {
      AppRouting.shared.openInApp(ME_ROUTE);
    };
    // 等登录页出栈、恢复的页面推入之后再弹。
    setTimeout(() => CouliDialog.open(ui, options), 350);
  }

  /**
   * LoginBindPhoneGuide（BR-INV-03 细则 ①）：第三方新号登录成功后一次、可跳过。【去绑定】进 BindPhone；【暂不】、点遮罩或系统
   * 返回 → 继续执行登录前登记的待办。TODO(N-29) INVITE-STATE：购买触发的登录应换用 body_before_buy 并记 ② 已读，需要购买
   * pending_action 的识别与 tips 接口，本任务未接；先用通用正文。
   */
  private showBindPhoneGuide(): void {
    const ui: UIContext | null = this.ui;
    if (ui === null) {
      this.releaseHeldPending();
      return;
    }
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = LoginDraftTexts.text('invite.bind_phone_guide.title');
    options.message = LoginDraftTexts.text('invite.bind_phone_guide.body');
    options.primaryText = LoginDraftTexts.text('invite.bind_phone_guide.go');
    options.secondaryText = LoginDraftTexts.text('invite.bind_phone_guide.skip');
    options.onPrimary = (): void => {
      AppRouting.shared.openInApp(RoutePolicy.BIND_PHONE);
    };
    options.onSecondary = (): void => this.releaseHeldPending();
    options.onDismissed = (): void => this.releaseHeldPending();
    CouliDialog.open(ui, options);
  }

  /** 引导结束、未绑定就离开绑手机页：恢复登录时保留的待办（Router 守卫照常判定，敏感操作不自动恢复）。 */
  private releaseHeldPending(): void {
    if (!this.guideHolding) {
      return;
    }
    this.guideHolding = false;
    this.loginService()?.resumeHeldPending();
  }

  /** 绑手机成功（BindPhoneService 已刷新 getMe）：守卫重算会话状态，按「完成前置」恢复待办。 */
  phoneBound(): void {
    this.guideHolding = false;
    // R2-02：绑定完成——明确释放暂缓，随后按「完成前置」恢复。
    this.loginService()?.endHold();
    AppRouting.shared.navigator.remove(RoutePolicy.BIND_PHONE);
    AppRouting.shared.stateChanged(false);
    AppRouting.shared.router.prerequisiteCompleted();
  }

  /** 绑手机页出栈（系统返回等不经 onClose 的离开）：没绑定就按【暂不】恢复保留的待办。 */
  bindPageLeft(): void {
    this.releaseHeldPending();
  }

  /**
   * 统一客服出口（登录页、绑手机页的【联系客服申诉】等共用）。TODO(N-26)：客服入口（cs.open，/v1/config.kf，未装微信按
   * cs.wechat_unavailable）在客服任务实现；先打开帮助中心。
   */
  static openCustomerService(): void {
    AppRouting.shared.openInApp(HELP_ROUTE);
  }

  /**
   * 第三方老用户登录后 phone_bound 没查清（getMe 失败，R1-02）就进了绑手机页：再查一次；查清是已绑就关掉本页，待办经 Router
   * 守卫照常恢复（这不是完成了绑定，不重置计时）。
   */
  private recheckPhoneBinding(): void {
    const client: ApiClient | null = AppNetwork.client;
    const oauth: OAuthLoginService | null = this.oauthService();
    if (client === null || oauth === null || !this.phoneBinding.isUnverified(client.sessionAccount())) {
      return;
    }
    const account: string | null = client.sessionAccount();
    oauth.refreshMe().then((known: boolean): void => {
      if (known && this.phoneBinding.get(account) === true && client.sessionAccount() === account) {
        AppRouting.shared.navigator.remove(RoutePolicy.BIND_PHONE);
        AppRouting.shared.stateChanged(false);
        AppRouting.shared.router.resumePending();
      }
    });
  }

  /** 绑手机页配置（BindPhone 路由）。 */
  bindPageConfig(): BindPhonePageConfig | null {
    const service: BindPhoneService | null = this.bindPhoneService();
    if (service === null) {
      return null;
    }
    const config: BindPhonePageConfig = new BindPhonePageConfig(service, this.texts);
    config.providerName = LoginDraftTexts.text('login.provider.' + this.lastProvider);
    config.onClose = (): void => {
      AppRouting.shared.navigator.remove(RoutePolicy.BIND_PHONE);
      this.releaseHeldPending();
    };
    config.onBound = (): void => {
      // phoneBound 已移除本页；这里不再重复。
    };
    config.onCustomerService = (): void => AppLogin.openCustomerService();
    // R2-03：10007 stage=cooling → 经 Router 打开 DeleteAccount（守卫照常判定）。
    config.onNavigate = (route: string): void => {
      AppRouting.shared.openInApp(route);
    };
    this.recheckPhoneBinding();
    return config;
  }

  /** 设置页【退出登录】确认之后。返回 true = 已回到游客。 */
  async logout(): Promise<boolean> {
    const service: LoginService | null = this.loginService();
    if (service === null) {
      return false;
    }
    const done: boolean = await service.logout();
    hilog.info(DOMAIN, TAG, 'logout done=%{public}s', String(done));
    return done;
  }
}
