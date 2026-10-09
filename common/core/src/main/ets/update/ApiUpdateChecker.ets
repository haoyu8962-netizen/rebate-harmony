import { ApiClient, ApiRequest, ApiResult } from '../network/ApiClient';
import { UpdateCheckAdapter } from './UpdateCheckAdapter';
import { DEFAULT_RECHECK_INTERVAL_SEC, UpdateCheckOutcome, UpdateCheckResult, UpdateChecker } from './UpdateGate';

/**
 * 真实版本检查器（F-X-01，FU-HM-0709；Release 以及 Debug / Staging 不用调试假数据时）：经现有 ApiClient 发
 * GET /v1/app-versions/check（契约 operationId checkAppVersion：x-auth none、不签名、没有 query，平台与渠道由 ApiClient 的公共头
 * X-Platform / X-Channel 给出；x-error-codes 为空，只有公共码）。
 *
 * - 只在 allowed() 为真时发：App 接「环境闸门 SETTLED 且已同意当前隐私政策」（基本模式、首启未同意都不发，03 §4.4、BR-ID-11）。
 *   同一条件也作为 ApiRequest.sendAllowed，在每次实际发送前（含 GET 自动重试退避之后）再核对一次；网络层本身也在基本模式、
 *   未同意时本地拒绝 checkAppVersion（RequestHeaderPolicy 的基本模式白名单里没有它）。
 * - 复用在途：已有一次检查没结束时，再次 check() 返回同一个 Promise，不另发请求（03 §4.2；协调器层也不重复发）。
 * - 成功（code 0）→ data 交 UpdateCheckAdapter 投影成 UpdateCheckResult（字段以契约为准，不臆造）；recheck_interval_sec
 *   不在 check 响应里，用 recheckIntervalSec()（App 接 /v1/config.app_update，见 intervalFromConfig；缺省包内默认，rule-gaps G01）。
 * - 其余一律按失败（网络错误、业务错误、本地拒绝、被作废 / 取消、data 解析不出）：UpdateGate 按 unknown 处理，不误拦用户。
 * 不抛出。单线程（UI 线程）使用。
 */
export class ApiUpdateChecker implements UpdateChecker {
  static readonly OPERATION: string = 'checkAppVersion';

  private readonly client: () => ApiClient | null;
  private readonly allowed: () => boolean;
  private readonly recheckIntervalSec: () => number;
  private inFlight: Promise<UpdateCheckOutcome> | null = null;
  /** 实际交给 ApiClient 的检查次数（诊断与测试用）。 */
  private sentCount: number = 0;

  constructor(client: () => ApiClient | null, allowed: () => boolean,
    recheckIntervalSec: () => number = (): number => DEFAULT_RECHECK_INTERVAL_SEC) {
    this.client = client;
    this.allowed = allowed;
    this.recheckIntervalSec = recheckIntervalSec;
  }

  /**
   * /v1/config 生效配置（ConfigStore.snapshotJson）里的 app_update.recheck_interval_sec；没有、不是正数或解析不出时用包内默认
   * （rule-gaps G01）。
   */
  static intervalFromConfig(snapshotJson: string | null): number {
    if (snapshotJson === null) {
      return DEFAULT_RECHECK_INTERVAL_SEC;
    }
    try {
      const root: Record<string, Object> = JSON.parse(snapshotJson) as Record<string, Object>;
      const section: Object | undefined = root === null || typeof root !== 'object' ? undefined : root['app_update'];
      if (section === undefined || section === null || typeof section !== 'object') {
        return DEFAULT_RECHECK_INTERVAL_SEC;
      }
      const value: Object | undefined = (section as Record<string, Object>)['recheck_interval_sec'];
      if (typeof value !== 'number') {
        return DEFAULT_RECHECK_INTERVAL_SEC;
      }
      const seconds: number = value as number;
      return Number.isFinite(seconds) && seconds > 0 ? seconds : DEFAULT_RECHECK_INTERVAL_SEC;
    } catch (e) {
      return DEFAULT_RECHECK_INTERVAL_SEC;
    }
  }

  /** 有检查在途。 */
  get isRunning(): boolean {
    return this.inFlight !== null;
  }

  get requests(): number {
    return this.sentCount;
  }

  check(): Promise<UpdateCheckOutcome> {
    const running: Promise<UpdateCheckOutcome> | null = this.inFlight;
    if (running !== null) {
      return running;
    }
    if (!this.safeAllowed()) {
      return Promise.resolve(UpdateCheckOutcome.failure());
    }
    let client: ApiClient | null = null;
    try {
      client = this.client();
    } catch (e) {
      client = null;
    }
    if (client === null) {
      return Promise.resolve(UpdateCheckOutcome.failure());
    }
    this.sentCount++;
    const promise: Promise<UpdateCheckOutcome> = this.run(client).then((outcome: UpdateCheckOutcome) => {
      this.inFlight = null;
      return outcome;
    });
    this.inFlight = promise;
    return promise;
  }

  private safeAllowed(): boolean {
    try {
      return this.allowed();
    } catch (e) {
      return false;
    }
  }

  /**
   * 判定要用的契约必填字段齐全（AppVersionCheck.required）：latest_version 是字符串，min_supported_version / recommended_version
   * 存在（字符串或 null），stores 是数组。缺了按检查失败（unknown），不把残缺响应当成「不低于」。
   */
  static wellFormed(data: Record<string, Object>): boolean {
    if (data === null || typeof data !== 'object' || typeof data['latest_version'] !== 'string'
      || !Array.isArray(data['stores'])) {
      return false;
    }
    for (const key of ['min_supported_version', 'recommended_version']) {
      if (!Object.keys(data).includes(key)) {
        return false;
      }
      const value: Object | null | undefined = data[key];
      if (value !== null && value !== undefined && typeof value !== 'string') {
        return false;
      }
    }
    return true;
  }

  private async run(client: ApiClient): Promise<UpdateCheckOutcome> {
    const request: ApiRequest = new ApiRequest(ApiUpdateChecker.OPERATION);
    request.sendAllowed = (): boolean => this.safeAllowed();
    try {
      const result: ApiResult = await client.request(request);
      if (!result.ok || !ApiUpdateChecker.wellFormed(result.data)) {
        return UpdateCheckOutcome.failure();
      }
      let interval: number = DEFAULT_RECHECK_INTERVAL_SEC;
      try {
        const value: number = this.recheckIntervalSec();
        interval = Number.isFinite(value) && value > 0 ? value : DEFAULT_RECHECK_INTERVAL_SEC;
      } catch (e) {
        interval = DEFAULT_RECHECK_INTERVAL_SEC;
      }
      const parsed: UpdateCheckResult | null = UpdateCheckAdapter.fromJson(JSON.stringify(result.data), interval);
      return parsed === null ? UpdateCheckOutcome.failure() : UpdateCheckOutcome.success(parsed);
    } catch (e) {
      // ApiClient 不抛出；万一抛出按失败（unknown）。
      return UpdateCheckOutcome.failure();
    }
  }
}
