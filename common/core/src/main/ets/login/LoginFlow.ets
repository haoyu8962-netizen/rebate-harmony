import { ApiOperation, ApiOperations, BundledConfig } from 'generated';
import {
  EffectKind, ErrorActionInput, ErrorActionMapper, ErrorActionState, ErrorEffect, ErrorUpdateState
} from '../network/ErrorActionMapper';
import { SessionScope } from '../network/NetworkPolicy';

/**
 * 短信登录主链路的纯逻辑（APP-05a；BR-ID-04、BR-ID-05、BR-ID-10、BR-INV-02、BR-INV-06、BR-TEXT-14；03 §4.2）。
 * 三端同名；向量 specs/login-vectors.json（LoginVector.test.ets）。没有界面、网络与计时器：执行器是 LoginService，
 * 页面在 features/auth。
 */

/** 手机号规范化结果。 */
export class PhoneResult {
  readonly valid: boolean;
  /** 规范化后的 11 位号码；不合法为 null。 */
  readonly normalized: string | null;
  /** 不合法的原因（与服务端 20001 data.reason 同名：phone_invalid）；合法为 null。 */
  readonly reasonRaw: string | null;

  constructor(valid: boolean, normalized: string | null, reasonRaw: string | null) {
    this.valid = valid;
    this.normalized = normalized;
    this.reasonRaw = reasonRaw;
  }
}

/**
 * 手机号规范化（BR-ID-05 细则「手机号规范化」normalize_phone，与服务端同一规格）：
 * ① NFKC；② 删除全部空白（含 U+3000、U+00A0）、零宽字符（U+200B–U+200D、U+FEFF）与连字符（「-」及 U+2010–U+2015）；
 * ③ 去国家码：「+86」开头，或「0086」「86」开头且其后恰为 11 位数字；④ 必须匹配 ^1[3-9][0-9]{9}$。
 * 服务端永远自己再规范化一遍，客户端结果只用于提示与提交（不以客户端为准）。
 */
export class PhoneNumber {
  static readonly REASON_INVALID: string = 'phone_invalid';
  private static readonly STRIP: RegExp = /[\s​-‍﻿\-‐-―]/g;
  private static readonly PATTERN: RegExp = /^1[3-9][0-9]{9}$/;

  static normalize(raw: string): PhoneResult {
    let text: string = PhoneNumber.nfkc(raw).replace(PhoneNumber.STRIP, '');
    if (text.startsWith('+86')) {
      text = text.substring(3);
    } else if (text.startsWith('0086') && /^[0-9]{11}$/.test(text.substring(4))) {
      text = text.substring(4);
    } else if (text.startsWith('86') && /^[0-9]{11}$/.test(text.substring(2))) {
      text = text.substring(2);
    }
    if (!PhoneNumber.PATTERN.test(text)) {
      return new PhoneResult(false, null, PhoneNumber.REASON_INVALID);
    }
    return new PhoneResult(true, text, null);
  }

  /** 页面显示用的脱敏号码：138****5678（设计稿 LoginCode「验证码已发送至」）。 */
  static masked(normalized: string): string {
    if (normalized.length !== 11) {
      return normalized;
    }
    return normalized.substring(0, 3) + '****' + normalized.substring(7);
  }

  /** 输入框显示的分组：138 0000 5678（只给合法号码分组，其余原样）。 */
  static grouped(normalized: string): string {
    if (normalized.length !== 11) {
      return normalized;
    }
    return normalized.substring(0, 3) + ' ' + normalized.substring(3, 7) + ' ' + normalized.substring(7);
  }

  static nfkc(raw: string): string {
    try {
      return raw.normalize('NFKC');
    } catch (e) {
      return raw;
    }
  }
}

/**
 * 登录页的协议勾选（BR-ID-04：勾选框默认不勾；未勾选点登录 → 确认框；同意后记下点击时刻并继续）。
 * consentAtMillis 是本机记下的勾选 / 确认时刻（登录请求的 consent_at），不是服务端已写入 consent_records。
 * 取消勾选时清除记下的时刻：之后再登录必须重新确认（TODO(N-26) AGREEMENT-01：历史时刻的去留未规定，保守清除）。
 */
export class AgreementState {
  checked: boolean = false;
  /** 确认框正在显示。 */
  showConfirm: boolean = false;
  /** 最近一次点登录（或在确认框里同意）之后可以继续登录。 */
  proceed: boolean = false;
  consentAtMillis: number | null = null;
  private readonly clock: () => number;

  constructor(clock: () => number) {
    this.clock = clock;
  }

  /** 点【获取验证码】或【登录】：已勾选直接继续；未勾选弹确认框。 */
  tapLogin(): void {
    if (this.checked && this.consentAtMillis !== null) {
      this.showConfirm = false;
      this.proceed = true;
      return;
    }
    this.showConfirm = true;
    this.proceed = false;
  }

  check(): void {
    this.checked = true;
    this.consentAtMillis = this.clock();
    this.showConfirm = false;
    this.proceed = false;
  }

  uncheck(): void {
    this.checked = false;
    this.consentAtMillis = null;
    this.proceed = false;
  }

  /** 确认框【同意并继续】：勾上并记下点击时刻（实参，安全整数毫秒）。 */
  confirm(nowMillis: number): void {
    this.checked = true;
    this.consentAtMillis = nowMillis;
    this.showConfirm = false;
    this.proceed = true;
  }

  /** 确认框【取消】或关闭：不勾选、不继续。 */
  cancel(): void {
    this.showConfirm = false;
    this.proceed = false;
  }

  /** 页面取走「继续」一次（避免同一次同意触发两次请求）。 */
  consumeProceed(): boolean {
    const go: boolean = this.proceed;
    this.proceed = false;
    return go;
  }
}

/** 发码之后的倒计时与页面状态。 */
export class SmsCountdownResult {
  readonly countdownSec: number;
  readonly canResend: boolean;
  /** code_sent / rate_limited / 其余同 LoginErrorMapper 的 stateRaw。 */
  readonly stateRaw: string;
  readonly textKey: string | null;

  constructor(countdownSec: number, canResend: boolean, stateRaw: string, textKey: string | null) {
    this.countdownSec = countdownSec;
    this.canResend = canResend;
    this.stateRaw = stateRaw;
    this.textKey = textKey;
  }
}

/**
 * 发码倒计时（BR-ID-05：60 秒 1 条；03 §4.2、BR-TEXT-14：42901 按 Retry-After 禁用触发按钮，缺省 5 秒——
 * 编排者 2026-10-07 更正，不取较大者）。Retry-After 的解析与 ErrorActionMapper 同一个函数（不另造）。
 */
export class SmsCountdown {
  static readonly RESEND_SECONDS: number = 60;
  static readonly STATE_SENT: string = 'code_sent';
  static readonly STATE_RATE_LIMITED: string = 'rate_limited';

  static after(code: number, retryAfterHeader: string | undefined, _nowMillis: number): SmsCountdownResult {
    const headers: Record<string, string> = {};
    if (retryAfterHeader !== undefined) {
      headers['Retry-After'] = retryAfterHeader;
    }
    return SmsCountdown.fromMillis(code, ErrorActionMapper.retryAfterMillis(headers), {});
  }

  /**
   * 执行器用（ApiResult 不带响应头，ErrorEffect.disableMillis 已是同一函数算出的禁用毫秒数）。成功时取 60 秒；
   * data.resend_after_sec 更大时按它（契约：至少 60，取各项限制最晚的解除时刻）。TODO(N-26) SMS-01：小于 60、缺头、
   * HTTP-date 等由 ErrorActionMapper 统一兜底（缺省 5 秒）。
   */
  static fromMillis(code: number, disableMillis: number, data: Record<string, Object>): SmsCountdownResult {
    if (code === 0) {
      let seconds: number = SmsCountdown.RESEND_SECONDS;
      const resend: Object | undefined = data['resend_after_sec'];
      if (typeof resend === 'number' && Number.isInteger(resend as number) && (resend as number) > seconds
        && (resend as number) <= ErrorActionMapper.MAX_RETRY_AFTER_SECONDS) {
        seconds = resend as number;
      }
      return new SmsCountdownResult(seconds, false, SmsCountdown.STATE_SENT, null);
    }
    const mapped: LoginErrorResult = LoginErrorMapper.map(LoginErrorMapper.SEND_SMS_CODE, code, data);
    if (code === 42901) {
      const seconds: number = Math.max(1, Math.ceil(disableMillis / 1000));
      return new SmsCountdownResult(seconds, false, SmsCountdown.STATE_RATE_LIMITED, mapped.textKey);
    }
    return new SmsCountdownResult(0, true, mapped.stateRaw, mapped.textKey);
  }
}

/** 验证码输入的形状（只报告原字符串，不规定 UI 清洗，rule-gaps CODE-01）。 */
export class CodeShape {
  readonly complete: boolean;
  readonly digitsOnly: boolean;

  constructor(complete: boolean, digitsOnly: boolean) {
    this.complete = complete;
    this.digitsOnly = digitsOnly;
  }
}

/** 6 位短信验证码（BR-ID-05；openapi LoginBySmsRequest.code ^[0-9]{6}$）。 */
export class CodeInput {
  static readonly LENGTH: number = 6;

  static accept(raw: string): CodeShape {
    return new CodeShape(/^[0-9]{6}$/.test(raw), /^[0-9]*$/.test(raw));
  }

  /** 输入框的清洗：只留 ASCII 数字，最多 6 位（页面用；TODO(N-26) CODE-01：全角与粘贴策略未规定，保守只收 ASCII）。 */
  static sanitize(raw: string): string {
    const digits: string = raw.replace(/[^0-9]/g, '');
    return digits.length > CodeInput.LENGTH ? digits.substring(0, CodeInput.LENGTH) : digits;
  }
}

/** 登录相关错误码在页面上的状态与文案（经 ErrorActionMapper，不另造码表）。 */
export class LoginErrorResult {
  /**
   * field_error / code_error / code_expired / rate_limited / risk_blocked / registration_blocked（LoginCodeBlocked）/
   * force_update / deletion_processing（LoginDeletionProcessing）/ session_expired（LoginSessionExpired）/
   * provider_unavailable / service_error / network_error / toast / message。
   */
  readonly stateRaw: string;
  readonly textKey: string | null;
  /** 要在旁边提示的字段（phone / code / invite_code…）；没有为 null。 */
  readonly field: string | null;
  /** 网络层或页面要去的路由（ForceUpdate、Login…）；没有为 null。 */
  readonly route: string | null;
  /** 禁用触发按钮的毫秒数（42901）；其余 0。 */
  readonly disableMillis: number;

  constructor(stateRaw: string, textKey: string | null, field: string | null, route: string | null,
    disableMillis: number = 0) {
    this.stateRaw = stateRaw;
    this.textKey = textKey;
    this.field = field;
    this.route = route;
    this.disableMillis = disableMillis;
  }
}

export class LoginErrorMapper {
  static readonly SEND_SMS_CODE: string = 'sendSmsCode';
  static readonly LOGIN_BY_SMS: string = 'loginBySms';

  /** op 是 operationId；code 是业务码；data 是外壳 data。 */
  static map(op: string, code: number, data: Record<string, Object>,
    headers: Record<string, string> = {}): LoginErrorResult {
    const operation: ApiOperation | undefined = ApiOperations.byId(op);
    if (operation === undefined) {
      return new LoginErrorResult('message', null, null, null);
    }
    // 登录页没有会话：按「不低于、正常作用域」映射（rule-gaps ERROR-01：10405 受限令牌、强更中 10404 由网络层按真实状态处理）。
    const effect: ErrorEffect = ErrorActionMapper.map(new ErrorActionInput(code, data, operation, headers, false,
      new ErrorActionState(ErrorUpdateState.SUPPORTED, SessionScope.FULL, '')));
    return LoginErrorMapper.ofEffect(op, code, effect);
  }

  /** 网络层已给出的 Effect（ApiResult.effect）→ 页面状态。 */
  static ofEffect(op: string, code: number, effect: ErrorEffect): LoginErrorResult {
    const key: string | null = effect.textKey;
    const route: string | null = effect.route;
    switch (code) {
      case 20002:
        return new LoginErrorResult('code_error', key, 'code', route);
      case 20003:
        return new LoginErrorResult('code_expired', key, 'code', route);
      case 44001:
        // 发码被拦：只提示；登录（注册）被拦：LoginCodeBlocked 弹窗（不建号，验证码要重新获取）。
        return new LoginErrorResult(op === LoginErrorMapper.LOGIN_BY_SMS ? 'registration_blocked' : 'risk_blocked',
          key, null, route);
      case 10007:
        if (route === null) {
          return new LoginErrorResult('deletion_processing', key, null, null);
        }
        break;
      default:
        break;
    }
    switch (effect.effectKindRaw) {
      case EffectKind.FIELD_ERROR:
        return new LoginErrorResult('field_error', key, effect.fields.length > 0 ? effect.fields[0] : null, route);
      case EffectKind.DISABLE_BUTTON:
        return new LoginErrorResult('rate_limited', key, null, route, effect.disableMillis);
      case EffectKind.FORCE_UPDATE:
        return new LoginErrorResult('force_update', key, null, route);
      case EffectKind.CLEAR_SESSION_LOGIN:
      case EffectKind.CLEAR_SESSION_STAY_FORCE_UPDATE:
        return new LoginErrorResult('session_expired', key, null, route);
      case EffectKind.GENERIC_ERROR:
      case EffectKind.NETWORK_ERROR:
        return new LoginErrorResult(effect.effectKindRaw === EffectKind.NETWORK_ERROR ? 'network_error' : 'service_error',
          key, null, route);
      case EffectKind.PAGE_ACTION:
        return new LoginErrorResult(code === 50305 ? 'provider_unavailable' : 'page_action', key, null, route);
      case EffectKind.FALLBACK_MESSAGE:
        return new LoginErrorResult('message', key, null, route);
      default:
        return new LoginErrorResult('toast', key, null, route);
    }
  }
}

/** 邀请码输入框的判定。 */
export class InviteDecision {
  readonly showInviteField: boolean;
  /** 只判注册页可接受的语法（空值可省略）；不决定能否登录（rule-gaps INVITE-01）。 */
  readonly valid: boolean;
  /** 规范化后的码（空串 = 不带 invite_code）。 */
  readonly normalized: string;
  /** 输入框下方的告知句（BR-INV-18 细则）；不显示输入框时为 null。 */
  readonly noticeKey: string | null;

  constructor(showInviteField: boolean, valid: boolean, normalized: string, noticeKey: string | null) {
    this.showInviteField = showInviteField;
    this.valid = valid;
    this.normalized = normalized;
    this.noticeKey = noticeKey;
  }
}

/**
 * 注册页邀请码（BR-INV-01 字符集 23456789ABCDEFGHJKLMNPQRSTUVWXYZ、长度 6；BR-INV-02 规范化：NFKC → 删空白与零宽 → 大写，
 * 不做 O→0 纠错、不删连字符）。受限登录（从强更页进入）不显示邀请码等业务输入（BR-ID-01 细则「受限登录」）。
 */
export class InviteField {
  static readonly NOTICE_KEY: string = 'invite.notice_inviter';
  /** openapi LoginBySmsRequest.invite_code maxLength。 */
  static readonly MAX_WIRE_LENGTH: number = 32;
  private static readonly STRIP: RegExp = /[\s​-‍﻿]/g;
  private static readonly PATTERN: RegExp = /^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/;

  static normalize(raw: string): string {
    return PhoneNumber.nfkc(raw).replace(InviteField.STRIP, '').toUpperCase();
  }

  static decide(raw: string, context: Record<string, Object>): InviteDecision {
    const normalized: string = InviteField.normalize(raw);
    const valid: boolean = normalized.length === 0 || InviteField.PATTERN.test(normalized);
    if (context['restricted'] === true) {
      return new InviteDecision(false, valid, '', null);
    }
    return new InviteDecision(true, valid, normalized, InviteField.NOTICE_KEY);
  }

  /**
   * 登录请求里带的 invite_code：受限登录不带；规范化后为空不带；超过契约长度不带（否则整个登录 20001）。
   * 语法不对的照样带上，由服务端判（失败只回 invite_bind.failed，不阻止注册，INVITE-01）。
   */
  static wireValue(raw: string, restricted: boolean): string | null {
    if (restricted) {
      return null;
    }
    const normalized: string = InviteField.normalize(raw);
    if (normalized.length === 0 || normalized.length > InviteField.MAX_WIRE_LENGTH) {
      return null;
    }
    return normalized;
  }
}

/** 登录成功后的动作（AfterLogin.plan 的元素；三端同名）。 */
export class AfterLoginAction {
  /** 会话已由 ApiClient 保存（执行器只在 ApiClient 返回成功后继续，INTEGRATION-01）。 */
  static readonly SAVE_SESSION: string = 'save_session';
  /** 交给 Router 守卫恢复 pending_action（BR-ID-10）。 */
  static readonly RESUME_PENDING: string = 'resume_pending';
  /** 受限会话或强更：删除业务类 pending_action，不执行。 */
  static readonly DISCARD_PENDING: string = 'discard_pending';
  static readonly ENTER_FORCE_UPDATE: string = 'enter_force_update';
  /**
   * 受限会话与强更「不低于」并存（本机结论与服务端不一致，AFTER-02）：结论未定，不动待办；执行器先做一次受限会话复查
   * （单飞刷新），再按最新的作用域与强更结论重新计划（harmony-review-r1 R1-04）。
   */
  static readonly REFRESH_RESTRICTED: string = 'refresh_restricted';
}

/** AfterLogin.plan 的强更状态取值。 */
export class AfterLoginUpdate {
  static readonly SUPPORTED: string = 'supported';
  static readonly BELOW: string = 'below';
  static readonly UNKNOWN: string = 'unknown';
  static readonly CHECKING: string = 'checking';
}

/**
 * 登录成功后的会话 / 路由计划（03 §4.2「受限会话」、§4.4；BR-ID-01、BR-ID-10）：
 * - 先 save_session（ApiClient 已保存成功才算登录成功）；
 * - 受限会话（deletion_only）且强更低于 / 未知 / 检查中：丢弃业务 pending_action，进强更页；
 * - 正常会话但强更低于：同样丢弃并进强更页（正常会话不绕过强更）；
 * - 其余：有 pending_action 时交给 Router 守卫恢复（未知 / 检查中由 Router 自己等待或按只读清单处理）。
 * 邀请绑定结果（invite_bind）不改变计划、不截断登录（AFTER-03）。
 * - deletion_only 且强更为 supported（本机结论与服务端不一致，AFTER-02）：结论未定，不删 pending_action，计划
 *   refresh_restricted——执行器显式复查受限会话后按最新状态重新计划（R1-04：原先在这里丢弃待办，而 ApiClient 保存新会话时
 *   已记下「不需要受限屏障」，注释所依赖的后续刷新不会发生，待办实际丢失）。
 */
export class AfterLogin {
  static plan(response: Record<string, Object>, state: Record<string, Object>): string[] {
    const actions: string[] = [AfterLoginAction.SAVE_SESSION];
    const restricted: boolean = response['session_scope'] === SessionScope.DELETION_ONLY;
    const update: Object | undefined = state['update'];
    const pending: boolean = state['pendingAction'] === true;
    const below: boolean = update === AfterLoginUpdate.BELOW;
    const notSupported: boolean = update !== AfterLoginUpdate.SUPPORTED;
    if ((restricted && notSupported) || below) {
      if (pending) {
        actions.push(AfterLoginAction.DISCARD_PENDING);
      }
      actions.push(AfterLoginAction.ENTER_FORCE_UPDATE);
      return actions;
    }
    if (restricted) {
      actions.push(AfterLoginAction.REFRESH_RESTRICTED);
      return actions;
    }
    if (pending) {
      actions.push(AfterLoginAction.RESUME_PENDING);
    }
    return actions;
  }
}

/** 登录请求上送的协议版本（BR-ID-04；openapi LegalVersions）。 */
export class LegalVersions {
  readonly privacy: number;
  readonly agreement: number;

  constructor(privacy: number, agreement: number) {
    this.privacy = privacy;
    this.agreement = agreement;
  }

  /**
   * 包内当前版本：生成的包内默认配置（BundledConfig，default_config.json 的 legal.privacy.version、legal.agreement.version）。
   * 读不出时按 1（契约最小值）。TODO(N-26) LEGAL-01：首启弹窗的 BundledLegal.PRIVACY_POLICY_VERSION 仍是占位 1，与包内默认配置
   * 不一致，待法务定稿随包导出协议副本后统一。
   */
  static bundled(): LegalVersions {
    return LegalVersions.parse(BundledConfig.DATA_JSON);
  }

  static parse(configJson: string): LegalVersions {
    try {
      const root: Record<string, Object> = JSON.parse(configJson) as Record<string, Object>;
      const legal: Record<string, Object> = root['legal'] as Record<string, Object>;
      const privacy: Record<string, Object> = legal['privacy'] as Record<string, Object>;
      const agreement: Record<string, Object> = legal['agreement'] as Record<string, Object>;
      return new LegalVersions(LegalVersions.version(privacy['version']), LegalVersions.version(agreement['version']));
    } catch (e) {
      return new LegalVersions(1, 1);
    }
  }

  private static version(raw: Object | undefined): number {
    return typeof raw === 'number' && Number.isInteger(raw as number) && (raw as number) >= 1 ? raw as number : 1;
  }
}
