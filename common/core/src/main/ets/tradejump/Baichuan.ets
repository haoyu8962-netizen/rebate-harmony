/**
 * 外跳：联盟 SDK 适配层（03 §3.1、§4.5；BR-ATTR-27 淘宝行；鸿蒙走百川 HarmonyOS SDK，规划/09 CAP-X-04）。执行器与 apps.json
 * 判定在 core/trade（APP-06b）。
 *
 * 百川（淘宝）SDK 本任务不引入（任务书 §2.3、§3）：这里只有接口与「不可用」实现。AppKey、回跳 scheme 负责人未给，用
 * BAICHUAN_APP_KEY_PLACEHOLDER 占位（TODO(N-28)，rule-gaps）。
 */

/** 百川打开结果。 */
export class BaichuanOpenResult {
  /** 已拉起淘宝（或百川内的商品页）。 */
  static readonly LAUNCHED: string = 'launched';
  /** 已初始化但拉起失败（含电商 SDK 未开通）。 */
  static readonly FAILED: string = 'failed';
  /** 初始化失败（重试 1 次后仍失败），与 FAILED 分开上报 sdk_init_failed（BR-ATTR-27 淘宝行）。 */
  static readonly INIT_FAILED: string = 'init_failed';
}

/** 百川授权结果（sdk_token，BR-ID-17 细则「授权方式」）。令牌只交给 bindings，不落库、不进日志。 */
export class BaichuanAuthResult {
  static readonly TOKEN: string = 'token';
  static readonly CANCELLED: string = 'cancelled';
  static readonly FAILED: string = 'failed';
  readonly kind: string;
  readonly accessToken: string;
  readonly expiresIn: number;

  constructor(kind: string, accessToken: string = '', expiresIn: number = 0) {
    this.kind = kind;
    this.accessToken = accessToken;
    this.expiresIn = expiresIn;
  }
}

/** 百川 AppKey 占位：负责人还没有提供（TODO(N-28)，任务书 §0「不臆造」）。 */
export const BAICHUAN_APP_KEY_PLACEHOLDER: string = 'TODO_N28_BAICHUAN_APP_KEY';

/**
 * 百川适配层（BR-ATTR-27 淘宝行、03 §4.5）：
 * - initialize 只由 PrivacyGate.onConsented 的「联盟」步骤调用（BR-ID-11，硬规则 5）；失败时记下；
 * - 下一次执行淘宝 sdk 步骤之前 retryInitIfFailed 重试初始化 1 次，仍失败就跳过 sdk 步骤、按 fallbacks 继续；
 * - open 原样交出服务端下发的 sdk 步骤 value，不改不补参数（BR-ATTR-05）。
 */
export interface BaichuanAdapter {
  /** SDK 当前可用（已初始化成功）。 */
  isReady(): boolean;

  /** 同意隐私政策后初始化（只在 PrivacyGate.onConsented 里调）。返回是否成功。 */
  initialize(): boolean;

  /** 初始化曾失败时重试 1 次（下一次执行 sdk 步骤之前）；返回重试后是否可用。没失败过不重试，按当前结论返回。 */
  retryInitIfFailed(): boolean;

  /** 执行 sdk 步骤（value 原样）；BaichuanOpenResult 取值。 */
  open(value: string): Promise<string>;

  /** 能否执行 sdk_token 授权（AuthMethodPicker 的本端能力）。 */
  supportsSdkToken(): boolean;

  /** sdk_token 授权（等到 SDK 回调）。 */
  authorize(): Promise<BaichuanAuthResult>;
}

/**
 * 不可用实现（生产与本任务的唯一实现）：没有 SDK、没有 AppKey，初始化一律失败；sdk 步骤报 INIT_FAILED，执行器据此跳过 sdk 步骤、
 * 按下发的 fallbacks 继续，没有后续步骤时提示 jump.taobao_sdk_unavailable、不外跳（BR-ATTR-27）。sdk_token 授权不可用。
 */
export class UnavailableBaichuan implements BaichuanAdapter {
  /** 占位：接入 SDK 时用（TODO(N-28)）。 */
  readonly appKey: string;
  private initFailed: boolean = false;
  /** 初始化尝试次数（同意后 1 次 + 每次 sdk 步骤前的重试），只用于观察。 */
  initAttempts: number = 0;

  constructor(appKey: string = BAICHUAN_APP_KEY_PLACEHOLDER) {
    this.appKey = appKey;
  }

  isReady(): boolean {
    return false;
  }

  initialize(): boolean {
    this.initAttempts++;
    this.initFailed = true;
    return false;
  }

  retryInitIfFailed(): boolean {
    if (!this.initFailed) {
      return false;
    }
    this.initAttempts++;
    return false;
  }

  open(_value: string): Promise<string> {
    return Promise.resolve(BaichuanOpenResult.INIT_FAILED);
  }

  supportsSdkToken(): boolean {
    return false;
  }

  authorize(): Promise<BaichuanAuthResult> {
    return Promise.resolve(new BaichuanAuthResult(BaichuanAuthResult.FAILED));
  }
}
