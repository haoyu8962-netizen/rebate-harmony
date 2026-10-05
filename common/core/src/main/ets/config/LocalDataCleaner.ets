/**
 * 本机数据清理注册表（03 §3.6「切换环境：先清除本机的会话与缓存」）。
 *
 * 放在 src/main 是因为 Release 也要用：启动时发现「上次生效的环境」与本次不同（同 bundleName 覆盖安装）要清；
 * 以后撤回隐私同意、退出登录也复用同一批清理器。本文件只有「注册 / 全部清理」，没有任何切换环境的入口——
 * 运行中切换环境的实现（EnvironmentSwitcher）只在 src/staging，Release 不编译。
 *
 * 本任务会话与缓存还不存在；先有 Preferences 命名空间清理，Asset（令牌）、LKG、页面缓存、pending_action
 * 等由各自模块以后注册进来（TODO(HM-02)）。
 */
export interface LocalDataCleaner {
  /** 唯一名字；重复注册同名清理器时后者替换前者。 */
  readonly name: string;

  clean(): Promise<void>;
}

/** 一次清理的结果：按注册顺序执行，单个失败不影响其余继续执行。 */
export class CleanReport {
  readonly cleaned: string[];
  readonly failed: string[];

  constructor(cleaned: string[], failed: string[]) {
    this.cleaned = cleaned;
    this.failed = failed;
  }

  get ok(): boolean {
    return this.failed.length === 0;
  }
}

export class LocalDataCleanerRegistry {
  private cleaners: LocalDataCleaner[] = [];

  register(cleaner: LocalDataCleaner): void {
    const index: number = this.cleaners.findIndex((c: LocalDataCleaner) => c.name === cleaner.name);
    if (index >= 0) {
      this.cleaners[index] = cleaner;
    } else {
      this.cleaners.push(cleaner);
    }
  }

  unregister(name: string): void {
    this.cleaners = this.cleaners.filter((c: LocalDataCleaner) => c.name !== name);
  }

  names(): string[] {
    return this.cleaners.map((c: LocalDataCleaner) => c.name);
  }

  async cleanAll(): Promise<CleanReport> {
    const cleaned: string[] = [];
    const failed: string[] = [];
    for (const cleaner of this.cleaners.slice()) {
      try {
        await cleaner.clean();
        cleaned.push(cleaner.name);
      } catch (e) {
        failed.push(cleaner.name);
      }
    }
    return new CleanReport(cleaned, failed);
  }
}
