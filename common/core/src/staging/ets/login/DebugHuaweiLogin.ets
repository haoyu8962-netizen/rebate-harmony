// 仅 core staging：entry 转发本实现，Release 源码集没有任何场景、假号码和假凭证。
import {
  HuaweiQuickLoginPort, QuickLoginCredential, QuickLoginCredentialKind, QuickLoginFallback, QuickLoginPrefetch
} from '../../../main/ets/login/HuaweiQuickLoginPort';
import { OAuthProvider } from '../../../main/ets/login/OAuthLoginFlow';
import { ThirdPartyAuthAdapter, ThirdPartyAuthKind, ThirdPartyAuthResult } from '../../../main/ets/login/OAuthLoginService';

export class DebugHuaweiQuickLoginScene {
  static readonly PHONE: string = 'phone';
  static readonly NOT_LOGGED_IN: string = '1001502001';
  static readonly NO_PERMISSION: string = '1001502014';
  static readonly AGREEMENT_NOT_ACCEPTED: string = '1005300001';
  static readonly USER_CANCEL: string = '1001502012';
  static readonly NETWORK_ERROR: string = 'network_error';
  static readonly LAUNCH_KEY: string = 'couli_debug_huawei_scene';
  static readonly MARKER: string = 'COULI_FAKE_HUAWEI_HM14A_8c2f31';
  static current: string = DebugHuaweiQuickLoginScene.PHONE;
}

export class DebugHuaweiQuickLogin implements HuaweiQuickLoginPort {
  private readonly scene: () => string;
  private accepted: boolean = false;
  private serial: number = 0;
  private onClick: () => Promise<void> = (): Promise<void> => Promise.resolve();
  private onCredential: (result: QuickLoginCredential) => Promise<void> =
    (_result: QuickLoginCredential): Promise<void> => Promise.resolve();

  constructor(scene: () => string) {
    this.scene = scene;
  }

  prefetchAnonymousPhone(): Promise<QuickLoginPrefetch> {
    const scene: string = this.scene();
    if (scene === DebugHuaweiQuickLoginScene.NOT_LOGGED_IN) {
      return Promise.resolve(QuickLoginPrefetch.failed(QuickLoginFallback.NOT_LOGGED_IN));
    }
    if (scene === DebugHuaweiQuickLoginScene.NO_PERMISSION) {
      return Promise.resolve(QuickLoginPrefetch.failed(QuickLoginFallback.NO_PERMISSION));
    }
    return Promise.resolve(QuickLoginPrefetch.phone('138****8000'));
  }

  setAgreement(accepted: boolean): void {
    this.accepted = accepted;
  }

  listen(onClick: () => Promise<void>, onCredential: (result: QuickLoginCredential) => Promise<void>): void {
    this.onClick = onClick;
    this.onCredential = onCredential;
  }

  /** 点击事件先派发；结果无需等待授权尝试回包，模拟系统组件两条独立回调。 */
  async tap(): Promise<void> {
    const clicked: Promise<void> = this.onClick();
    const delivered: Promise<void> = this.onCredential(this.accepted ? this.result() :
      QuickLoginCredential.of(QuickLoginCredentialKind.AGREEMENT_NOT_ACCEPTED));
    await Promise.all([clicked, delivered]);
  }

  continueLogin(): void {
    if (this.accepted) {
      this.onCredential(this.result()).catch((): void => {
      });
    }
  }

  private result(): QuickLoginCredential {
    const scene: string = this.scene();
    if (scene === DebugHuaweiQuickLoginScene.USER_CANCEL) {
      return QuickLoginCredential.of(QuickLoginCredentialKind.CANCELLED);
    }
    if (scene === DebugHuaweiQuickLoginScene.NETWORK_ERROR) {
      return QuickLoginCredential.of(QuickLoginCredentialKind.NETWORK_ERROR);
    }
    if (scene === DebugHuaweiQuickLoginScene.NO_PERMISSION || scene === DebugHuaweiQuickLoginScene.NOT_LOGGED_IN) {
      return QuickLoginCredential.of(QuickLoginCredentialKind.ERROR);
    }
    this.serial++;
    return QuickLoginCredential.code('debug-stub-huawei-one-tap-' + this.serial);
  }
}

export class DebugHuaweiAuthAdapter implements ThirdPartyAuthAdapter {
  readonly provider: string = OAuthProvider.HUAWEI;
  private serial: number = 0;

  adapterAvailable(): boolean {
    return true;
  }

  installed(): boolean | null {
    return true;
  }

  authorize(_nonce: string): Promise<ThirdPartyAuthResult> {
    this.serial++;
    return Promise.resolve(new ThirdPartyAuthResult(ThirdPartyAuthKind.CREDENTIAL, null, null, null,
      'debug-stub-huawei-' + this.serial));
  }
}

/** 每次调用与结果交付都重新核对环境；切到 prod 后旧实例也不能继续发假凭证。 */
export class GatedHuaweiQuickLogin implements HuaweiQuickLoginPort {
  private readonly fake: DebugHuaweiQuickLogin;
  private readonly gate: () => boolean;

  constructor(fake: DebugHuaweiQuickLogin, gate: () => boolean) {
    this.fake = fake;
    this.gate = gate;
  }

  async prefetchAnonymousPhone(): Promise<QuickLoginPrefetch> {
    if (!this.gate()) {
      return QuickLoginPrefetch.failed(QuickLoginFallback.UNSUPPORTED);
    }
    const result: QuickLoginPrefetch = await this.fake.prefetchAnonymousPhone();
    return this.gate() ? result : QuickLoginPrefetch.failed(QuickLoginFallback.UNSUPPORTED);
  }

  setAgreement(accepted: boolean): void {
    this.fake.setAgreement(this.gate() && accepted);
  }

  continueLogin(): void {
    if (this.gate()) {
      this.fake.continueLogin();
    }
  }

  tap(): Promise<void> {
    return this.gate() ? this.fake.tap() : Promise.resolve();
  }

  listen(onClick: () => Promise<void>, onCredential: (result: QuickLoginCredential) => Promise<void>): void {
    this.fake.listen((): Promise<void> => this.gate() ? onClick() : Promise.resolve(),
      (result: QuickLoginCredential): Promise<void> => this.gate() ? onCredential(result) : Promise.resolve());
  }
}
