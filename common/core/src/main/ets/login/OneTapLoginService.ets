import { ApiClient, ApiOutcome, ApiRequest, ApiResult, ClientScope } from '../network/ApiClient';
import { LocalRejectReason } from '../network/NetworkPolicy';
import { LegalVersions } from './LoginFlow';
import { LastLoginMethodStore } from './LastLoginMethod';
import { AttemptTicket, LoginOutcome, LoginService, loginResponseAccount } from './LoginService';
import { OAuthProvider } from './OAuthLoginFlow';
import { OAuthLoginService } from './OAuthLoginService';
import { OneTapLoginPort } from './OneTapLoginPort';

/** 尝试归属保留到凭证提交，不能在等待后重新绑定到另一个会话、环境或隐私世代。 */
export class OneTapAttempt {
  readonly id: string;
  readonly ticket: AttemptTicket;
  readonly scope: ClientScope;
  submitted: boolean = false;

  constructor(id: string, ticket: AttemptTicket, scope: ClientScope) {
    this.id = id;
    this.ticket = ticket;
    this.scope = scope;
  }
}

/** 一键登录复用短信登录的会话保存、手机号认定、待办恢复和待绑定码。 */
export class OneTapLoginService {
  private readonly client: ApiClient;
  private readonly login: LoginService;
  private readonly legal: LegalVersions;
  private running: boolean = false;

  constructor(client: ApiClient, login: LoginService, legal: LegalVersions) {
    this.client = client;
    this.login = login;
    this.legal = legal;
  }

  async createAttempt(): Promise<OneTapAttempt | null> {
    const ticket: AttemptTicket = this.login.attemptTicket();
    const scope: ClientScope = this.client.captureScope();
    const body: Record<string, Object> = {};
    body['provider'] = OAuthProvider.HUAWEI;
    body['purpose'] = 'login';
    const request: ApiRequest = new ApiRequest(OAuthLoginService.CREATE_OPERATION, {}, '', JSON.stringify(body));
    request.owner = ticket.owner;
    try {
      const result: ApiResult = await this.client.request(request);
      if (!result.ok || !this.login.ticketValid(ticket) || !this.client.scopeValid(scope)) {
        return null;
      }
      const id: Object | undefined = result.data['attempt_id'];
      return typeof id === 'string' && (id as string).length > 0 ?
        new OneTapAttempt(id as string, ticket, scope) : null;
    } finally {
      this.login.releaseTicket(ticket);
    }
  }

  async loginHuawei(attempt: OneTapAttempt, code: string, consentAt: number | null,
    restricted: boolean): Promise<LoginOutcome> {
    if (consentAt === null || !Number.isSafeInteger(consentAt)) {
      return new LoginOutcome(LoginOutcome.AGREEMENT_REQUIRED);
    }
    if (this.running || this.login.busy) {
      return new LoginOutcome(LoginOutcome.BUSY);
    }
    if (code.length === 0 || attempt.submitted || !this.login.ticketValid(attempt.ticket)
      || !this.client.scopeValid(attempt.scope)) {
      return new LoginOutcome(LoginOutcome.STALE);
    }
    const ticket: AttemptTicket = this.login.attemptTicket();
    const methodStore: LastLoginMethodStore | null = this.login.lastLoginMethod;
    const revision: number = methodStore?.revision ?? -1;
    // 所有本地关口通过后才消费；不在结算时清容器，避免删掉请求在途时新收到的码（G18）。
    const invite: string | null = restricted ? null : (this.login.pendingInvite?.consumeForRequest() ?? null);
    const request: ApiRequest = new ApiRequest(OneTapLoginPort.OPERATION_ID, {}, '',
      OneTapLoginPort.body(attempt.id, code, this.legal, consentAt, invite));
    request.owner = ticket.owner;
    attempt.submitted = true;
    this.running = true;
    try {
      const result: ApiResult = await this.client.request(request);
      if (result.ok) {
        const verified: ((account: string | null) => void) | null = this.login.onPhoneVerifiedSession;
        if (verified !== null && this.client.sessionReadable()) {
          const account: string | null = loginResponseAccount(result.data, this.client.sessionAccount());
          if (account !== null) {
            verified(account);
          }
        }
        // R13：新号也已绑手机，不暂缓待办、不走第三方绑手机引导。
        const outcome: LoginOutcome = await this.login.finishSessionLogin(result, ticket, false, restricted);
        if (outcome.stateRaw === LoginOutcome.LOGGED_IN && methodStore !== null) {
          methodStore.record(LastLoginMethodStore.HUAWEI_ONE_TAP, revision);
        }
        return outcome;
      }
      if (!this.login.ticketValid(ticket)) {
        return new LoginOutcome(LoginOutcome.STALE);
      }
      if (result.outcome === ApiOutcome.LOCAL_REJECT
        && result.localRejectReason !== LocalRejectReason.SESSION_SAVE_FAILED
        && result.localRejectReason !== LocalRejectReason.INVALID_SESSION_TOKENS) {
        return new LoginOutcome(LoginOutcome.STALE);
      }
      return new LoginOutcome('service_error', LoginService.GENERIC_KEY, null, 0, [], null, null, result.trace6);
    } finally {
      this.running = false;
      this.login.releaseTicket(ticket);
    }
  }
}
