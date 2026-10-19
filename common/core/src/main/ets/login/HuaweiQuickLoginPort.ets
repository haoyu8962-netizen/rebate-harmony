import { OAuthProvider } from './OAuthLoginFlow';
import { ThirdPartyAuthAdapter, ThirdPartyAuthKind, ThirdPartyAuthResult } from './OAuthLoginService';

/** Account Kit 的预取结果分类；真实 SDK 的错误码换算在 HM-14b 接入。 */
export class QuickLoginFallback {
  static readonly NOT_LOGGED_IN: string = 'not_logged_in';
  static readonly NO_PHONE: string = 'no_phone';
  static readonly NO_PERMISSION: string = 'no_permission';
  static readonly UNSUPPORTED: string = 'unsupported';
  static readonly ERROR: string = 'error';
}

export class QuickLoginPrefetch {
  readonly anonymousPhone: string | null;
  readonly fallback: string | null;

  private constructor(phone: string | null, fallback: string | null) {
    this.anonymousPhone = phone;
    this.fallback = fallback;
  }

  static phone(phone: string): QuickLoginPrefetch {
    return phone.trim().length === 0 ? QuickLoginPrefetch.failed(QuickLoginFallback.NO_PHONE) :
      new QuickLoginPrefetch(phone, null);
  }

  static failed(reason: string): QuickLoginPrefetch {
    return new QuickLoginPrefetch(null, reason);
  }
}

export class QuickLoginCredentialKind {
  static readonly CREDENTIAL: string = 'credential';
  static readonly CANCELLED: string = 'cancelled';
  static readonly AGREEMENT_NOT_ACCEPTED: string = 'agreement_not_accepted';
  static readonly NETWORK_ERROR: string = 'network_error';
  static readonly ERROR: string = 'error';
}

/** 凭证只在内存中交给服务端，不落盘、不输出到日志。 */
export class QuickLoginCredential {
  readonly kind: string;
  readonly authorizationCode: string | null;

  private constructor(kind: string, code: string | null) {
    this.kind = kind;
    this.authorizationCode = code;
  }

  static code(code: string): QuickLoginCredential {
    return new QuickLoginCredential(QuickLoginCredentialKind.CREDENTIAL, code);
  }

  static of(kind: string): QuickLoginCredential {
    return new QuickLoginCredential(kind, null);
  }

  toString(): string {
    return 'QuickLoginCredential(' + this.kind + ')';
  }
}

/** 监听的 Promise 表示该次事件已处理完；预取不触发授权，continueLogin 只用于确认同意后。 */
export interface HuaweiQuickLoginPort {
  prefetchAnonymousPhone(): Promise<QuickLoginPrefetch>;
  setAgreement(accepted: boolean): void;
  continueLogin(): void;
  listen(onClick: () => Promise<void>, onCredential: (result: QuickLoginCredential) => Promise<void>): void;
}

/** 正式能力接入前的端口：没有 SDK 初始化或授权副作用。 */
export class UnavailableHuaweiQuickLogin implements HuaweiQuickLoginPort {
  prefetchAnonymousPhone(): Promise<QuickLoginPrefetch> {
    return Promise.resolve(QuickLoginPrefetch.failed(QuickLoginFallback.UNSUPPORTED));
  }

  setAgreement(_accepted: boolean): void {
  }

  continueLogin(): void {
  }

  listen(_onClick: () => Promise<void>, _onCredential: (result: QuickLoginCredential) => Promise<void>): void {
  }
}

/** 普通华为授权同样等 HM-14b，正式包不显示不可用按钮。 */
export class UnavailableHuaweiAdapter implements ThirdPartyAuthAdapter {
  readonly provider: string = OAuthProvider.HUAWEI;

  adapterAvailable(): boolean {
    return false;
  }

  installed(): boolean | null {
    return null;
  }

  authorize(_nonce: string): Promise<ThirdPartyAuthResult> {
    return Promise.resolve(ThirdPartyAuthResult.of(ThirdPartyAuthKind.UNAVAILABLE));
  }
}
