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

/** 每次清理开始时最先同步执行的一步（如作废并取消在途网络请求）。 */
class BeforeClearHook {
  readonly name: string;
  readonly run: () => void;

  constructor(name: string, run: () => void) {
    this.name = name;
    this.run = run;
  }
}

export class LocalDataCleanerRegistry {
  private cleaners: LocalDataCleaner[] = [];
  private hooks: BeforeClearHook[] = [];
  private withdrawalHooks: BeforeClearHook[] = [];

  /** 只随撤回同意清除的本机偏好，环境切换 cleanAll 不执行（G24）。同名替换。 */
  setOnWithdrawal(name: string, run: () => void): void {
    const hook: BeforeClearHook = new BeforeClearHook(name, run);
    const index: number = this.withdrawalHooks.findIndex((h: BeforeClearHook): boolean => h.name === name);
    if (index < 0) {
      this.withdrawalHooks.push(hook);
    } else {
      this.withdrawalHooks[index] = hook;
    }
  }

  /** 由撤回入口同步执行；失败纳入撤回报告，保留撤回痕迹以便冷启动重试。 */
  runWithdrawalHooks(): CleanReport {
    const cleaned: string[] = [];
    const failed: string[] = [];
    for (const hook of this.withdrawalHooks.slice()) {
      try {
        hook.run();
        cleaned.push(hook.name);
      } catch (e) {
        failed.push(hook.name);
      }
    }
    return new CleanReport(cleaned, failed);
  }

  /**
   * 登记「清理前第一步」（同名替换）：cleanAll（切换环境、覆盖安装对账）与 cleanOnly（撤回同意）开始时、在任何清理器
   * 之前同步执行，不受名字筛选影响。用于网络层作废并取消在途请求（ApiClient.invalidate，lessons 35）：先让旧请求、
   * 重试与刷新结果全部失效，再删令牌与设备身份，晚到的响应不能把会话写回来。抛异常记为失败，其余照常清理。
   */
  setBeforeClear(name: string, run: () => void): void {
    const hook: BeforeClearHook = new BeforeClearHook(name, run);
    const index: number = this.hooks.findIndex((h: BeforeClearHook) => h.name === name);
    if (index >= 0) {
      this.hooks[index] = hook;
    } else {
      this.hooks.push(hook);
    }
  }

  /** 已登记的「清理前第一步」名字（按执行顺序）。 */
  beforeClearNames(): string[] {
    return this.hooks.map((h: BeforeClearHook) => h.name);
  }

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

  has(name: string): boolean {
    return this.cleaners.some((c: LocalDataCleaner) => c.name === name);
  }

  async cleanAll(): Promise<CleanReport> {
    return this.run(this.cleaners.slice());
  }

  /**
   * 只跑指定名字的清理器（按注册顺序；没注册的名字记为失败，不能当成清干净了）。
   * 撤回隐私同意用它：只清令牌、device_id、install_secret（BR-ID-13），不删其他本机数据。
   */
  async cleanOnly(names: string[]): Promise<CleanReport> {
    const report: CleanReport = await this.run(this.cleaners.filter((c: LocalDataCleaner) => names.indexOf(c.name) >= 0));
    const missing: string[] = names.filter((n: string) => !this.has(n));
    return new CleanReport(report.cleaned, report.failed.concat(missing));
  }

  private async run(cleaners: LocalDataCleaner[]): Promise<CleanReport> {
    const cleaned: string[] = [];
    const failed: string[] = [];
    // 第一步（同步、在任何 await 之前）：清理前钩子。
    for (const hook of this.hooks.slice()) {
      try {
        hook.run();
        cleaned.push(hook.name);
      } catch (e) {
        failed.push(hook.name);
      }
    }
    for (const cleaner of cleaners) {
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
