import { PhoneNumber, PhoneResult, SmsCountdown } from './LoginFlow';
import { SendCodeOutcome } from './LoginService';

/** 一次读屏播报：文案键与变量（页面经文案字典取字，缺键用草稿键）。 */
export class AuthAnnouncement {
  readonly textKey: string;
  readonly vars: Map<string, string>;

  constructor(textKey: string, vars: Map<string, string> = new Map<string, string>()) {
    this.textKey = textKey;
    this.vars = vars;
  }
}

/**
 * 绑手机页的读屏状态播报（APP-05b harmony-review-r2 R2-04，共性 11；03 §10.5 引用的设计稿无障碍约定 §10）：
 * - 发码成功：对当前有效请求（号码仍是发起时的号码、页面未离开）播报一次脱敏发送对象「验证码已发送至 138****5678」；
 *   countdown_active（没有新发出）、失败、迟到（stale）都不播报。
 * - 倒计时：同一号码的等待（重发倒计时或 42901 Retry-After）由有效变为可重发时播报一次「可以重新获取验证码」；不逐秒播报。
 *   换号只重新记下状态、不播报；离页（dispose）之后一律不播报。
 * 纯逻辑，页面每次计时刷新调 tick、每个发码结果调 sendResult，按返回值播报。
 */
export class BindPhoneAnnouncer {
  static readonly CODE_SENT_KEY: string = 'login.code.sent_to';
  static readonly RESEND_READY_KEY: string = 'bind_phone.a11y.resend_ready';

  /** 上一次 tick 看到的号码（规范化；不合法为空串）与它当时是否在等待。 */
  private lastPhone: string | null = null;
  private lastWaiting: boolean = false;
  private disposed: boolean = false;

  /**
   * 发码结果。currentPhoneRaw：结果回来时输入框里的号码。只有 code_sent、号码仍是这次发出的号码、页面未离开时返回播报，
   * 同时把这个号码记为「等待中」（之后倒计时结束播报一次）。
   */
  sendResult(outcome: SendCodeOutcome, currentPhoneRaw: string): AuthAnnouncement | null {
    if (this.disposed || outcome.stateRaw !== SmsCountdown.STATE_SENT || outcome.phone === null) {
      return null;
    }
    const current: PhoneResult = PhoneNumber.normalize(currentPhoneRaw);
    if (current.normalized === null || current.normalized !== outcome.phone) {
      return null;
    }
    this.lastPhone = outcome.phone;
    this.lastWaiting = outcome.countdownSec > 0;
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('phone', PhoneNumber.masked(outcome.phone));
    return new AuthAnnouncement(BindPhoneAnnouncer.CODE_SENT_KEY, vars);
  }

  /**
   * 计时刷新（每秒、换号、页面重新出现）。waitingSec：这个号码此刻还要等几秒才能再发（重发倒计时与 42901 等待之和）。
   * 同一号码从「等待中」变为 0 时返回一次播报；其余返回 null。
   */
  tick(phoneRaw: string, waitingSec: number): AuthAnnouncement | null {
    if (this.disposed) {
      return null;
    }
    const phone: PhoneResult = PhoneNumber.normalize(phoneRaw);
    const key: string = phone.normalized ?? '';
    const waiting: boolean = waitingSec > 0;
    if (key !== this.lastPhone) {
      // 换号（含第一次看到）：只记下状态，不播报旧号码的结果。
      this.lastPhone = key;
      this.lastWaiting = waiting;
      return null;
    }
    const ended: boolean = this.lastWaiting && !waiting && key.length > 0;
    this.lastWaiting = waiting;
    return ended ? new AuthAnnouncement(BindPhoneAnnouncer.RESEND_READY_KEY) : null;
  }

  /** 离开页面：之后的发码结果与计时都不播报。 */
  dispose(): void {
    this.disposed = true;
  }
}
