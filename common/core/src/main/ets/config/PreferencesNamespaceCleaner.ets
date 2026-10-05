import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LocalDataCleaner } from './LocalDataCleaner';

/** 本 App 自己的 Preferences 文件名（命名空间）。 */
export class CouliPreferences {
  /** 业务数据命名空间；别的模块新增 Preferences 文件时登记进 ALL_NAMESPACES，清理时一并删除。 */
  static readonly APP_NAMESPACE: string = 'couli_app';
  static readonly ALL_NAMESPACES: string[] = [CouliPreferences.APP_NAMESPACE];
  /**
   * 环境记录（上次生效的环境、调试面板的选择）专用命名空间。不在 ALL_NAMESPACES 里，
   * PreferencesNamespaceCleaner 也会主动跳过它：清理期间不能丢掉这些记录。
   */
  static readonly ENVIRONMENT_RECORD_NAMESPACE: string = 'couli_environment_record';
}

/** 删除本 App 的 Preferences 命名空间（文件与内存缓存一起删）；永远不删环境记录命名空间。 */
export class PreferencesNamespaceCleaner implements LocalDataCleaner {
  readonly name: string = 'preferences';
  private readonly context: common.Context;
  readonly namespaces: string[];

  constructor(context: common.Context, namespaces: string[] = CouliPreferences.ALL_NAMESPACES) {
    this.context = context;
    this.namespaces = PreferencesNamespaceCleaner.deletable(namespaces);
  }

  /** 去掉环境记录命名空间（即使调用方误传进来）。 */
  static deletable(namespaces: string[]): string[] {
    return namespaces.filter((n: string) => n !== CouliPreferences.ENVIRONMENT_RECORD_NAMESPACE);
  }

  /** 删除失败时抛出，由 LocalDataCleanerRegistry.cleanAll 记为失败。 */
  async clean(): Promise<void> {
    for (const namespace of this.namespaces) {
      await preferences.deletePreferences(this.context, namespace);
    }
  }
}
