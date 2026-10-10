// APP-09 二次验证面板的执行器（StepUpSheet；brief §2.6；BR-ID-08 短信方式、BR-WDR-01）。
// - 打开即对当前 action 发码：sendSmsCode {phone, purpose: step_up, action}。号码只用本机绑定了当前账号归属的规范化号码（G31）；取不到
//   不编造、不让用户另填，提示并登记空白（rule-gaps H 段）。
// - 「验证码已发送至你绑定的手机号」（G16，不显示号码）；倒计时按 resend_after_sec（未返回按 60 秒）。
// - 【验证并提交】输满 6 位才可用 → stepUp {action, code}；成功把 token 记进内存（按账号与 action，G17）并交给发起方，由发起方沿用原键重放。
// - 20002 / 20003：清空输入、assertive 播报；42901 发码与验证分开限流（smsGate / verifyGate）；10405 进强更。
// - 面板是敏感浮层：关闭或会话变化后迟到的结果只丢弃（APP-07 第 4 条）。
// - 重发截止时间在会话共享的 SmsResendClock（鸿蒙 R1-06，共性第 6 条）：按账号、号码、action 隔离；面板关闭重开时恢复倒计时，
//   每次实际发送前核对同一截止时间与「发送在途」。发码请求不随面板关闭取消（只按会话与账号归属），结果照样记下截止时间。
// - 发码结算由共享服务发布（鸿蒙 R2-01/R2-02，共性第 26、27 条）：请求回来先按账号 / 会话归属写共享截止时间与 42901 限流（面板
//   关了也写），再发布给订阅同一键的面板；在途期间重开的面板靠订阅解除 sending，恢复倒计时或重试状态。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { StepUpGrant, WalletJson } from './WalletJson';
import { WalletDeps } from './WalletController';
import { SmsResendClock, SmsSendOutcome, WalletLoadFailure, WalletMessage, WalletMessages } from './WalletSession';

export class StepUpSnapshot {
  /** 已发码（显示「验证码已发送至你绑定的手机号」）。 */
  sent: boolean = false;
  sending: boolean = false;
  verifying: boolean = false;
  /** 距可重新获取的秒数（0 = 可点【重新获取验证码】）。 */
  countdown: number = 0;
  code: string = '';
  error: WalletMessage | null = null;
  /** 取不到本账号的手机号（G31）：不发码。 */
  noPhone: boolean = false;
  /** 发码 / 验证的 42901 禁用中。 */
  sendBlocked: boolean = false;
  verifyBlocked: boolean = false;
  /** 清空输入的次数（页面据此把输入框清空并聚焦）。 */
  clearSeq: number = 0;
}

export class StepUpController {
  static readonly SEND_OPERATION: string = 'sendSmsCode';
  static readonly VERIFY_OPERATION: string = 'stepUp';
  readonly action: string;
  private readonly d: WalletDeps;
  private readonly account: string;
  private readonly scope: string;
  /** 打开面板的提交 / 确认所属的钱包会话世代（共性第 60 条）；null 只给不经页面的直接构造（单测），不核对世代。 */
  private readonly epoch: number | null;
  private closed: boolean = false;
  private timer: number = -1;
  private countdownUntil: number = 0;
  private verifySeq: number = 0;
  private state: StepUpSnapshot = new StepUpSnapshot();
  private readonly unsubscribe: () => void;
  onChange: (snapshot: StepUpSnapshot) => void = (_s: StepUpSnapshot) => {
  };
  /** 拿到 token（发起方沿用原键重放 1 次）。 */
  onToken: (token: string) => void = (_t: string) => {
  };

  /**
   * APP-09 共性第 60 条：面板沿用打开它的提交 / 确认身份——account、scope（页面构建时的归属键，含登录序号与会话世代）、epoch（钱包
   * 会话世代）由发起页原样传入；发码、重新获取、验证、读手机号、占用发码槽位、发包前都核对它，不重新绑定执行时的会话。scope 为 null
   * 时（不经页面的直接构造）取构造时的归属。
   */
  constructor(deps: WalletDeps, action: string, account: string, scope: string | null = null,
    epoch: number | null = null) {
    this.d = deps;
    this.action = action;
    this.account = account;
    this.scope = scope ?? deps.scope();
    this.epoch = epoch;
    const gates: () => void = (): void => {
      if (!this.closed) {
        this.emit();
      }
    };
    const a: () => void = deps.session.smsGate.subscribe(gates);
    const b: () => void = deps.session.verifyGate.subscribe(gates);
    // 打开时就反映共享限流（关闭的面板收到的 42901 也在这里体现，R2-02）。
    this.state.sendBlocked = deps.session.smsGate.active;
    this.state.verifyBlocked = deps.session.verifyGate.active;
    // 重开面板：同一账号、号码、action 的截止时间还没过 → 恢复「已发送」与倒计时（不再自动发码）。
    const phone: string | null = deps.stepUpPhone(account);
    let unsubscribeSms: () => void = (): void => {
    };
    if (phone !== null) {
      const key: string = SmsResendClock.key(account, phone, action);
      const left: number = deps.session.sms.remainingMs(key, deps.clock());
      if (left > 0) {
        this.state.sent = true;
        this.countdownUntil = deps.clock() + left;
        this.tick();
      }
      this.state.sending = deps.session.sms.sending(key);
      // 订阅这个键的发码结算（含别的面板发出、本面板打开时仍在途的请求）。
      unsubscribeSms = deps.session.sms.subscribe(key, (outcome: SmsSendOutcome): void => {
        this.settled(key, outcome);
      });
    }
    this.unsubscribe = (): void => {
      a();
      b();
      unsubscribeSms();
    };
  }

  get snapshot(): StepUpSnapshot {
    return this.state;
  }

  get open(): boolean {
    return !this.closed;
  }

  /** 面板仍属于打开它的提交 / 确认身份（会话归属、账号、钱包会话世代都没变）。 */
  private valid(): boolean {
    return !this.closed && this.sameSession();
  }

  /** 发起身份对应的会话仍是当前会话（不看面板开关；共享结算用）。 */
  private sameSession(): boolean {
    return this.d.scope() === this.scope && this.d.account() === this.account
      && (this.epoch === null || this.d.session.epoch === this.epoch);
  }

  /** 打开即发码（也是【重新获取验证码】）。 */
  send(): boolean {
    const s: StepUpSnapshot = this.state;
    if (!this.closed && this.countdownUntil > 0) {
      // 倒计时按截止时间现算（计时器在后台可能停过），不以上一次刷新的秒数为准。
      this.tick();
    }
    if (this.closed || s.sending || s.countdown > 0 || this.d.session.smsGate.active) {
      return false;
    }
    if (!this.valid()) {
      // 共性第 60 条：会话已变（即使清空通知还没到）——不读手机号、不占发码槽位、不发包。
      return false;
    }
    const phone: string | null = this.d.stepUpPhone(this.account);
    if (phone === null) {
      // TODO(N-32) G31 / rule-gaps H：本机取不到当前账号的手机号，不编造、不让用户另填。
      s.noPhone = true;
      s.error = WalletMessages.of('step_up.no_phone');
      this.emit();
      return false;
    }
    const clock: SmsResendClock = this.d.session.sms;
    const key: string = SmsResendClock.key(this.account, phone, this.action);
    const now: number = this.d.clock();
    const ticket: number = clock.begin(key, now);
    if (ticket === 0) {
      // 截止时间没过（别的面板实例刚发过）或发送在途：不发，显示同一倒计时。
      const left: number = clock.remainingMs(key, now);
      if (left > 0) {
        s.sent = true;
        this.countdownUntil = now + left;
        this.tick();
      }
      s.sending = clock.sending(key);
      this.emit();
      return false;
    }
    s.sending = true;
    s.error = null;
    this.emit();
    const body: Record<string, string> = {};
    body['phone'] = phone;
    body['purpose'] = 'step_up';
    body['action'] = this.action;
    const request: ApiRequest = new ApiRequest(StepUpController.SEND_OPERATION, {}, '', JSON.stringify(body));
    // 只按打开面板的发起身份（会话归属、账号、世代；面板关闭不取消已发出的发码：结果要记进共享截止时间）。
    request.owner = (): boolean => this.sameSession();
    request.sendAllowed = (): boolean => this.d.session.smsGate.sendAllowed();
    const d: WalletDeps = this.d;
    this.d.api.request(request).then((result: ApiResult) => {
      // 共享部分先做，不看面板是否还开着（R2-02）：只按发出时的账号与会话归属写截止时间与 42901 限流。
      const sameSession: boolean = this.sameSession();
      if (!sameSession) {
        clock.finish(key, null, new SmsSendOutcome(false, null), ticket);
        return;
      }
      if (result.ok) {
        const sec: number = WalletJson.resendAfterSec(result.data);
        clock.finish(key, d.clock() + sec * 1000, new SmsSendOutcome(true, null), ticket);
        return;
      }
      const failure: WalletLoadFailure = WalletLoadFailure.of(result);
      if (failure.kind === WalletLoadFailure.RATE && failure.disableMs > 0) {
        d.session.smsGate.start(failure.disableMs);
      }
      if (result.code === 10405) {
        d.forceUpdate();
      }
      const message: WalletMessage = result.code === 20001
        ? WalletMessages.of(ErrorActionMapper.textKey(20001, null) ?? 'error.20001') : failure.message;
      clock.finish(key, null, new SmsSendOutcome(false, message), ticket);
    });
    return true;
  }

  /** 共享发码服务发布的结算（本面板发出的，或打开前已在途的）：解除 sending，成功恢复倒计时，失败显示提示并回到可重试。 */
  private settled(key: string, outcome: SmsSendOutcome): void {
    if (!this.valid()) {
      return;
    }
    const s: StepUpSnapshot = this.state;
    s.sending = false;
    if (outcome.ok) {
      const left: number = this.d.session.sms.remainingMs(key, this.d.clock());
      s.sent = true;
      s.error = null;
      this.countdownUntil = this.d.clock() + left;
      this.tick();
    } else if (outcome.error !== null) {
      s.error = outcome.error;
    }
    this.emit();
  }

  /** 输入（只留数字，最多 6 位）。 */
  setCode(text: string): void {
    if (!this.valid()) {
      // 共性第 59、60 条：会话已变的旧输入回调不写进面板。
      return;
    }
    const digits: string = text.replace(/[^0-9]/g, '').substring(0, 6);
    this.state.code = digits;
    if (digits.length > 0) {
      this.state.error = null;
    }
    this.emit();
  }

  get canVerify(): boolean {
    const s: StepUpSnapshot = this.state;
    return this.valid() && s.code.length === 6 && !s.verifying && !this.d.session.verifyGate.active;
  }

  /** 【验证并提交】。 */
  verify(): boolean {
    if (!this.canVerify) {
      return false;
    }
    const s: StepUpSnapshot = this.state;
    const seq: number = ++this.verifySeq;
    s.verifying = true;
    s.error = null;
    this.emit();
    const body: Record<string, string> = {};
    body['action'] = this.action;
    body['code'] = s.code;
    const request: ApiRequest = new ApiRequest(StepUpController.VERIFY_OPERATION, {}, '', JSON.stringify(body));
    // 归属只按会话与账号（同发码，共性第 27 条）：面板关闭后到达的 42901 仍写进共享验证限流；结果本身（含 token）面板关了就丢弃。
    const d: WalletDeps = this.d;
    request.owner = (): boolean => this.sameSession();
    request.sendAllowed = this.d.session.verifyGate.sendAllowed;
    this.d.api.request(request).then((result: ApiResult) => {
      if (!this.sameSession()) {
        return;
      }
      if (!result.ok) {
        const failure: WalletLoadFailure = WalletLoadFailure.of(result);
        if (failure.kind === WalletLoadFailure.RATE && failure.disableMs > 0) {
          d.session.verifyGate.start(failure.disableMs);
        }
      }
      if (!this.valid() || seq !== this.verifySeq) {
        return;
      }
      s.verifying = false;
      if (result.ok) {
        const grant: StepUpGrant | null = WalletJson.stepUp(result.data);
        if (grant === null) {
          s.error = WalletMessages.of(WalletMessages.GENERIC_KEY);
          this.emit();
          return;
        }
        this.d.session.tokens.put(this.action, this.account, grant.token, grant.expireAtMs);
        this.close();
        this.onToken(grant.token);
        return;
      }
      this.failure(result);
    });
    return true;
  }

  private failure(result: ApiResult): void {
    const s: StepUpSnapshot = this.state;
    const code: number = result.code;
    if (code === 20002 || code === 20003) {
      s.code = '';
      s.clearSeq++;
      s.error = WalletMessages.of('error.' + code);
      this.emit();
      return;
    }
    const failure: WalletLoadFailure = WalletLoadFailure.of(result);
    // 42901 的共享验证限流已在响应处理开头写入（不论面板是否还开着）。
    if (code === 10405) {
      this.d.forceUpdate();
    }
    if (code === 20001) {
      s.error = WalletMessages.of(ErrorActionMapper.textKey(20001, null) ?? 'error.20001');
    } else {
      s.error = failure.message;
    }
    this.emit();
  }

  private tick(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const left: number = Math.max(0, Math.ceil((this.countdownUntil - this.d.clock()) / 1000));
    this.state.countdown = left;
    if (left > 0 && !this.closed) {
      this.timer = setTimeout((): void => {
        this.timer = -1;
        this.tick();
        this.emit();
      }, 1000);
    }
  }

  /** 关闭面板（关闭按钮、系统返回、拿到 token、会话变化）：之后迟到的结果只丢弃。 */
  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.unsubscribe();
    this.state.code = '';
  }

  private emit(): void {
    this.state.sendBlocked = this.d.session.smsGate.active;
    this.state.verifyBlocked = this.d.session.verifyGate.active;
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }
}
