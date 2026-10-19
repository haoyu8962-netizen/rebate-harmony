import { LocalDataCleanerRegistry } from '../config/LocalDataCleaner';

export interface LastLoginMethodBackend {
  read(): string | null;
  write(method: string | null): boolean;
}

/** 本机只存方式枚举，不存号码；退出与环境切换保留，撤回同意清除（G05/G22/G24）。 */
export class LastLoginMethodStore {
  static readonly SMS: string = 'sms';
  static readonly HUAWEI_ONE_TAP: string = 'huawei_one_tap';
  static readonly HUAWEI: string = 'huawei';
  static readonly WECHAT: string = 'wechat';
  private readonly backend: LastLoginMethodBackend;
  private version: number = 0;

  constructor(backend: LastLoginMethodBackend) {
    this.backend = backend;
  }

  private static valid(method: string): boolean {
    return method === LastLoginMethodStore.SMS || method === LastLoginMethodStore.HUAWEI_ONE_TAP
      || method === LastLoginMethodStore.HUAWEI || method === LastLoginMethodStore.WECHAT;
  }

  read(): string | null {
    try {
      const value: string | null = this.backend.read();
      return value !== null && LastLoginMethodStore.valid(value) ? value : null;
    } catch (e) {
      return null;
    }
  }

  /** 跨异步登录过程捕获；清理或更新后，旧登录的迟到结果不能重新写入。 */
  get revision(): number {
    return this.version;
  }

  record(method: string, revision: number = this.version): void {
    if (revision === this.version && LastLoginMethodStore.valid(method)) {
      this.version++;
      try {
        this.backend.write(method);
      } catch (e) {
        // 偏好写失败不能把已保存的登录会话变成失败。
      }
    }
  }

  clear(): void {
    this.version++;
    if (!this.backend.write(null)) {
      throw new Error('last login method clear failed');
    }
  }

  installCleaner(registry: LocalDataCleanerRegistry): void {
    registry.setOnWithdrawal('last_login_method', (): void => this.clear());
  }
}
