import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, LoginOutcome, LoginService, RouterLoginHost, RoutePolicy, SessionState, SessionTokens
} from 'core';
import { CouliDialog, CouliDialogOptions, CouliToast } from 'designsystem';
import { LoginPageConfig, LoginTexts } from 'auth';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppNetwork } from '../network/AppNetwork';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';
import { LoginDraftTexts } from './LoginDraftTexts';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliLogin';
const AGREEMENT_ROUTE: string = 'Agreement';
const SETTINGS_ROUTE: string = 'Settings';
const HELP_ROUTE: string = 'Help';
const ME_ROUTE: string = 'Me';

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
    this.service = service;
    return service;
  }

  /** 守卫用的会话状态。 */
  sessionState(): SessionState {
    return RouterLoginHost.sessionState(AppNetwork.client, AppNetwork.tokens);
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
    // LoginPublicHarmony 的第三方登录位置：APP-05b 实现前只在 Debug / Staging 构建显示占位（版式比对用），Release 不显示。
    config.showThirdPartySlot = BuildVariant.IS_DEBUG_BUILD;
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
    config.onCustomerService = (): void => {
      // TODO(N-26)：客服入口（cs.open，/v1/config.kf，未装微信按 cs.wechat_unavailable）在客服任务实现；先打开帮助中心。
      AppRouting.shared.openInApp(HELP_ROUTE);
    };
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
