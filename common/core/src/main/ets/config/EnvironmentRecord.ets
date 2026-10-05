import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { CouliPreferences } from './PreferencesNamespaceCleaner';

/**
 * 环境记录的键值存储。键只在 CouliPreferences.ENVIRONMENT_RECORD_NAMESPACE 里，清理器不会删。
 * 读失败抛出（调用方区分「没有记录」与「读不出来」）；写、删失败抛出（每次写删都落盘）。
 */
export interface EnvironmentRecord {
  get(key: string): Promise<string | undefined>;

  put(key: string, value: string): Promise<void>;

  remove(key: string): Promise<void>;
}

export class EnvironmentRecordKeys {
  /** 上次全部清理成功后生效的环境（启动对账用，三套配置都有）。 */
  static readonly LAST_EFFECTIVE: string = 'last_effective_environment';
  /**
   * 写进 LAST_EFFECTIVE 的「切换未完成」标记（不是任何环境名）。调试面板切换在清理前先写它，
   * 切换没有完整提交时就留着：之后任何构建启动都看到「上次 ≠ 本次」，强制清理后再记录（R2-02）。
   */
  static readonly UNSETTLED_MARK: string = 'unsettled_switch';
}

/** 用 Preferences 实现的环境记录。 */
export class PreferencesEnvironmentRecord implements EnvironmentRecord {
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private async open(): Promise<preferences.Preferences> {
    return preferences.getPreferences(this.context, CouliPreferences.ENVIRONMENT_RECORD_NAMESPACE);
  }

  async get(key: string): Promise<string | undefined> {
    const store: preferences.Preferences = await this.open();
    const value: preferences.ValueType = await store.get(key, '');
    if (typeof value === 'string' && value.length > 0) {
      return value;
    }
    return undefined;
  }

  async put(key: string, value: string): Promise<void> {
    const store: preferences.Preferences = await this.open();
    await store.put(key, value);
    await store.flush();
  }

  async remove(key: string): Promise<void> {
    const store: preferences.Preferences = await this.open();
    await store.delete(key);
    await store.flush();
  }
}
