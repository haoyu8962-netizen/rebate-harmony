// 运行中切换服务器环境（只在 Debug / Staging 编译；Release 产物里没有本文件，release-scan 检查）。
import { AppEnvironment, EnvironmentEndpoints, EnvironmentSource } from '../../../main/ets/config/AppEnvironment';
import { EnvironmentRecord, EnvironmentRecordKeys } from '../../../main/ets/config/EnvironmentRecord';
import { CleanReport, LocalDataCleanerRegistry } from '../../../main/ets/config/LocalDataCleaner';

/** 调试面板选择的环境（跨重启持久化）。键名是 release-scan 的标记之一：Release 产物里不得出现。 */
export class EnvironmentSelection {
  static readonly KEY: string = 'couli.debug.environment_selection';

  /** 读持久化的选择；没有、读不出来或不在本构建的地址表里都返回 undefined。 */
  static async read(record: EnvironmentRecord, table: Map<AppEnvironment, EnvironmentEndpoints>):
    Promise<AppEnvironment | undefined> {
    try {
      const raw: string | undefined = await record.get(EnvironmentSelection.KEY);
      if (raw === undefined) {
        return undefined;
      }
      for (const env of Array.from(table.keys())) {
        if (env === raw) {
          return env;
        }
      }
      return undefined;
    } catch (e) {
      return undefined;
    }
  }
}

export enum SwitchOutcome {
  SWITCHED = 'switched',
  UNCHANGED = 'unchanged',
  /** 目标环境不在本构建的地址表里。 */
  NOT_AVAILABLE = 'not_available',
  /** 上一次切换还没结束。 */
  BUSY = 'busy',
  /** 有清理器失败：内存环境与选择都不变，LAST_EFFECTIVE 留为 UNSETTLED_MARK，可重试。 */
  CLEAN_FAILED = 'clean_failed',
  /** 选择或 LAST_EFFECTIVE 写不进去：内存环境不变、选择回滚，可重试。 */
  RECORD_FAILED = 'record_failed'
}

export class SwitchResult {
  readonly outcome: SwitchOutcome;
  readonly report: CleanReport | null;

  constructor(outcome: SwitchOutcome, report: CleanReport | null) {
    this.outcome = outcome;
    this.report = report;
  }
}

/**
 * Debug / Staging 的当前环境：只读部分实现 EnvironmentSource，另有 switchTo。
 * 切换顺序（R2-02）：
 *   1. 读当前选择（回滚用）；读不出 → RECORD_FAILED，什么都不动。
 *   2. LAST_EFFECTIVE 写为 UNSETTLED_MARK（切换开始的持久化标记）；写不进 → RECORD_FAILED，什么都不动。
 *   3. 全部清理器；有失败 → CLEAN_FAILED。
 *   4. 写选择 = 目标；5. 写 LAST_EFFECTIVE = 目标。4 或 5 失败 → 选择回滚为第 1 步读到的值 → RECORD_FAILED。
 *   6. 两项都写成功后才切内存里的当前环境，返回 SWITCHED。
 * 3–5 任一步失败：内存环境不变、选择回滚；LAST_EFFECTIVE 留在 UNSETTLED_MARK，
 * 它与任何构建的本次环境都不同，于是之后不论 Debug 重启还是覆盖安装 Staging / Release，启动对账都会先清理再记录。
 * 回滚本身失败也只会让下次启动多清一次，不会跳过清理。
 */
export class EnvironmentSwitcher implements EnvironmentSource {
  readonly cleaners: LocalDataCleanerRegistry;
  private readonly table: Map<AppEnvironment, EnvironmentEndpoints>;
  private readonly record: EnvironmentRecord;
  private currentEnvironment: AppEnvironment;
  private switching: boolean = false;

  constructor(initial: AppEnvironment, table: Map<AppEnvironment, EnvironmentEndpoints>,
    cleaners: LocalDataCleanerRegistry, record: EnvironmentRecord) {
    if (table.size === 0) {
      throw new Error('EnvironmentSwitcher: empty endpoint table');
    }
    this.table = table;
    this.cleaners = cleaners;
    this.record = record;
    this.currentEnvironment = table.has(initial) ? initial : Array.from(table.keys())[0];
  }

  get current(): AppEnvironment {
    return this.currentEnvironment;
  }

  get endpoints(): EnvironmentEndpoints {
    return this.table.get(this.currentEnvironment) as EnvironmentEndpoints;
  }

  available(): AppEnvironment[] {
    return Array.from(this.table.keys());
  }

  canSwitch(): boolean {
    return this.table.size > 1;
  }

  async switchTo(target: AppEnvironment): Promise<SwitchResult> {
    if (!this.table.has(target)) {
      return new SwitchResult(SwitchOutcome.NOT_AVAILABLE, null);
    }
    if (target === this.currentEnvironment) {
      return new SwitchResult(SwitchOutcome.UNCHANGED, null);
    }
    if (this.switching) {
      return new SwitchResult(SwitchOutcome.BUSY, null);
    }
    this.switching = true;
    try {
      let previousSelection: string | undefined = undefined;
      try {
        previousSelection = await this.record.get(EnvironmentSelection.KEY);
        await this.record.put(EnvironmentRecordKeys.LAST_EFFECTIVE, EnvironmentRecordKeys.UNSETTLED_MARK);
      } catch (e) {
        return new SwitchResult(SwitchOutcome.RECORD_FAILED, null);
      }
      const report: CleanReport = await this.cleaners.cleanAll();
      if (!report.ok) {
        return new SwitchResult(SwitchOutcome.CLEAN_FAILED, report);
      }
      try {
        await this.record.put(EnvironmentSelection.KEY, target);
        await this.record.put(EnvironmentRecordKeys.LAST_EFFECTIVE, target);
      } catch (e) {
        await this.restoreSelection(previousSelection);
        return new SwitchResult(SwitchOutcome.RECORD_FAILED, report);
      }
      this.currentEnvironment = target;
      return new SwitchResult(SwitchOutcome.SWITCHED, report);
    } finally {
      this.switching = false;
    }
  }

  /** 把选择恢复成切换前的值（原来没有就删掉）。失败只记不抛：LAST_EFFECTIVE 已不是任何环境名，下次启动会强制清理。 */
  private async restoreSelection(previous: string | undefined): Promise<void> {
    try {
      if (previous === undefined) {
        await this.record.remove(EnvironmentSelection.KEY);
      } else {
        await this.record.put(EnvironmentSelection.KEY, previous);
      }
    } catch (e) {
      // 见方法注释。
    }
  }
}
