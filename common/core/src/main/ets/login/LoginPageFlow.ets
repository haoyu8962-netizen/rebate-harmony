import { AgreementConfirmKeys } from './AgreementSentence';
import { CodeAutoSubmit } from './CodeAutoSubmit';
import { AgreementState, SmsCountdown } from './LoginFlow';
import { LoginOutcome, LoginSendState, LoginService, PhoneEntry, SendCodeOutcome } from './LoginService';

/** 登录页动作调度。视图只派发动作、展示状态；本层统一处理同意、发码、换步与求助路由。 */
export class LoginPageFlow {
  static readonly STEP_PHONE: string = 'phone';
  static readonly STEP_CODE: string = 'code';
  readonly agreement: AgreementState;
  readonly code: CodeAutoSubmit;
  helpLinks: () => Record<string, Object> | null = (): Record<string, Object> | null => null;
  open: (route: string, params: Record<string, Object>) => boolean = (_r: string, _p: Record<string, Object>): boolean => false;

  private readonly service: LoginService;
  private readonly clock: () => number;
  private readonly restricted: boolean;
  private phoneRaw: string = '';
  private stepRaw: string = LoginPageFlow.STEP_PHONE;
  private confirmation: AgreementConfirmKeys | null = null;
  private pending: (() => Promise<void>) | null = null;
  private feedback: SendCodeOutcome | null = null;
  private sending: boolean = false;
  private revision: number = 0;

  constructor(service: LoginService, clock: () => number = () => Date.now(), restricted: boolean = false) {
    this.service = service;
    this.clock = clock;
    this.restricted = restricted;
    this.agreement = new AgreementState(clock);
    this.code = new CodeAutoSubmit(service, this.agreement, clock);
  }

  get phone(): string {
    return this.phoneRaw;
  }

  set phone(value: string) {
    if (value !== this.phoneRaw) {
      this.backToPhone();
      this.phoneRaw = value;
    }
  }

  get step(): string {
    return this.stepRaw;
  }

  get confirm(): AgreementConfirmKeys | null {
    return this.confirmation;
  }

  get sendFeedback(): SendCodeOutcome | null {
    return this.feedback;
  }

  get countdownSec(): number {
    return this.service.sendState(this.phoneRaw).countdownSec;
  }

  get canResend(): boolean {
    const state: LoginSendState = this.service.sendState(this.phoneRaw);
    return !this.sending && !this.code.submitting && state.countdownSec === 0 && state.rateLimitedSec === 0;
  }

  tapGetCode(): Promise<void> {
    if (this.stepRaw !== LoginPageFlow.STEP_PHONE || this.sending) {
      return Promise.resolve();
    }
    const blocked: boolean = this.service.sendState(this.phoneRaw).rateLimitedSec > 0;
    const entry: PhoneEntry = this.service.phoneEntry(this.phoneRaw, blocked);
    if (entry.kind === PhoneEntry.CONTINUE) {
      return this.gate('get_code', (): Promise<void> => this.enterCode());
    }
    if (blocked) {
      return Promise.resolve();
    }
    return this.gate('get_code', (): Promise<void> => this.send());
  }

  tapContinue(): Promise<void> {
    if (this.stepRaw !== LoginPageFlow.STEP_PHONE || this.sending
      || this.service.continueEntry(this.phoneRaw).kind !== PhoneEntry.CONTINUE) {
      return Promise.resolve();
    }
    return this.gate('get_code', (): Promise<void> => this.enterCode());
  }

  tapResend(): Promise<void> {
    if (this.stepRaw !== LoginPageFlow.STEP_CODE || !this.canResend) {
      return Promise.resolve();
    }
    return this.send();
  }

  /** 第三方按钮复用同一个同意状态和确认框；执行器由页面配置提供。 */
  tapOAuth(run: () => Promise<void>): Promise<void> {
    if (this.stepRaw !== LoginPageFlow.STEP_PHONE || this.sending) {
      return Promise.resolve();
    }
    return this.gate('oauth', run);
  }

  async confirmAgree(): Promise<void> {
    const run: (() => Promise<void>) | null = this.pending;
    if (run === null || this.confirmation === null) {
      return;
    }
    // 先消费再执行，确认框连点不会重复发码。
    this.pending = null;
    this.confirmation = null;
    this.agreement.confirm(this.clock());
    this.agreement.consumeProceed();
    await run();
  }

  cancelAgree(): void {
    this.pending = null;
    this.confirmation = null;
    this.agreement.cancel();
  }

  backToPhone(): void {
    this.revision++;
    this.cancelAgree();
    this.feedback = null;
    this.code.leave();
    this.stepRaw = LoginPageFlow.STEP_PHONE;
    this.service.invalidateAttempt();
  }

  openCodeHelp(): boolean {
    return this.open('Help', LoginPageFlow.helpParams(this.helpLinks()));
  }

  private static helpParams(links: Record<string, Object> | null): Record<string, Object> {
    const out: Record<string, Object> = {};
    const target: Object | undefined = links === null ? undefined : links['login_help'];
    if (target === undefined || target === null || typeof target !== 'object' || Array.isArray(target)) {
      return out;
    }
    const link: Record<string, Object> = target as Record<string, Object>;
    const params: Object | undefined = link['params'];
    if (link['route'] !== 'Help' || params === undefined || params === null || typeof params !== 'object'
      || Array.isArray(params)) {
      return out;
    }
    const article: Object | undefined = (params as Record<string, Object>)['article_id'];
    if (typeof article === 'string' && (article as string).trim().length > 0) {
      out['article_id'] = article as string;
    }
    return out;
  }

  private gate(action: string, run: () => Promise<void>): Promise<void> {
    if (this.confirmation !== null) {
      return Promise.resolve();
    }
    this.agreement.tapLogin();
    if (this.agreement.consumeProceed()) {
      return run();
    }
    this.pending = run;
    this.confirmation = AgreementConfirmKeys.of(action);
    return Promise.resolve();
  }

  private async send(): Promise<void> {
    if (this.sending) {
      return;
    }
    this.feedback = null;
    this.sending = true;
    const revision: number = this.revision;
    let outcome: SendCodeOutcome;
    try {
      outcome = await this.service.sendCode(this.phoneRaw);
    } finally {
      this.sending = false;
    }
    if (revision !== this.revision) {
      return;
    }
    if (outcome.stateRaw === SmsCountdown.STATE_SENT || outcome.stateRaw === LoginService.STATE_COUNTDOWN) {
      await this.enterCode();
    } else if (outcome.stateRaw !== LoginOutcome.STALE && outcome.stateRaw !== LoginOutcome.BUSY) {
      // 原样保留字段、倒计时、路由和 trace，禁止吞掉发码失败。
      this.feedback = outcome;
    }
  }

  private enterCode(): Promise<void> {
    if (this.code.begin(this.phoneRaw, this.restricted)) {
      this.stepRaw = LoginPageFlow.STEP_CODE;
    }
    return Promise.resolve();
  }
}
