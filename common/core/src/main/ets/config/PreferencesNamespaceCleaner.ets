import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LocalDataCleaner } from './LocalDataCleaner';

/** 本 App 自己的 Preferences 文件名（命名空间）。 */
export class CouliPreferences {
  /**
   * 业务数据命名空间；别的模块新增 Preferences 文件时登记进 ALL_NAMESPACES，清理时一并删除。
   * 已用的键：router.pending_action（PreferencesPendingBackend，APP-02a）。
   */
  static readonly APP_NAMESPACE: string = 'couli_app';
  static readonly ALL_NAMESPACES: string[] = [CouliPreferences.APP_NAMESPACE];
  /**
   * 环境记录（上次生效的环境、调试面板的选择）专用命名空间。不在 ALL_NAMESPACES 里，
   * PreferencesNamespaceCleaner 也会主动跳过它：清理期间不能丢掉这些记录。
   */
  static readonly ENVIRONMENT_RECORD_NAMESPACE: string = 'couli_environment_record';
  /**
   * 本机隐私决定（APP-02b，PreferencesPrivacyStore）专用命名空间：决定、同意时的政策版本、同意的点击时间、是否基本模式。
   * 它记的是「这台设备上的用户对包内隐私政策点了什么」，不属于任何服务器环境：03 §3.6 切换环境要清的是
   * 令牌、device_id、install_secret、LKG、页面缓存、pending_action，不含隐私决定；切换环境后不重弹首启弹窗。
   * 所以它不在 ALL_NAMESPACES 里，PreferencesNamespaceCleaner 也主动跳过（环境切换、覆盖安装对账都不会误删）。
   * 撤回同意（BR-ID-13）不删除这里：清的是令牌、device_id、install_secret（PrivacyWithdrawalCleaners），
   * 然后把这里的决定改写为 basic_mode——删掉反而会让下次冷启动当成「从未决定」重弹首启弹窗。
   */
  static readonly PRIVACY_DECISION_NAMESPACE: string = 'couli_privacy_decision';
  /**
   * 撤回同意的「撤回意图」标记（APP-02b R1-01，两阶段写入的第一阶段）：与本机隐私决定分开的独立小文件，
   * 先于决定记录落盘；任一阶段中断或写入失败，冷启动读到它都强制按基本模式、凭据不可读、重试清理。
   * 与本机隐私决定同理不属于任何服务器环境，环境切换与覆盖安装对账都不删；只在撤回清理全部成功后由 PrivacyGate 改回 false。
   */
  static readonly PRIVACY_WITHDRAWAL_INTENT_NAMESPACE: string = 'couli_privacy_withdrawal_intent';
  /** 任何清理器都不删除的命名空间。 */
  static readonly PRESERVED_NAMESPACES: string[] = [CouliPreferences.ENVIRONMENT_RECORD_NAMESPACE,
    CouliPreferences.PRIVACY_DECISION_NAMESPACE, CouliPreferences.PRIVACY_WITHDRAWAL_INTENT_NAMESPACE];
}

/** 删除本 App 的 Preferences 命名空间（文件与内存缓存一起删）；永远不删环境记录、本机隐私决定与撤回意图命名空间。 */
export class PreferencesNamespaceCleaner implements LocalDataCleaner {
  readonly name: string = 'preferences';
  private readonly context: common.Context;
  readonly namespaces: string[];

  constructor(context: common.Context, namespaces: string[] = CouliPreferences.ALL_NAMESPACES) {
    this.context = context;
    this.namespaces = PreferencesNamespaceCleaner.deletable(namespaces);
  }

  /** 去掉环境记录、本机隐私决定与撤回意图命名空间（即使调用方误传进来）。 */
  static deletable(namespaces: string[]): string[] {
    return namespaces.filter((n: string) => CouliPreferences.PRESERVED_NAMESPACES.indexOf(n) < 0);
  }

  /** 删除失败时抛出，由 LocalDataCleanerRegistry.cleanAll 记为失败。 */
  async clean(): Promise<void> {
    for (const namespace of this.namespaces) {
      await preferences.deletePreferences(this.context, namespace);
    }
  }
}
