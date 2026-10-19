import { ApiClient, ClientScope } from '../network/ApiClient';
import { AgreementConfirmKeys } from './AgreementSentence';
import { HuaweiQuickLoginPort, QuickLoginCredential, QuickLoginCredentialKind, QuickLoginPrefetch } from './HuaweiQuickLoginPort';
import { AgreementState, LegalVersions } from './LoginFlow';
import { LoginPageFlow } from './LoginPageFlow';
import { AttemptTicket, LoginOutcome, LoginService } from './LoginService';
import { OAuthProvider } from './OAuthLoginFlow';
import { OAuthLoginService } from './OAuthLoginService';
import { OneTapAttempt, OneTapLoginService } from './OneTapLoginService';

/** 首屏纯决策：只有能力可用且确有匿名号才进一键页。 */
export class LoginFirstScreen {
  static readonly PENDING: string = 'pending';
  static readonly QUICK_LOGIN: string = 'quick_login';
  static readonly PHONE_PAGE: string = 'phone_page';
  readonly screen: string;
  readonly thirdParty: string[];

  constructor(screen: string, thirdParty: string[]) {
    this.screen = screen;
    this.thirdParty = thirdParty;
  }

  static decide(capable: boolean, prefetch: QuickLoginPrefetch | null, providers: string[]): LoginFirstScreen {
    const others: string[] = providers.filter((provider: string): boolean => provider !== OAuthProvider.HUAWEI);
    if (capable && prefetch !== null && prefetch.fallback === null && prefetch.anonymousPhone !== null
      && prefetch.anonymousPhone.length > 0) {
      return new LoginFirstScreen(LoginFirstScreen.QUICK_LOGIN, others);
    }
    const first: string[] = providers.indexOf(OAuthProvider.HUAWEI) >= 0 ? [OAuthProvider.HUAWEI] : [];
    return new LoginFirstScreen(LoginFirstScreen.PHONE_PAGE, first.concat(others));
  }
}

export class QuickLoginDeps {
  readonly port: HuaweiQuickLoginPort;
  readonly client: ApiClient;
  readonly login: LoginService;
  readonly oauth: OAuthLoginService | null;
  readonly capable: () => boolean;
  readonly privacyReady: () => boolean;
  legal: LegalVersions = LegalVersions.bundled();
  clock: () => number = (): number => Date.now();
  delay: (millis: number) => Promise<void> = (millis: number): Promise<void> => new Promise<void>(
    (resolve: () => void): void => {
      setTimeout(resolve, millis);
    });
  restricted: boolean = false;
  pageFlow: LoginPageFlow | null = null;
  onLoggedIn: (outcome: LoginOutcome) => void = (_outcome: LoginOutcome): void => {
  };

  constructor(port: HuaweiQuickLoginPort, client: ApiClient, login: LoginService, oauth: OAuthLoginService | null,
    capable: () => boolean, privacyReady: () => boolean) {
    this.port = port;
    this.client = client;
    this.login = login;
    this.oauth = oauth;
    this.capable = capable;
    this.privacyReady = privacyReady;
  }
}

/** 只管理视图模型；官方组件和周围布局留待视觉闸与 HM-14b。 */
export class QuickLoginFlow {
  static readonly PREFETCH_TIMEOUT_MILLIS: number = 5000;
  /** 共享确认框的按钮键沿用 HM-13a；一键页正文另外包含华为认证协议。 */
  readonly confirmBodyKey: string = AgreementConfirmKeys.of('one_tap', true).bodyKey;
  readonly agreementTextKey: string = 'login.agree.text_huawei';
  readonly agreement: AgreementState;
  private readonly deps: QuickLoginDeps;
  private readonly page: LoginPageFlow;
  private readonly service: OneTapLoginService;
  private screenRaw: string = LoginFirstScreen.PENDING;
  private phone: string | null = null;
  private feedback: string | null = null;
  private result: LoginOutcome | null = null;
  private attempt: Promise<OneTapAttempt | null> | null = null;
  private submitting: boolean = false;
  private revision: number = 0;
  private consentRevision: number = 0;
  private settled: Promise<void> = Promise.resolve();
  private finishFirst: (() => void) | null = null;

  constructor(deps: QuickLoginDeps) {
    this.deps = deps;
    this.page = deps.pageFlow ?? new LoginPageFlow(deps.login, deps.clock, deps.restricted);
    this.agreement = this.page.agreement;
    this.service = new OneTapLoginService(deps.client, deps.login, deps.legal);
    deps.port.setAgreement(this.agreement.checked);
    deps.port.listen((): Promise<void> => this.onClick(),
      (result: QuickLoginCredential): Promise<void> => this.onCredential(result));
  }

  get screen(): string {
    return this.screenRaw;
  }

  get anonymousPhone(): string | null {
    return this.phone;
  }

  get thirdParty(): string[] {
    const providers: string[] = this.deps.oauth?.visibleProviders() ?? [];
    return LoginFirstScreen.decide(this.screenRaw === LoginFirstScreen.QUICK_LOGIN,
      this.phone === null ? null : QuickLoginPrefetch.phone(this.phone), providers).thirdParty;
  }

  get confirm(): AgreementConfirmKeys | null {
    return this.page.confirm;
  }

  get feedbackKey(): string | null {
    return this.feedback;
  }

  get outcome(): LoginOutcome | null {
    return this.result;
  }

  get busy(): boolean {
    return this.submitting;
  }

  /** 视图据此给一键按钮、其他手机号入口或第三方按钮挂标签；不保存号码。 */
  get lastMethod(): string | null {
    return this.deps.login.lastLoginMethod?.read() ?? null;
  }

  prefetchSettled(): Promise<void> {
    return this.settled;
  }

  /** 首个事件决定首屏；两个事件的处理链全部挂到 settled 上，迟到输入只结算、不翻屏。 */
  start(): Promise<void> {
    this.endPrefetch();
    this.deps.login.invalidateAttempt();
    this.revision++;
    const revision: number = this.revision;
    this.attempt = null;
    this.feedback = null;
    this.result = null;
    this.phone = null;
    this.screenRaw = LoginFirstScreen.PENDING;
    this.page.cancelAgree();
    this.uncheck();
    if (!this.deps.privacyReady() || !this.deps.capable()) {
      this.screenRaw = LoginFirstScreen.PHONE_PAGE;
      this.settled = Promise.resolve();
      return Promise.resolve();
    }
    const ticket: AttemptTicket = this.deps.login.attemptTicket();
    this.deps.login.releaseTicket(ticket);
    const scope: ClientScope = this.deps.client.captureScope();
    const first: Promise<void> = new Promise<void>((resolve: () => void): void => {
      this.finishFirst = resolve;
    });
    let decided: boolean = false;
    const handle: (value: QuickLoginPrefetch | null) => void = (value: QuickLoginPrefetch | null): void => {
      if (decided || revision !== this.revision) {
        return;
      }
      decided = true;
      const usable: boolean = this.deps.privacyReady() && this.deps.capable()
        && this.deps.login.ticketValid(ticket) && this.deps.client.scopeValid(scope);
      const choice: LoginFirstScreen = LoginFirstScreen.decide(usable, value, []);
      this.screenRaw = choice.screen;
      this.phone = choice.screen === LoginFirstScreen.QUICK_LOGIN && value !== null ? value.anonymousPhone : null;
      this.endPrefetch();
    };
    const fetched: Promise<void> = this.prefetch().then((value: QuickLoginPrefetch | null): void => handle(value));
    const timeout: Promise<void> = this.deps.delay(QuickLoginFlow.PREFETCH_TIMEOUT_MILLIS)
      .then((): void => handle(null));
    this.settled = Promise.all([fetched, timeout]).then((): void => {
    });
    return first;
  }

  private async prefetch(): Promise<QuickLoginPrefetch | null> {
    try {
      return await this.deps.port.prefetchAnonymousPhone();
    } catch (e) {
      return null;
    }
  }

  private endPrefetch(): void {
    const finish: (() => void) | null = this.finishFirst;
    this.finishFirst = null;
    if (finish !== null) {
      finish();
    }
  }

  check(): void {
    this.consentRevision++;
    this.agreement.check();
    this.deps.port.setAgreement(true);
  }

  uncheck(): void {
    this.consentRevision++;
    this.agreement.uncheck();
    this.deps.port.setAgreement(false);
  }

  confirmAgree(): Promise<void> {
    return this.screenRaw === LoginFirstScreen.QUICK_LOGIN ? this.page.confirmAgree() : Promise.resolve();
  }

  cancelAgree(): void {
    this.page.cancelAgree();
    this.attempt = null;
  }

  otherPhone(): void {
    this.revision++;
    this.endPrefetch();
    this.attempt = null;
    this.phone = null;
    this.page.backToPhone();
    this.screenRaw = LoginFirstScreen.PHONE_PAGE;
  }

  private ready(): boolean {
    return this.screenRaw === LoginFirstScreen.QUICK_LOGIN && this.deps.privacyReady() && this.deps.capable();
  }

  private async onClick(): Promise<void> {
    if (!this.ready() || this.submitting || this.deps.login.busy || this.deps.oauth?.busy === true) {
      return;
    }
    this.feedback = null;
    this.result = null;
    const attempt: Promise<OneTapAttempt | null> = this.service.createAttempt();
    this.attempt = attempt;
    const created: OneTapAttempt | null = await attempt;
    if (created === null && this.attempt === attempt && this.ready()) {
      this.feedback = LoginService.GENERIC_KEY;
      this.otherPhone();
    }
  }

  private async onCredential(result: QuickLoginCredential): Promise<void> {
    if (!this.ready() || this.submitting || this.attempt === null) {
      return;
    }
    if (result.kind === QuickLoginCredentialKind.CANCELLED) {
      this.cancelAgree();
      this.feedback = null;
      return;
    }
    if (result.kind === QuickLoginCredentialKind.AGREEMENT_NOT_ACCEPTED) {
      this.agreement.uncheck();
      await this.page.tapOneTap((): Promise<void> => {
        if (this.ready() && this.attempt !== null) {
          this.consentRevision++;
          this.deps.port.setAgreement(true);
          this.deps.port.continueLogin();
        }
        return Promise.resolve();
      });
      return;
    }
    if (result.kind !== QuickLoginCredentialKind.CREDENTIAL) {
      this.feedback = LoginService.GENERIC_KEY;
      this.otherPhone();
      return;
    }
    const consentAt: number | null = this.agreement.consentAtMillis;
    const code: string | null = result.authorizationCode;
    if (!this.agreement.checked || consentAt === null || code === null || code.length === 0) {
      return;
    }
    const attempt: Promise<OneTapAttempt | null> = this.attempt;
    const revision: number = this.revision;
    const consentRevision: number = this.consentRevision;
    this.attempt = null;
    this.submitting = true;
    try {
      const created: OneTapAttempt | null = await attempt;
      // 三轮评审的等待窗口：页面、同意时刻、同意修订和环境都要复核，之后才可能消费邀请码。
      if (!this.ready() || revision !== this.revision || !this.agreement.checked
        || consentAt !== this.agreement.consentAtMillis || consentRevision !== this.consentRevision) {
        return;
      }
      if (created === null) {
        this.feedback = LoginService.GENERIC_KEY;
        this.otherPhone();
        return;
      }
      const outcome: LoginOutcome = await this.service.loginHuawei(created, code, consentAt, this.deps.restricted);
      if (revision !== this.revision) {
        return;
      }
      this.result = outcome;
      if (outcome.stateRaw === LoginOutcome.LOGGED_IN) {
        this.deps.onLoggedIn(outcome);
      } else if (outcome.stateRaw !== LoginOutcome.STALE && outcome.stateRaw !== LoginOutcome.BUSY) {
        this.feedback = LoginService.GENERIC_KEY;
        this.otherPhone();
      }
    } finally {
      this.submitting = false;
    }
  }
}
