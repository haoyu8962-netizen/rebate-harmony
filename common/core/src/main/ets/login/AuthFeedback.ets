import { BindOutcome } from './BindPhoneService';
import { SendCodeOutcome } from './LoginService';
import { BindPhoneAction, OAuthLoginErrorAction } from './OAuthLoginFlow';
import { OAuthLoginOutcome } from './OAuthLoginService';

/**
 * 绑手机页与第三方登录的失败怎样呈现（APP-05b harmony-review-r1 R1-05、R1-06；APP-05b 共性 5、6）。页面只按 kind 渲染：
 * - risk_dialog：44001 风控拦截（BR-TEXT-14 表 A「给申诉入口」）——弹窗，标题 error.44001（risk_msg 未下发时的默认句），
 *   按钮【知道了】与【联系客服申诉】（cs.appeal_entry，统一客服出口）；第三方登录不套用短信登录专用说明（descKey 为 null）。
 * - phone_error / code_error：字段错误（20001 手机号、20002 / 20003 验证码）——输入框下提示，读屏即时播报一次、无障碍焦点
 *   移到错误提示，错误说明关联到输入框；用户输入保留（03 §10.5）。
 * - navigate：错误码要求跳页（10007 stage=cooling → DeleteAccount 注销进度页，可撤回；BR-TEXT-14 表 A「不弹本提示」，R2-03）——
 *   页面经 Router 打开 route，不提示；stage=processing 是 toast。
 * - toast：其余错误轻提示；none：不提示（成功、取消、迟到、忙）。
 */
export class AuthFeedback {
  static readonly NONE: string = 'none';
  static readonly TOAST: string = 'toast';
  static readonly PHONE_ERROR: string = 'phone_error';
  static readonly CODE_ERROR: string = 'code_error';
  static readonly RISK_DIALOG: string = 'risk_dialog';
  /** 经 Router 打开 route（10007 冷静期 → DeleteAccount，R2-03），不弹提示。 */
  static readonly NAVIGATE: string = 'navigate';
  static readonly RISK_KEY: string = 'error.44001';
  /** 申诉入口的文案键（BR-TEXT-14 cs.appeal_entry）。 */
  static readonly APPEAL_KEY: string = 'cs.appeal_entry';
  static readonly RISK_OK_KEY: string = 'login.risk_blocked.ok';

  readonly kind: string;
  readonly textKey: string | null;
  /** 风控弹窗的说明句键（第三方登录与绑手机没有专用说明，为 null）。 */
  readonly descKey: string | null;
  /** 是否给申诉入口。 */
  readonly appeal: boolean;
  /** navigate 时要打开的路由；其余为 null。 */
  readonly route: string | null;

  constructor(kind: string, textKey: string | null = null, descKey: string | null = null, appeal: boolean = false,
    route: string | null = null) {
    this.kind = kind;
    this.textKey = textKey;
    this.descKey = descKey;
    this.appeal = appeal;
    this.route = route;
  }

  private static navigate(route: string | null): AuthFeedback | null {
    return route === null ? null : new AuthFeedback(AuthFeedback.NAVIGATE, null, null, false, route);
  }

  private static risk(): AuthFeedback {
    return new AuthFeedback(AuthFeedback.RISK_DIALOG, AuthFeedback.RISK_KEY, null, true);
  }

  /** 绑定（bindPhone）的结果。 */
  static ofBind(outcome: BindOutcome): AuthFeedback {
    switch (outcome.actionRaw) {
      case BindPhoneAction.DONE:
      case BindPhoneAction.MERGE_CONFIRM:
      case BindOutcome.STALE:
      case BindOutcome.BUSY:
      case BindOutcome.CODE_INCOMPLETE:
        return new AuthFeedback(AuthFeedback.NONE);
      case BindOutcome.PHONE_INVALID:
        return new AuthFeedback(AuthFeedback.PHONE_ERROR, outcome.textKey ?? 'error.20001');
      case BindOutcome.NAVIGATE:
        return AuthFeedback.navigate(outcome.route) ?? AuthFeedback.ofKey(outcome.textKey);
      default:
        break;
    }
    return AuthFeedback.ofKey(outcome.textKey);
  }

  /** 绑手机发码（sendSmsCode purpose=bind）的失败；成功、倒计时与限流由页面自己处理。 */
  static ofBindSend(outcome: SendCodeOutcome): AuthFeedback {
    if (outcome.stateRaw === BindOutcome.STALE || outcome.stateRaw === BindOutcome.BUSY) {
      return new AuthFeedback(AuthFeedback.NONE);
    }
    if (outcome.stateRaw === BindOutcome.NAVIGATE) {
      return AuthFeedback.navigate(outcome.route) ?? AuthFeedback.ofKey(outcome.textKey);
    }
    if (outcome.textKey === AuthFeedback.RISK_KEY) {
      return AuthFeedback.risk();
    }
    if (outcome.field === 'phone') {
      return new AuthFeedback(AuthFeedback.PHONE_ERROR, outcome.textKey ?? 'error.20001');
    }
    return AuthFeedback.ofKey(outcome.textKey);
  }

  /** 第三方登录的失败（risk_blocked → 风控弹窗与申诉入口，R1-05）。 */
  static ofOAuth(outcome: OAuthLoginOutcome): AuthFeedback {
    if (outcome.stateRaw === OAuthLoginErrorAction.RISK_BLOCKED) {
      return AuthFeedback.risk();
    }
    return new AuthFeedback(AuthFeedback.TOAST, outcome.textKey);
  }

  private static ofKey(textKey: string | null): AuthFeedback {
    if (textKey === AuthFeedback.RISK_KEY) {
      return AuthFeedback.risk();
    }
    if (textKey === 'error.20002' || textKey === 'error.20003') {
      return new AuthFeedback(AuthFeedback.CODE_ERROR, textKey);
    }
    if (textKey === 'error.20001.phone_invalid') {
      return new AuthFeedback(AuthFeedback.PHONE_ERROR, textKey);
    }
    return new AuthFeedback(AuthFeedback.TOAST, textKey);
  }
}
