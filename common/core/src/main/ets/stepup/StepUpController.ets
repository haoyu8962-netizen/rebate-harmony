// 二次验证面板的执行器（StepUpSheet；APP-09 brief §2.6、APP-13a §2 第 7 项；BR-ID-08 短信方式、BR-WDR-01）。
// APP-13a：从 wallet/ 挪到共用位置，依赖改为通用接口 StepUpDeps（钱包与账号的执行器依赖都实现它），支持 withdraw、
// payout_account、phone_change、account_deletion 四个 action；受限会话（deletion_only）下只允许 account_deletion，其余本地拒绝、不发请求。
// 拿到的 token 记进共享缓存时绑定打开面板的会话归属（scope），按账号、会话归属与 action 隔离（APP-13a G23）。
// - 打开即对当前 action 发码：sendSmsCode {phone, purpose: step_up, action}。号码只用本机绑定了当前账号归属的规范化号码（G31）；取不到
//   不编造、不让用户另填，提示并登记空白（rule-gaps H 段）。
// - 「验证码已发送至你绑定的手机号」（G16，不显示号码）；倒计时按 resend_after_sec（未返回按 60 秒）。
// - 【验证并提交】输满 6 位才可用 → stepUp {action, code}；成功把 token 记进内存（按账号与 action，G17）并交给发起方，由发起方沿用原键重放。
// - 20002 / 20003：清空输入、assertive 播报；42901 发码与验证分开限流：发码按「账号 + 号码 + action」键（SmsResendClock，与倒计时同键，
//   harmony-review-r1 R1-10），验证用 verifyGate；10405 只在网络层判定 FORCE_UPDATE 时进强更（R1-07）。
// - 面板是敏感浮层：关闭或会话变化后迟到的结果只丢弃（APP-07 第 4 条）。
// - 重发截止时间在会话共享的 SmsResendClock（鸿蒙 R1-06，共性第 6 条）：按账号、号码、action 隔离；面板关闭重开时恢复倒计时，
//   每次实际发送前核对同一截止时间与「发送在途」。发码请求不随面板关闭取消（只按会话与账号归属），结果照样记下截止时间。
// - 发码结算由共享服务发布（鸿蒙 R2-01/R2-02，共性第 26、27 条）：请求回来先按账号 / 会话归属写共享截止时间与 42901 限流（面板
//   关了也写），再发布给订阅同一键的面板；在途期间重开的面板靠订阅解除 sending，恢复倒计时或重试状态。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { EffectKind, ErrorActionMapper } from '../network/ErrorActionMapper';
import { StepUpGrant, WalletJson } from '../wallet/WalletJson';
import { SmsResendClock, SmsSendOutcome, WalletLoadFailure, WalletMessage, WalletMessages } from '../wallet/WalletSession';
import { StepUpActions, StepUpDeps } from './StepUpPorts';

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
  /** 受限会话（deletion_only）下这个 action 不允许（只允许 account_deletion）：本地拒绝，不发请求。 */
  scopeDenied: boolean = false;
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
  private readonly d: StepUpDeps;
  private readonly account: string;
  private readonly scope: string;
  /** 打开面板的提交 / 确认所属的钱包会话世代（共性第 60 条）；null 只给不经页面的直接构造（单测），不核对世代。 */
  private readonly epoch: number | null;
  private closed: boolean = false;
  private timer: number = -1;
  private rateTimer: number = -1;
  /** 本面板的发码键（打开时按本机号码算一次，发码时更新；取不到号码为 null）。不在 emit 里重读号码（共性第 60 条）。 */
  private sendKey: string | null = null;
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
  constructor(deps: StepUpDeps, action: string, account: string, scope: string | null = null,
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
    // 重开面板：同一账号、号码、action 的截止时间还没过 → 恢复「已发送」与倒计时（不再自动发码）。
    const phone: string | null = deps.stepUpPhone(account);
    this.sendKey = phone === null ? null : SmsResendClock.key(account, phone, action);
    // 打开时就反映共享限流（关闭的面板收到的 42901 也在这里体现，R2-02）。发码限流按本面板的键（账号 + 号码 + action，R1-10）。
    const rateMs: number = this.sendRateMs();
    this.state.sendBlocked = rateMs > 0;
    this.state.verifyBlocked = deps.session.verifyGate.active;
    // harmony-review-r2 R2-06：恢复了这把键已有的发码限流 → 立即安排该键的到期刷新（不依赖只作观察值的全局 smsGate 通知）。
    this.armRateRefresh(rateMs);
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

  /** 本面板这把键的发码 42901 剩余毫秒（R1-10：限流与倒计时同键，不再看全局闸门）。 */
  private sendRateMs(): number {
    const key: string | null = this.sendKey;
    return key === null ? 0 : this.d.session.sms.rateRemainingMs(key, this.d.clock());
  }

  /** 打开即发码（也是【重新获取验证码】）。 */
  send(): boolean {
    const s: StepUpSnapshot = this.state;
    if (!this.closed && this.countdownUntil > 0) {
      // 倒计时按截止时间现算（计时器在后台可能停过），不以上一次刷新的秒数为准。
      this.tick();
    }
    if (this.closed || s.sending || s.countdown > 0) {
      return false;
    }
    if (!this.valid()) {
      // 共性第 60 条：会话已变（即使清空通知还没到）——不读手机号、不占发码槽位、不发包。
      return false;
    }
    if (this.denied()) {
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
    this.sendKey = key;
    const now: number = this.d.clock();
    if (clock.rateRemainingMs(key, now) > 0) {
      // R1-10：这把键（账号 + 号码 + action）还在 42901 禁用期：不发，按钮置灰。
      this.emit();
      return false;
    }
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
    // 执行层：每次实际发包前按同一把键核对 42901（R1-10）。
    request.sendAllowed = (): boolean => clock.rateRemainingMs(key, this.d.clock()) === 0;
    const d: StepUpDeps = this.d;
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
        // R1-10：限流记在这把键上（同键的面板共享、面板关了也记）；smsGate 只作「本会话有发码被限流」的汇总观察值，不再用于放行判断。
        clock.rateLimit(key, d.clock() + failure.disableMs);
        d.session.smsGate.start(failure.disableMs);
      }
      if (StepUpController.forcesUpdate(result)) {
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
    return this.valid() && s.code.length === 6 && !s.verifying && !this.d.session.verifyGate.active
      && StepUpActions.allowedIn(this.d.stepUpRestricted(), this.action);
  }

  /**
   * APP-13a §2 第 7 项：受限会话（deletion_only）下只允许 account_deletion；其他 action 本地拒绝（提示并置灰，不发码、不验证）。
   * 受限表由网络层另在发包前拦截（ApiClient.restrictedBodyAllowed），这里在页面一侧先拦，不让请求走到网络层。
   */
  private denied(): boolean {
    if (StepUpActions.allowedIn(this.d.stepUpRestricted(), this.action)) {
      return false;
    }
    const s: StepUpSnapshot = this.state;
    s.scopeDenied = true;
    s.error = WalletMessages.of('step_up.no_phone');
    this.emit();
    return true;
  }

  /** 【验证并提交】。 */
  verify(): boolean {
    if (this.valid() && this.denied()) {
      return false;
    }
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
    const d: StepUpDeps = this.d;
    // FU-HM-0722（APP-13a 共性 43，Android R3-01）：发起时固定 token 失效世代。回包之前别处的换号 / 绑手机成功（或会话换代）已统一
    // 作废 token 时，这次签发的 token 不写共享缓存、不交给发起方（换号第 1 步不进第 2 步，提交也就带不上它）。
    const tokenGen: number = d.session.tokens.generation;
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
        if (d.session.tokens.generation !== tokenGen) {
          // 共性 43：先作废、后到达的验证成功：丢弃 token，面板留在可输入状态，清空验证码请用户重新验证（提示复用 error.10003，G01）。
          s.code = '';
          s.clearSeq++;
          s.error = WalletMessages.of('error.10003');
          this.emit();
          return;
        }
        // APP-13a G23：token 绑定打开面板的会话归属（scope，含登录序号、会话世代；账号页另含会话作用域），只放内存。
        this.d.session.tokens.put(this.action, this.account, grant.token, grant.expireAtMs, this.scope);
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
    if (StepUpController.forcesUpdate(result)) {
      this.d.forceUpdate();
    }
    if (code === 20001) {
      s.error = WalletMessages.of(ErrorActionMapper.textKey(20001, null) ?? 'error.20001');
    } else {
      s.error = failure.message;
    }
    this.emit();
  }

  /** R1-07：只有网络层判定 FORCE_UPDATE 的 10405 才进强更（REFRESH_ONLY 与刷新失败沿用网络层结论）。 */
  private static forcesUpdate(result: ApiResult): boolean {
    return result.effect !== null && result.effect.effectKindRaw === EffectKind.FORCE_UPDATE;
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
    if (this.rateTimer !== -1) {
      clearTimeout(this.rateTimer);
      this.rateTimer = -1;
    }
    this.unsubscribe();
    this.state.code = '';
  }

  /** 这把键的发码限流到期时再刷新一次（按钮恢复可点）；已安排的不重复安排。 */
  private armRateRefresh(rateMs: number): void {
    if (rateMs > 0 && this.rateTimer === -1 && !this.closed) {
      this.rateTimer = setTimeout((): void => {
        this.rateTimer = -1;
        if (!this.closed) {
          this.emit();
        }
      }, rateMs);
    }
  }

  private emit(): void {
    const rateMs: number = this.closed ? 0 : this.sendRateMs();
    this.state.sendBlocked = rateMs > 0;
    this.state.verifyBlocked = this.d.session.verifyGate.active;
    this.armRateRefresh(rateMs);
    try {
      this.onChange(this.state);
    } catch (e) {
      // 页面回调出错不影响执行器。
    }
  }
}
