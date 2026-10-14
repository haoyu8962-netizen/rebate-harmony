// 二次验证（StepUpSheet）的共用依赖（APP-13a §2 第 7 项、§3 鸿蒙：从钱包 Feature 挪到共用位置）。
// 提现、收款账号（APP-09）与换手机号、申请注销（APP-13a）共用同一套执行器（StepUpController）与会话级共享服务：
// - 发码截止时间与在途占用（SmsResendClock，按账号 + 号码 + action 隔离，APP-09 第 6、17、26、27、40 条）；
// - 发码与验证各自的 42901 闸门（smsGate / verifyGate）；
// - 内存里的 step_up_token（StepUpTokenCache，APP-09 G17、APP-13a G23：按账号、会话归属与 action 隔离，不落盘）。
// 钱包（WalletDeps / WalletSession）与账号（AccountDeps / AccountSession）各自实现这里的接口；共享服务在 App 里只有一份
// （WalletSession 创建，AccountSession 引用同一份），换号成功后「丢弃全部 action 的 token」才能一次清干净（G04）。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { RetryAfterGate } from '../network/RetryAfterGate';
import { StepUpTokenCache } from '../wallet/WalletPresentation';
import { SmsResendClock } from '../wallet/WalletSession';

/** 二次验证面板只发两种请求（sendSmsCode、stepUp）。 */
export interface StepUpApiPort {
  request(request: ApiRequest): Promise<ApiResult>;
}

/** 会话级共享服务（App 一份）。epoch：会话世代（每次 reset 加 1；面板按打开时的世代核对）。 */
export interface StepUpSessionPort {
  readonly smsGate: RetryAfterGate;
  readonly verifyGate: RetryAfterGate;
  readonly sms: SmsResendClock;
  readonly tokens: StepUpTokenCache;
  epoch: number;
}

/**
 * 二次验证执行器的依赖。scope：会话归属键（含登录序号与会话世代；账号页另含会话作用域 full / deletion_only）；account：当前会话账号；
 * stepUpPhone：本机绑定了账号归属的规范化号码（APP-09 G31 / APP-13a G02：取不到为 null，不编造）；stepUpRestricted：当前是受限会话
 * （deletion_only）——只允许 account_deletion，其他 action 本地拒绝、不发请求（APP-13a §2 第 7 项）。
 */
export interface StepUpDeps {
  readonly api: StepUpApiPort;
  readonly session: StepUpSessionPort;
  clock: () => number;
  scope: () => string;
  account: () => string | null;
  stepUpPhone: (account: string) => string | null;
  forceUpdate: () => void;
  stepUpRestricted: () => boolean;
}

/** 二次验证的四个 action（enums/identity step_up_action）。 */
export class StepUpActions {
  static readonly WITHDRAW: string = 'withdraw';
  static readonly PAYOUT_ACCOUNT: string = 'payout_account';
  static readonly PHONE_CHANGE: string = 'phone_change';
  static readonly ACCOUNT_DELETION: string = 'account_deletion';

  /** 受限会话（deletion_only）下只接受 account_deletion（BR-ID-01 细则「受限会话」可调接口表）。 */
  static allowedIn(restricted: boolean, action: string): boolean {
    return !restricted || action === StepUpActions.ACCOUNT_DELETION;
  }
}

/** 会话级共享服务的一份实例（WalletSession 持有并对外交出；AccountSession 引用同一份）。 */
export class StepUpShared {
  readonly smsGate: RetryAfterGate;
  readonly verifyGate: RetryAfterGate;
  readonly sms: SmsResendClock;
  readonly tokens: StepUpTokenCache;

  constructor(smsGate: RetryAfterGate, verifyGate: RetryAfterGate, sms: SmsResendClock, tokens: StepUpTokenCache) {
    this.smsGate = smsGate;
    this.verifyGate = verifyGate;
    this.sms = sms;
    this.tokens = tokens;
  }

  /** 会话换代：清空截止时间、限流与全部 token（两边各自 reset 时都调，重复调用无害）。 */
  reset(): void {
    this.smsGate.reset();
    this.verifyGate.reset();
    this.sms.clear();
    this.tokens.onSessionChanged();
  }
}
