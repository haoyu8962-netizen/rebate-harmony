import { CleanReport, LocalDataCleaner, LocalDataCleanerRegistry } from '../config/LocalDataCleaner';

/**
 * 撤回同意要清的本机凭据（BR-ID-13：令牌、device_id、install_secret）。会话与设备注册还没有实现，
 * 先在 APP-01 的清理器注册表里放同名占位清理项；以后的真实实现用同名 register 替换占位（注册表同名替换）。
 * 这些清理项同时也属于 03 §3.6「切换环境先清会话与设备身份」，所以注册进同一个 AppConfig.cleaners：
 * 环境切换的 cleanAll 会一并跑到它们；撤回同意只跑这几项（cleanOnly），不动环境记录与本机隐私决定。
 */
export class PrivacyWithdrawalCleaners {
  /** access_token、refresh_token、h5_token。TODO(APP-05)：会话层接入后注册同名真实清理器。 */
  static readonly SESSION_TOKENS: string = 'session_tokens';
  /** device_id 与 install_secret。TODO(APP-03)：设备注册接入后注册同名真实清理器。 */
  static readonly DEVICE_IDENTITY: string = 'device_identity';
  /**
   * 埋点离线队列（APP-03b，R1-06）：撤回同意必须清空（03 §4.7、BR-ID-11）。登记在撤回清理名单里，删不掉时撤回清理不算完成、
   * 撤回痕迹保留并在冷启动重试；真实清理项由 App 组合处同名替换占位（TrackerQueueCleaner）。
   */
  static readonly TRACKER_QUEUE: string = 'tracker_queue';
  static readonly NAMES: string[] = [PrivacyWithdrawalCleaners.SESSION_TOKENS, PrivacyWithdrawalCleaners.DEVICE_IDENTITY,
    PrivacyWithdrawalCleaners.TRACKER_QUEUE];

  /** 没有真实实现时注册占位（已注册的同名清理器不覆盖）。 */
  static registerPlaceholders(registry: LocalDataCleanerRegistry): void {
    for (const name of PrivacyWithdrawalCleaners.NAMES) {
      if (!registry.has(name)) {
        registry.register(new PlaceholderCleaner(name));
      }
    }
  }

  /** 撤回同意时调用：只跑令牌、设备身份与埋点队列的清理项。 */
  static run(registry: LocalDataCleanerRegistry): Promise<CleanReport> {
    // cleanOnly 同步启动作废在途请求，再清撤回专用偏好；两类失败都阻止标记清理完成。
    const common: Promise<CleanReport> = registry.cleanOnly(PrivacyWithdrawalCleaners.NAMES);
    const preferences: CleanReport = registry.runWithdrawalHooks();
    return common.then((report: CleanReport): CleanReport =>
      new CleanReport(report.cleaned.concat(preferences.cleaned), report.failed.concat(preferences.failed)));
  }
}

/** 占位清理项：什么都没存，所以什么都不用清。 */
export class PlaceholderCleaner implements LocalDataCleaner {
  readonly name: string;

  constructor(name: string) {
    this.name = name;
  }

  clean(): Promise<void> {
    return Promise.resolve();
  }
}

/**
 * 撤回同意清理的一次运行与结果交付（F-X-08 ①，FU-HM-0719）。PrivacyGate.withdrawalCleanup 的生产实现：
 * - 跑撤回清理名单（PrivacyWithdrawalCleaners.run：清理前第一步 + 令牌、设备身份、埋点队列；各模块的本机偏好 / 草稿删除登记在清理前第一步里，
 *   删除没确认落盘就抛错 → 本次报告失败）；全部成功 → onDone（PrivacyGate.withdrawalCleanupDone 清撤回痕迹）。
 * - 失败 → 撤回痕迹保留（冷启动、回前台、【重试】再跑；痕迹在时凭据不可读，各本机存储读前先补删）。
 * - 由用户操作（【确认撤回】、失败提示的【重试】）同步发起的这一次失败，交 onFailed 当场提示并给【重试】；冷启动 / 回前台的自动重试
 *   再失败不另弹框（保守、不打扰：基本模式照常、凭据禁读）。
 */
export class WithdrawalCleanupRun {
  private readonly registry: LocalDataCleanerRegistry;
  /** interactive() 执行期间同步发起的那一次清理按「当场」交付失败。 */
  private interactiveNext: boolean = false;
  /** 清理全部成功。 */
  onDone: (report: CleanReport) => void = (_r: CleanReport) => {
  };
  /** 用户操作发起的清理失败（当场提示 + 【重试】）。 */
  onFailed: (report: CleanReport) => void = (_r: CleanReport) => {
  };
  /** 每次结果（日志用；ok 与失败项名字，不含数据）。 */
  onSettled: (report: CleanReport, interactive: boolean) => void = (_r: CleanReport, _i: boolean) => {
  };

  constructor(registry: LocalDataCleanerRegistry) {
    this.registry = registry;
  }

  /** PrivacyGate.withdrawalCleanup：发起一次清理（清理前第一步同步执行完才返回）。 */
  run(): Promise<CleanReport> {
    const interactive: boolean = this.interactiveNext;
    this.interactiveNext = false;
    return PrivacyWithdrawalCleaners.run(this.registry).then((report: CleanReport): CleanReport => {
      try {
        this.onSettled(report, interactive);
      } catch (e) {
        // 日志出错不影响结果交付。
      }
      if (report.ok) {
        this.onDone(report);
      } else if (interactive) {
        this.onFailed(report);
      }
      return report;
    });
  }

  /** 用户操作：action 同步执行期间发起的清理（PrivacyGate.withdraw / retryPendingWithdrawalCleanup 里同步调 run）失败时当场交付。 */
  interactive<T>(action: () => T): T {
    this.interactiveNext = true;
    try {
      return action();
    } finally {
      this.interactiveNext = false;
    }
  }
}
