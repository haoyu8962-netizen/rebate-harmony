import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { CouliPreferences } from '../config/PreferencesNamespaceCleaner';
import { LastLoginMethodBackend } from './LastLoginMethod';

/** 独立的本机偏好文件，不放进随环境删除的命名空间；撤回通过 Store 的专用钩子清键。 */
export class PreferencesLastLoginMethodBackend implements LastLoginMethodBackend {
  private static readonly KEY: string = 'last_method';
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private prefs(): preferences.Preferences {
    return preferences.getPreferencesSync(this.context, { name: CouliPreferences.LAST_LOGIN_METHOD_NAMESPACE });
  }

  read(): string | null {
    try {
      const value: preferences.ValueType = this.prefs().getSync(PreferencesLastLoginMethodBackend.KEY, '');
      return typeof value === 'string' && value.length > 0 ? value : null;
    } catch (e) {
      return null;
    }
  }

  write(method: string | null): boolean {
    try {
      const prefs: preferences.Preferences = this.prefs();
      if (method === null) {
        prefs.deleteSync(PreferencesLastLoginMethodBackend.KEY);
      } else {
        prefs.putSync(PreferencesLastLoginMethodBackend.KEY, method);
      }
      prefs.flushSync();
      return true;
    } catch (e) {
      return false;
    }
  }
}
