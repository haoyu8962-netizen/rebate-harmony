import { AppEnvironment, EnvironmentEndpoints, EnvironmentSource } from './AppEnvironment';
import { EnvironmentRecord } from './EnvironmentRecord';
import { EnvironmentLaunchReconciler, LaunchOutcome, LaunchReport } from './EnvironmentLaunchReconciler';
import { LocalDataCleanerRegistry } from './LocalDataCleaner';
import { EnvironmentSwitchGate } from './EnvironmentSwitchGate';
import { EnvironmentCatalog } from 'core/ets/config/EnvironmentCatalog';

/**
 * 启动环境闸门（X-01，三端统一口径）。
 * - PENDING：启动对账还没跑完。
 * - SETTLED：对账成功（首次记录 / 未变 / 清理并记录），环境已装入，可以读会话与缓存、进入正常首屏。
 * - BLOCKED：对账自动重试一次后仍失败（清理失败或写记录失败）。不装入环境：拿不到 endpoints，
 *   不得读取任何会话或缓存，RootPage 只显示阻断页与【重试】。
 * 除 SETTLED 外，AppConfig.environment() / endpoints() 都返回 undefined。
 */
export enum EnvironmentGate {
  PENDING = 'pending',
  SETTLED = 'settled',
  BLOCKED = 'blocked'
}

/** 按构建取环境目录（Debug / Staging 为 src/staging，Release 为 src/release）。单测可注入替身。 */
export interface EnvironmentCatalogPort {
  launchEnvironment(buildDefault: AppEnvironment, record: EnvironmentRecord): Promise<AppEnvironment>;

  createSource(environment: AppEnvironment, record: EnvironmentRecord,
    cleaners: LocalDataCleanerRegistry): EnvironmentSource;
}

/** 本构建编译进来的 EnvironmentCatalog。 */
export class BuildEnvironmentCatalog implements EnvironmentCatalogPort {
  launchEnvironment(buildDefault: AppEnvironment, record: EnvironmentRecord): Promise<AppEnvironment> {
    return EnvironmentCatalog.launchEnvironment(buildDefault, record);
  }

  createSource(environment: AppEnvironment, record: EnvironmentRecord,
    cleaners: LocalDataCleanerRegistry): EnvironmentSource {
    return EnvironmentCatalog.createSource(environment, record, cleaners);
  }
}

/**
 * 启动顺序：定本次环境（构建默认或调试面板的持久化选择）→ 启动对账；
 * 对账成功才装入环境（SETTLED）；失败先自动重试一次，仍失败进入 BLOCKED，等用户点【重试】再跑一次对账。
 * 不会抛出。
 */
export class EnvironmentBootstrap {
  private readonly catalog: EnvironmentCatalogPort;
  private state: EnvironmentGate = EnvironmentGate.PENDING;
  private source: EnvironmentSource | null = null;
  private report: LaunchReport | null = null;
  private attemptCount: number = 0;
  private buildDefault: AppEnvironment = AppEnvironment.PROD;
  private record: EnvironmentRecord | null = null;
  private cleaners: LocalDataCleanerRegistry | null = null;
  private running: Promise<EnvironmentGate> | null = null;

  constructor(catalog: EnvironmentCatalogPort = new BuildEnvironmentCatalog()) {
    this.catalog = catalog;
  }

  get gate(): EnvironmentGate {
    return this.state;
  }

  /** 最近一次对账结果。 */
  get launchReport(): LaunchReport | null {
    return this.report;
  }

  /** 已跑过的对账次数（含自动重试与手动重试）。 */
  get attempts(): number {
    return this.attemptCount;
  }

  /** 只有 SETTLED 才有当前环境。 */
  environment(): EnvironmentSource | undefined {
    if (this.state !== EnvironmentGate.SETTLED || this.source === null) {
      return undefined;
    }
    return this.source;
  }

  endpoints(): EnvironmentEndpoints | undefined {
    const source: EnvironmentSource | undefined = this.environment();
    return source === undefined ? undefined : source.endpoints;
  }

  /** 启动时调用一次（再次调用返回当前状态）：对账，失败自动重试一次。 */
  start(buildDefault: AppEnvironment, record: EnvironmentRecord,
    cleaners: LocalDataCleanerRegistry): Promise<EnvironmentGate> {
    if (this.record !== null) {
      return this.running !== null ? this.running : Promise.resolve(this.state);
    }
    this.buildDefault = buildDefault;
    this.record = record;
    this.cleaners = cleaners;
    return this.serialize(2);
  }

  /** 阻断页的【重试】：只在 BLOCKED 时重跑一次对账；成功后装入环境并转为 SETTLED。 */
  retry(): Promise<EnvironmentGate> {
    if (this.running !== null) {
      return this.running;
    }
    if (this.state !== EnvironmentGate.BLOCKED) {
      return Promise.resolve(this.state);
    }
    return this.serialize(1);
  }

  private serialize(maxAttempts: number): Promise<EnvironmentGate> {
    const run: Promise<EnvironmentGate> = this.attempt(maxAttempts).then((gate: EnvironmentGate) => {
      this.running = null;
      return gate;
    });
    this.running = run;
    return run;
  }

  private async attempt(maxAttempts: number): Promise<EnvironmentGate> {
    const record: EnvironmentRecord = this.record as EnvironmentRecord;
    const cleaners: LocalDataCleanerRegistry = this.cleaners as LocalDataCleanerRegistry;
    for (let i = 0; i < maxAttempts; i++) {
      this.attemptCount++;
      let target: AppEnvironment = this.buildDefault;
      let report: LaunchReport;
      try {
        target = await this.catalog.launchEnvironment(this.buildDefault, record);
        report = await EnvironmentLaunchReconciler.reconcile(target, record, cleaners);
      } catch (e) {
        report = new LaunchReport(LaunchOutcome.CLEAN_FAILED, undefined, target, null);
      }
      this.report = report;
      if (report.settled) {
        try {
          this.source = this.catalog.createSource(target, record, cleaners);
          this.state = EnvironmentGate.SETTLED;
          return this.state;
        } catch (e) {
          this.source = null;
        }
      }
    }
    this.state = EnvironmentGate.BLOCKED;
    return this.state;
  }
}

/**
 * 进程内唯一的环境配置（只读）。EntryAbility 启动时调 AppConfig.start 一次；阻断页的【重试】调 AppConfig.retry。
 * 环境只在 SETTLED 后可读：之前或 BLOCKED 时 environment() / endpoints() 都是 undefined（没有 prod 兜底）。
 * Debug / Staging 装入的实现可在调试面板切换（入口在 src/staging）；Release 装入的是固定 prod。
 */
export class AppConfig {
  static readonly cleaners: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
  private static readonly bootstrap: EnvironmentBootstrap = new EnvironmentBootstrap();

  static start(buildDefault: AppEnvironment, record: EnvironmentRecord): Promise<EnvironmentGate> {
    return AppConfig.bootstrap.start(buildDefault, record, AppConfig.cleaners);
  }

  static retry(): Promise<EnvironmentGate> {
    return AppConfig.bootstrap.retry();
  }

  /** 只读的闸门状态；会话层等读取本机数据前必须确认是 SETTLED（TODO(HM-02)）。 */
  static gate(): EnvironmentGate {
    return AppConfig.bootstrap.gate;
  }

  /** 当前环境（只读）；非 SETTLED 时为 undefined。 */
  static environment(): EnvironmentSource | undefined {
    return AppConfig.bootstrap.environment();
  }

  /**
   * 当前地址；非 SETTLED、或运行中切换环境（EnvironmentSwitchGate 关闭：清理与提交期间，R1-01）时为 undefined——
   * 网络层据此在本地拒绝一切请求（含设备注册），不会向旧环境发出。
   */
  static endpoints(): EnvironmentEndpoints | undefined {
    if (!EnvironmentSwitchGate.shared.open) {
      return undefined;
    }
    return AppConfig.bootstrap.endpoints();
  }

  /** 最近一次启动对账结果。 */
  static launchReport(): LaunchReport | null {
    return AppConfig.bootstrap.launchReport;
  }
}
