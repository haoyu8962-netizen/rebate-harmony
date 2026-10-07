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
    return registry.cleanOnly(PrivacyWithdrawalCleaners.NAMES);
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
