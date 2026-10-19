import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AppConfig, GuardDecisionKind, LastLoginMethodStore, PreferencesLastLoginMethodBackend, ApiClient, BindPhoneForm,
  BindPhoneHost, BindPhoneRecheck, BindPhoneService, ConfigStore, LoginOutcome, LoginService,
  OAuthLoginOutcome, OAuthLoginRoute, OAuthLoginService, OAuthProvider, PhoneBindingState, RouterLoginHost, RoutePolicy,
  SessionState, SessionTokens
} from 'core';
import { CouliDialog, CouliDialogOptions, CouliToast } from 'designsystem';
import { BindPhonePageConfig, LoginPageConfig, LoginTexts } from 'auth';
import { AppPendingInvite } from '../invite/AppPendingInvite';
import { AppClientCore } from '../clientcore/AppClientCore';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppNetwork } from '../network/AppNetwork';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';
import { AppAccount, DELETE_ACCOUNT_ROUTE } from '../account/AppAccount';
import { LoginDraftTexts } from './LoginDraftTexts';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliLogin';
const AGREEMENT_ROUTE: string = 'Agreement';
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
  private lastMethod: LastLoginMethodStore | null = null;

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

  /** 冷启动就登记撤回清理，不能等用户打开登录页后才登记。 */
  compose(context: common.Context): void {
    if (this.lastMethod === null) {
      this.lastMethod = new LastLoginMethodStore(new PreferencesLastLoginMethodBackend(context));
      this.lastMethod.installCleaner(AppConfig.cleaners);
    }
    if (this.service !== null) {
      this.service.lastLoginMethod = this.lastMethod;
    }
  }

  private static helpLinks(): Record<string, Object> | null {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const json: string | null = store === null ? null : store.value('help_links');
    if (json === null) {
      return null;
    }
    try {
      const parsed: Object = JSON.parse(json) as Object;
      return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ?
        parsed as Record<string, Object> : null;
    } catch (e) {
      return null;
    }
  }

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
    service.pendingInvite = AppPendingInvite.shared;
    service.lastLoginMethod = this.lastMethod;
    // R2-01：登录页确定出栈（关闭、清栈、强更替换导航栈）的同步出口立即作废本次尝试；系统返回由页面 onWillDisappear 兜住。
    this.host.watchLoginPage(service);
    // R2-01：短信登录的账号一定有手机号；其余（第三方登录、冷启动未知）要等 getMe 查清。
    service.onPhoneVerifiedSession = (account: string | null): void => this.phoneBinding.set(account, true);
    // APP-12 R1-03：真实登录成功（会话已保存、尝试仍有效）的会话世代交给推送上报，区分「恢复已有会话」与「登录成功」。
    service.onLoginCompleted((generation: number): void => AppLogin.loginCompleted(generation));
    this.service = service;
    return service;
  }

  /**
   * FU-HM-0720（APP-05b 共性 20）：绑手机成功后的那一轮 getMe 交给「我的」共享资料（AppMe 组合时接上 MeSession；之前不推进、不写）。
   */
  static meReadAdvance: () => number = (): number => -1;
  static meLoaded: (account: string, me: Record<string, Object>, generation: number) => void =
    (_a: string, _m: Record<string, Object>, _g: number): void => {
    };

  /** APP-12：登录完成（会话世代）的接收方（AppMe 组合时接上；之前什么都不做）。 */
  static loginCompleted: (generation: number) => void = (_g: number) => {
  };

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
    const service: BindPhoneService = new BindPhoneService(client, login.deadlines, this.phoneBinding,
      new AppBindPhoneHost());
    // APP-13a harmony-review-r1 R1-03、R1-04、R1-08：与换号共用 phoneGate、getMe 读取闸门与内存 token（AccountSession 一份）。
    service.accountPort = AppAccount.shared.session;
    service.forceUpdate = (): void => AppUpdate.shared.onServerForced();
    // FU-HM-0720（共性 20）：绑定成功后的 getMe 推进并写入「我的」共享资料（设置页、Agent 读同一份 phone_bound）。
    service.meReadAdvance = (): number => AppLogin.meReadAdvance();
    service.meLoaded = (account: string, me: Record<string, Object>, generation: number): void =>
      AppLogin.meLoaded(account, me, generation);
    service.syncSession();
    this.bindService = service;
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
    config.helpLinks = (): Record<string, Object> | null => AppLogin.helpLinks();
    config.open = (route: string, params: Record<string, Object>): boolean =>
      (restricted ? AppRouting.shared.openFromForceUpdatePage(route, params) :
        AppRouting.shared.openInApp(route, params)).kind === GuardDecisionKind.OPEN;
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

  /**
   * 绑手机成功（BindPhoneService 已刷新 getMe）的共享结算：释放暂缓、守卫重算会话状态。harmony-review-r3 R3-03：这里不出栈、不恢复
   * 待办——迟到的成功（原页面已离开、又打开了新的 BindPhone）不得按路由名移除后来的同名页；出栈与「完成前置」恢复由持有原页面许可的
   * 页面经 bindPageCompleted 做，只操作原来那一个导航实例。
   */
  phoneBound(): void {
    this.guideHolding = false;
    // R2-02：绑定完成——明确释放暂缓。
    this.loginService()?.endHold();
    AppRouting.shared.stateChanged(false);
  }

  /** 原页面许可仍有效时的绑定成功（页面已只退出自己那一个导航实例）：按「完成前置」恢复待办（R3-03）。 */
  bindPageCompleted(): void {
    AppRouting.shared.router.prerequisiteCompleted();
  }

  /** 绑手机页的【关闭】（页面已只退出自己那一个导航实例，F-HM-31）：没绑定就按【暂不】恢复保留的待办。 */
  bindPageClosed(): void {
    this.releaseHeldPending();
  }

  /** 绑手机页出栈（系统返回等不经 onClose 的离开）：没绑定就按【暂不】恢复保留的待办。 */
  bindPageLeft(): void {
    this.releaseHeldPending();
  }

  /** 统一客服出口的实现（APP-12：AppMe 组合时接上 Core 的 CustomerServiceEntry）。 */
  static customerServiceHandler: (() => void) | null = null;

  /**
   * 统一客服出口（登录页、绑手机页的【联系客服申诉】、授权管理、钱包、订单等共用；调用方不改）。APP-12 起委托 Core 的统一入口
   * （/v1/config.kf.url 原样打开，未装微信给复制客服链接与帮助中心，G20）；组合之前退回帮助中心。
   */
  static openCustomerService(): void {
    const handler: (() => void) | null = AppLogin.customerServiceHandler;
    if (handler !== null) {
      handler();
      return;
    }
    AppRouting.shared.openInApp(HELP_ROUTE);
  }

  /**
   * 第三方老用户登录后 phone_bound 没查清（getMe 失败，R1-02）就进了绑手机页：再查一次；查清是已绑就关掉本页，待办经 Router
   * 守卫照常恢复（这不是完成了绑定，不重置计时）。F-HM-31（同 R3-03）：补查持有发起页面的许可，只退出那一个导航实例
   * （config.onRecheckBound，按 navDestinationId），不按路由名移除；原页面已离开（许可失效）时只做共享结算（守卫重算），
   * 不出栈、不恢复待办，后来打开的同名页不受影响。
   */
  private recheckPhoneBinding(form: BindPhoneForm, config: BindPhonePageConfig): void {
    const client: ApiClient | null = AppNetwork.client;
    const oauth: OAuthLoginService | null = this.oauthService();
    if (client === null || oauth === null || !this.phoneBinding.isUnverified(client.sessionAccount())) {
      return;
    }
    const account: string | null = client.sessionAccount();
    form.recheckBound((): Promise<boolean> => oauth.refreshMe().then((known: boolean): boolean =>
      known && this.phoneBinding.get(account) === true && client.sessionAccount() === account
    )).then((result: string): void => {
      if (result === BindPhoneRecheck.UNBOUND) {
        return;
      }
      const here: boolean = result === BindPhoneRecheck.BOUND_HERE;
      if (here) {
        config.onRecheckBound();
      }
      AppRouting.shared.stateChanged(false);
      if (here) {
        AppRouting.shared.router.resumePending();
      }
    });
  }

  /** 状态同步的同步区（AppAccount.sync）：BindPhone 页的会话换代检测（R1-01：作废旧页面实例与弹窗、清空输入后重建）。 */
  syncBindPage(): void {
    this.bindService?.syncSession();
  }

  /** 绑手机页配置（BindPhone 路由）。 */
  bindPageConfig(): BindPhonePageConfig | null {
    const service: BindPhoneService | null = this.bindPhoneService();
    if (service === null) {
      return null;
    }
    const config: BindPhonePageConfig = new BindPhonePageConfig(service, this.texts);
    config.providerName = LoginDraftTexts.text('login.provider.' + this.lastProvider);
    // F-HM-31：onClose（只退出本实例 + 恢复暂缓）、onRecheckBound 与 R3-03 的 onBound（出栈本实例 + 恢复待办）都由 AppBindPhonePage
    // 按本页导航实例接上，不按路由名移除。
    config.recheck = (form: BindPhoneForm): void => this.recheckPhoneBinding(form, config);
    config.onCustomerService = (): void => AppLogin.openCustomerService();
    // R2-03：10007 stage=cooling → 经 Router 打开 DeleteAccount（守卫照常判定）。
    config.onNavigate = (route: string): void => {
      if (route === DELETE_ACCOUNT_ROUTE) {
        // APP-13a §2 第 9 项：10007 cooling 的统一落点（注销页可用才导航，否则只提示 error.10007，G01）。
        const cooling: Record<string, Object> = {};
        cooling['stage'] = 'cooling';
        AppAccount.shared.on10007(cooling);
        return;
      }
      AppRouting.shared.openInApp(route);
    };
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
