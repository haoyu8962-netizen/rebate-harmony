import { AppEnvironment } from './AppEnvironment';
import { EnvironmentRecord, EnvironmentRecordKeys } from './EnvironmentRecord';
import { CleanReport, LocalDataCleanerRegistry } from './LocalDataCleaner';

export enum LaunchOutcome {
  /** 没有「上次生效的环境」记录（首次安装）：只记录，不清理。 */
  FIRST_LAUNCH = 'first_launch',
  /** 与上次相同：什么都不做。 */
  UNCHANGED = 'unchanged',
  /** 与上次不同（如 Debug 覆盖安装 Staging）：全部清理器成功后已记录新环境。 */
  CLEANED = 'cleaned',
  /** 有清理器失败：不记录新环境；未 settled（自动重试一次后仍失败则启动阻断）。 */
  CLEAN_FAILED = 'clean_failed',
  /** 清理成功（或首次）但写记录失败：未 settled，同上处理（首次安装记录写不进去也必须阻断，否则以后覆盖安装会被当成首次而跳过清理）。 */
  RECORD_FAILED = 'record_failed'
}

export class LaunchReport {
  readonly outcome: LaunchOutcome;
  /** 上次生效的环境原值（没有记录为 undefined；读不出来为 'unreadable'）。 */
  readonly previous: string | undefined;
  readonly target: AppEnvironment;
  readonly clean: CleanReport | null;

  constructor(outcome: LaunchOutcome, previous: string | undefined, target: AppEnvironment, clean: CleanReport | null) {
    this.outcome = outcome;
    this.previous = previous;
    this.target = target;
    this.clean = clean;
  }

  /** 本机是否已确认没有别的环境的残留。 */
  get settled(): boolean {
    return this.outcome !== LaunchOutcome.CLEAN_FAILED && this.outcome !== LaunchOutcome.RECORD_FAILED;
  }
}

/**
 * 启动对账（X-01）：Debug 与 Staging（以及同签名的 Release）同 bundleName、可互相覆盖安装，
 * 覆盖后本次要用的环境可能与上次生效的不同，旧会话与缓存不能带过去。
 *
 * - 记录不存在（首次安装）→ 只记录本次环境，不清理。
 * - 与本次相同 → 不动。
 * - 不同或读不出来（含调试面板留下的 UNSETTLED_MARK）→ 先跑全部清理器；全部成功才写入本次环境；有失败则不写。
 * - 结果不是 settled 时由 EnvironmentBootstrap 自动重试一次，仍失败则 BLOCKED（不装入环境、显示阻断页）。
 *
 * 记录放在 ENVIRONMENT_RECORD_NAMESPACE，清理器不会删它；调试面板的选择也在那里，清理期间不丢。
 * 本类只对账「本次构建决定要用的环境」，不提供任何改变环境的入口（三套配置都编译）。
 */
export class EnvironmentLaunchReconciler {
  static async reconcile(target: AppEnvironment, record: EnvironmentRecord,
    cleaners: LocalDataCleanerRegistry): Promise<LaunchReport> {
    let previous: string | undefined = undefined;
    let readable: boolean = true;
    try {
      previous = await record.get(EnvironmentRecordKeys.LAST_EFFECTIVE);
    } catch (e) {
      readable = false;
      previous = 'unreadable';
    }

    if (readable && previous === undefined) {
      const firstOk: boolean = await EnvironmentLaunchReconciler.write(record, target);
      return new LaunchReport(firstOk ? LaunchOutcome.FIRST_LAUNCH : LaunchOutcome.RECORD_FAILED, previous, target, null);
    }
    if (readable && previous === target) {
      return new LaunchReport(LaunchOutcome.UNCHANGED, previous, target, null);
    }

    const report: CleanReport = await cleaners.cleanAll();
    if (!report.ok) {
      return new LaunchReport(LaunchOutcome.CLEAN_FAILED, previous, target, report);
    }
    const ok: boolean = await EnvironmentLaunchReconciler.write(record, target);
    return new LaunchReport(ok ? LaunchOutcome.CLEANED : LaunchOutcome.RECORD_FAILED, previous, target, report);
  }

  private static async write(record: EnvironmentRecord, target: AppEnvironment): Promise<boolean> {
    try {
      await record.put(EnvironmentRecordKeys.LAST_EFFECTIVE, target);
      return true;
    } catch (e) {
      return false;
    }
  }
}
