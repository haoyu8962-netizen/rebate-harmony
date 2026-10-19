import { AgreementState, CodeInput, CodeRevision, CodeStamp } from './LoginFlow';
import { LoginOutcome, LoginRateLimits, LoginService } from './LoginService';

export class CodeSubmitResult {
  readonly outcome: LoginOutcome;
  readonly current: boolean;

  constructor(outcome: LoginOutcome, current: boolean) {
    this.outcome = outcome;
    this.current = current;
  }
}

/** 验证码输入的唯一提交入口。修订号防重复与迟到覆盖，在途输入只更新格子、不排队（G12/G23）。 */
export class CodeAutoSubmit {
  private readonly service: LoginService;
  private readonly agreement: AgreementState;
  private readonly clock: () => number;
  private readonly revision: CodeRevision = new CodeRevision();
  private readonly limits: LoginRateLimits = new LoginRateLimits();
  private text: string = '';
  private phone: string = '';
  private restricted: boolean = false;
  private active: boolean = false;
  private running: boolean = false;
  private submitted: CodeStamp | null = null;

  constructor(service: LoginService, agreement: AgreementState, clock: () => number = () => Date.now()) {
    this.service = service;
    this.agreement = agreement;
    this.clock = clock;
  }

  get code(): string {
    return this.text;
  }

  get submitting(): boolean {
    return this.running;
  }

  get rateLimited(): boolean {
    return this.limits.loginBlocked(this.clock());
  }

  begin(rawPhone: string, restricted: boolean): boolean {
    if (this.agreement.consentAtMillis === null) {
      this.leave();
      return false;
    }
    this.phone = rawPhone;
    this.restricted = restricted;
    this.active = true;
    this.text = '';
    this.revision.bump();
    this.submitted = null;
    return true;
  }

  leave(): void {
    this.active = false;
    this.text = '';
    this.revision.bump();
  }

  input(raw: string): Promise<CodeSubmitResult> | null {
    if (!this.active) {
      return null;
    }
    this.text = this.revision.change(this.text, CodeInput.sanitize(raw));
    if (!CodeInput.accept(this.text).complete) {
      return null;
    }
    if (this.running) {
      // 这次完整输入已消费：即使系统随后重复派发同值，也不补交。
      this.submitted = this.revision.capture(this.text);
      return null;
    }
    const submitted: CodeStamp | null = this.submitted;
    if ((submitted !== null && this.revision.current(submitted, this.text)) || this.rateLimited
      || this.service.issuedCodeRemainingSec(this.phone) <= 0) {
      return null;
    }
    const consent: number | null = this.agreement.consentAtMillis;
    if (consent === null) {
      return null;
    }
    const stamp: CodeStamp = this.revision.capture(this.text);
    this.submitted = stamp;
    this.running = true;
    return this.submit(stamp, consent);
  }

  private async submit(stamp: CodeStamp, consent: number): Promise<CodeSubmitResult> {
    let outcome: LoginOutcome;
    try {
      outcome = await this.service.login(this.phone, stamp.code, consent, '', this.restricted);
    } finally {
      this.running = false;
    }
    this.limits.applyLogin(outcome, this.clock());
    const current: boolean = this.active && this.revision.current(stamp, this.text);
    const failed: boolean = outcome.stateRaw !== LoginOutcome.LOGGED_IN && outcome.stateRaw !== LoginOutcome.STALE
      && outcome.stateRaw !== LoginOutcome.BUSY && outcome.stateRaw !== 'rate_limited';
    // G25：42901 只禁用提交，保留内容。其余失败只清本次码，视图不卸载输入框，保留键盘。
    if (current && failed) {
      this.text = this.revision.change(this.text, '');
    }
    return new CodeSubmitResult(outcome, current);
  }
}
