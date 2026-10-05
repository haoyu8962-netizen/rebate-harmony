import { describe, it, expect } from '@ohos/hypium';
import {
  AppEnvironment,
  CleanReport,
  EnvironmentBootstrap,
  EnvironmentCatalogPort,
  EnvironmentGate,
  CouliPreferences,
  EnvironmentEndpoints,
  EnvironmentLaunchReconciler,
  EnvironmentRecord,
  EnvironmentRecordKeys,
  EnvironmentSource,
  ENVIRONMENT_SWITCH_COMPILED,
  LaunchOutcome,
  LaunchReport,
  LocalDataCleaner,
  LocalDataCleanerRegistry,
  PreferencesNamespaceCleaner,
  PROD_ENDPOINTS
} from '../../Index';
// 本机单测按 default target 编译（Index 导出的是 src/release 的替身），
// Debug / Staging 才编译的实现直接按相对路径引入来测。
import { EnvironmentCatalog as ReleaseCatalog } from '../release/ets/config/EnvironmentCatalog';
import { EnvironmentCatalog as StagingCatalog } from '../staging/ets/config/EnvironmentCatalog';
import {
  EnvironmentSelection,
  EnvironmentSwitcher,
  SwitchOutcome,
  SwitchResult
} from '../staging/ets/config/EnvironmentSwitcher';
import { DebugCapabilities, DebugCapability } from '../staging/ets/config/DebugCapabilities';

/** 内存里的环境记录；可让读或写失败。 */
class MemoryRecord implements EnvironmentRecord {
  readonly values: Map<string, string> = new Map<string, string>();
  failGet: boolean = false;
  failPutKey: string = '';
  /** 形如 'key=value'：只有写这个值时失败（模拟「前几次写成功、关键一次写失败」）。 */
  failPutEntry: string = '';
  failRemove: boolean = false;

  async get(key: string): Promise<string | undefined> {
    if (this.failGet) {
      throw new Error('get failed');
    }
    return this.values.get(key);
  }

  async put(key: string, value: string): Promise<void> {
    if (this.failPutKey === key || this.failPutKey === '*' || this.failPutEntry === key + '=' + value) {
      throw new Error('put failed: ' + key);
    }
    this.values.set(key, value);
  }

  async remove(key: string): Promise<void> {
    if (this.failRemove) {
      throw new Error('remove failed: ' + key);
    }
    this.values.delete(key);
  }
}

/** 单测用的 Debug / Staging 环境目录（本机单测按 default target 编译，BuildEnvironmentCatalog 是 Release 版）。 */
class StagingCatalogPort implements EnvironmentCatalogPort {
  launchEnvironment(buildDefault: AppEnvironment, record: EnvironmentRecord): Promise<AppEnvironment> {
    return StagingCatalog.launchEnvironment(buildDefault, record);
  }

  createSource(environment: AppEnvironment, record: EnvironmentRecord,
    cleaners: LocalDataCleanerRegistry): EnvironmentSource {
    return StagingCatalog.createSource(environment, record, cleaners);
  }
}

class RecordingCleaner implements LocalDataCleaner {
  readonly name: string;
  private readonly log: string[];
  fail: boolean;

  constructor(name: string, log: string[], fail: boolean = false) {
    this.name = name;
    this.log = log;
    this.fail = fail;
  }

  async clean(): Promise<void> {
    this.log.push(this.name);
    if (this.fail) {
      throw new Error('clean failed: ' + this.name);
    }
  }
}

/** 第一次清理失败、之后成功。 */
class FlakyCleaner implements LocalDataCleaner {
  readonly name: string = 'flaky';
  private readonly log: string[];
  private calls: number = 0;

  constructor(log: string[]) {
    this.log = log;
  }

  async clean(): Promise<void> {
    this.calls++;
    if (this.calls === 1) {
      this.log.push('flaky:fail');
      throw new Error('first clean fails');
    }
    this.log.push('flaky:ok');
  }
}

/** 清理时顺带记下此刻环境记录里的值，用来证明清理期间记录还在。 */
class SnapshotCleaner implements LocalDataCleaner {
  readonly name: string = 'snapshot';
  private readonly record: MemoryRecord;
  seen: string = '';

  constructor(record: MemoryRecord) {
    this.record = record;
  }

  async clean(): Promise<void> {
    const selection: string | undefined = this.record.values.get(EnvironmentSelection.KEY);
    const last: string | undefined = this.record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE);
    this.seen = (selection === undefined ? '-' : selection) + '/' + (last === undefined ? '-' : last);
  }
}

function fourEnvironments(): Map<AppEnvironment, EnvironmentEndpoints> {
  // 单测自造的地址表（与产物无关），模拟 Debug / Staging 构建可切换的四个环境。
  const map: Map<AppEnvironment, EnvironmentEndpoints> = new Map<AppEnvironment, EnvironmentEndpoints>();
  map.set(AppEnvironment.LOCAL, new EnvironmentEndpoints('https://api.local.unit.invalid', 'https://h5.local.unit.invalid'));
  map.set(AppEnvironment.TEST, new EnvironmentEndpoints('https://api.test.unit.invalid', 'https://h5.test.unit.invalid'));
  map.set(AppEnvironment.STAGING, new EnvironmentEndpoints('https://api.staging.unit.invalid', 'https://h5.staging.unit.invalid'));
  map.set(AppEnvironment.PROD, PROD_ENDPOINTS);
  return map;
}

function prodOnly(): Map<AppEnvironment, EnvironmentEndpoints> {
  const map: Map<AppEnvironment, EnvironmentEndpoints> = new Map<AppEnvironment, EnvironmentEndpoints>();
  map.set(AppEnvironment.PROD, PROD_ENDPOINTS);
  return map;
}

function registryWith(cleaner: LocalDataCleaner): LocalDataCleanerRegistry {
  const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
  registry.register(cleaner);
  return registry;
}

export default function environmentConfigTest() {
  describe('LocalDataCleanerRegistry', () => {
    it('runs_cleaners_in_registration_order', 0, async () => {
      const log: string[] = [];
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      registry.register(new RecordingCleaner('preferences', log));
      registry.register(new RecordingCleaner('asset', log));
      const report: CleanReport = await registry.cleanAll();
      expect(log.join(',')).assertEqual('preferences,asset');
      expect(report.cleaned.join(',')).assertEqual('preferences,asset');
      expect(report.ok).assertTrue();
    });

    it('same_name_replaces_and_unregister_removes', 0, async () => {
      const log: string[] = [];
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      registry.register(new RecordingCleaner('a', log, true));
      registry.register(new RecordingCleaner('b', log));
      registry.register(new RecordingCleaner('a', log));
      expect(registry.names().join(',')).assertEqual('a,b');
      registry.unregister('b');
      expect(registry.names().join(',')).assertEqual('a');
      const report: CleanReport = await registry.cleanAll();
      expect(report.ok).assertTrue();
    });

    it('a_failing_cleaner_does_not_stop_the_others', 0, async () => {
      const log: string[] = [];
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      registry.register(new RecordingCleaner('first', log, true));
      registry.register(new RecordingCleaner('second', log));
      const report: CleanReport = await registry.cleanAll();
      expect(log.join(',')).assertEqual('first,second');
      expect(report.failed.join(',')).assertEqual('first');
      expect(report.cleaned.join(',')).assertEqual('second');
      expect(report.ok).assertFalse();
    });

    it('namespace_cleaner_never_deletes_the_environment_record', 0, () => {
      const record: string = CouliPreferences.ENVIRONMENT_RECORD_NAMESPACE;
      expect(CouliPreferences.ALL_NAMESPACES.indexOf(record)).assertEqual(-1);
      const kept: string[] = PreferencesNamespaceCleaner.deletable([CouliPreferences.APP_NAMESPACE, record]);
      expect(kept.join(',')).assertEqual(CouliPreferences.APP_NAMESPACE);
    });
  });

  describe('EnvironmentLaunchReconciler', () => {
    it('first_install_records_without_cleaning', 0, async () => {
      const log: string[] = [];
      const record: MemoryRecord = new MemoryRecord();
      const report: LaunchReport =
        await EnvironmentLaunchReconciler.reconcile(AppEnvironment.TEST, record, registryWith(new RecordingCleaner('p', log)));
      expect(report.outcome).assertEqual(LaunchOutcome.FIRST_LAUNCH);
      expect(log.length).assertEqual(0);
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('test');
      expect(report.settled).assertTrue();
    });

    it('same_environment_does_nothing', 0, async () => {
      const log: string[] = [];
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'staging');
      const report: LaunchReport =
        await EnvironmentLaunchReconciler.reconcile(AppEnvironment.STAGING, record, registryWith(new RecordingCleaner('p', log)));
      expect(report.outcome).assertEqual(LaunchOutcome.UNCHANGED);
      expect(log.length).assertEqual(0);
    });

    it('different_environment_cleans_then_records', 0, async () => {
      const log: string[] = [];
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      const report: LaunchReport =
        await EnvironmentLaunchReconciler.reconcile(AppEnvironment.PROD, record, registryWith(new RecordingCleaner('p', log)));
      expect(report.outcome).assertEqual(LaunchOutcome.CLEANED);
      expect(report.previous).assertEqual('test');
      expect(log.join(',')).assertEqual('p');
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('prod');
    });

    it('clean_failure_does_not_record_and_the_next_launch_retries', 0, async () => {
      const log: string[] = [];
      const cleaner: RecordingCleaner = new RecordingCleaner('p', log, true);
      const registry: LocalDataCleanerRegistry = registryWith(cleaner);
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      const first: LaunchReport = await EnvironmentLaunchReconciler.reconcile(AppEnvironment.STAGING, record, registry);
      expect(first.outcome).assertEqual(LaunchOutcome.CLEAN_FAILED);
      expect(first.settled).assertFalse();
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('test');
      cleaner.fail = false;
      const second: LaunchReport = await EnvironmentLaunchReconciler.reconcile(AppEnvironment.STAGING, record, registry);
      expect(second.outcome).assertEqual(LaunchOutcome.CLEANED);
      expect(log.join(',')).assertEqual('p,p');
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('staging');
    });

    it('unreadable_record_cleans_before_recording', 0, async () => {
      const log: string[] = [];
      const record: MemoryRecord = new MemoryRecord();
      record.failGet = true;
      const report: LaunchReport =
        await EnvironmentLaunchReconciler.reconcile(AppEnvironment.PROD, record, registryWith(new RecordingCleaner('p', log)));
      expect(report.outcome).assertEqual(LaunchOutcome.CLEANED);
      expect(log.join(',')).assertEqual('p');
    });

    it('record_write_failure_is_reported_as_unsettled', 0, async () => {
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      record.failPutKey = '*';
      const report: LaunchReport =
        await EnvironmentLaunchReconciler.reconcile(AppEnvironment.STAGING, record, registryWith(new RecordingCleaner('p', [])));
      expect(report.outcome).assertEqual(LaunchOutcome.RECORD_FAILED);
      expect(report.settled).assertFalse();
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('test');
    });

    it('cleaning_keeps_the_environment_record_and_selection', 0, async () => {
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      record.values.set(EnvironmentSelection.KEY, 'local');
      const cleaner: SnapshotCleaner = new SnapshotCleaner(record);
      const report: LaunchReport = await EnvironmentLaunchReconciler.reconcile(AppEnvironment.LOCAL, record, registryWith(cleaner));
      expect(report.outcome).assertEqual(LaunchOutcome.CLEANED);
      expect(cleaner.seen).assertEqual('local/test');
      expect(record.values.get(EnvironmentSelection.KEY)).assertEqual('local');
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('local');
    });

    it('debug_install_then_staging_overwrite_cleans_old_session', 0, async () => {
      // X-01：Debug 首次运行（默认 test，从未手动切换）→ 覆盖安装 Staging（默认 staging）。
      const log: string[] = [];
      const registry: LocalDataCleanerRegistry = registryWith(new RecordingCleaner('session', log));
      const record: MemoryRecord = new MemoryRecord();
      const debugEnv: AppEnvironment = await StagingCatalog.launchEnvironment(AppEnvironment.TEST, record);
      const debugLaunch: LaunchReport = await EnvironmentLaunchReconciler.reconcile(debugEnv, record, registry);
      expect(debugLaunch.outcome).assertEqual(LaunchOutcome.FIRST_LAUNCH);
      expect(log.length).assertEqual(0);
      const stagingEnv: AppEnvironment = await StagingCatalog.launchEnvironment(AppEnvironment.STAGING, record);
      expect(stagingEnv).assertEqual(AppEnvironment.STAGING);
      const stagingLaunch: LaunchReport = await EnvironmentLaunchReconciler.reconcile(stagingEnv, record, registry);
      expect(stagingLaunch.outcome).assertEqual(LaunchOutcome.CLEANED);
      expect(log.join(',')).assertEqual('session');
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('staging');
    });

    it('staging_install_then_release_overwrite_cleans_old_session', 0, async () => {
      const log: string[] = [];
      const registry: LocalDataCleanerRegistry = registryWith(new RecordingCleaner('session', log));
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'staging');
      record.values.set(EnvironmentSelection.KEY, 'staging');
      const releaseEnv: AppEnvironment = await ReleaseCatalog.launchEnvironment(AppEnvironment.PROD, record);
      expect(releaseEnv).assertEqual(AppEnvironment.PROD);
      const report: LaunchReport = await EnvironmentLaunchReconciler.reconcile(releaseEnv, record, registry);
      expect(report.outcome).assertEqual(LaunchOutcome.CLEANED);
      expect(log.join(',')).assertEqual('session');
    });
  });

  describe('EnvironmentBootstrap', () => {
    it('clean_failure_retries_once_then_blocks_without_endpoints', 0, async () => {
      // R2-01 复现：上次 test，覆盖安装 Release，清理器一直失败。
      const log: string[] = [];
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      const bootstrap: EnvironmentBootstrap = new EnvironmentBootstrap();
      expect(bootstrap.gate).assertEqual(EnvironmentGate.PENDING);
      expect(bootstrap.environment() === undefined).assertTrue();
      const gate: EnvironmentGate =
        await bootstrap.start(AppEnvironment.PROD, record, registryWith(new RecordingCleaner('p', log, true)));
      expect(gate).assertEqual(EnvironmentGate.BLOCKED);
      expect(bootstrap.gate).assertEqual(EnvironmentGate.BLOCKED);
      expect(bootstrap.attempts).assertEqual(2);
      expect(log.join(',')).assertEqual('p,p');
      expect(bootstrap.environment() === undefined).assertTrue();
      expect(bootstrap.endpoints() === undefined).assertTrue();
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('test');
      const report: LaunchReport | null = bootstrap.launchReport;
      expect(report !== null && report.outcome === LaunchOutcome.CLEAN_FAILED).assertTrue();
    });

    it('blocked_retry_failure_keeps_record_and_stays_blocked', 0, async () => {
      const log: string[] = [];
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      const bootstrap: EnvironmentBootstrap = new EnvironmentBootstrap();
      const registry: LocalDataCleanerRegistry = registryWith(new RecordingCleaner('p', log, true));
      await bootstrap.start(AppEnvironment.PROD, record, registry);
      const gate: EnvironmentGate = await bootstrap.retry();
      expect(gate).assertEqual(EnvironmentGate.BLOCKED);
      expect(bootstrap.attempts).assertEqual(3);
      expect(log.join(',')).assertEqual('p,p,p');
      expect(bootstrap.endpoints() === undefined).assertTrue();
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('test');
    });

    it('blocked_retry_success_settles_installs_and_records', 0, async () => {
      const log: string[] = [];
      const cleaner: RecordingCleaner = new RecordingCleaner('p', log, true);
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      const bootstrap: EnvironmentBootstrap = new EnvironmentBootstrap();
      expect(await bootstrap.start(AppEnvironment.PROD, record, registryWith(cleaner))).assertEqual(EnvironmentGate.BLOCKED);
      cleaner.fail = false;
      const gate: EnvironmentGate = await bootstrap.retry();
      expect(gate).assertEqual(EnvironmentGate.SETTLED);
      expect(bootstrap.gate).assertEqual(EnvironmentGate.SETTLED);
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('prod');
      const endpoints: EnvironmentEndpoints | undefined = bootstrap.endpoints();
      expect(endpoints !== undefined && endpoints.apiBase === PROD_ENDPOINTS.apiBase).assertTrue();
      const source: EnvironmentSource | undefined = bootstrap.environment();
      expect(source !== undefined && source.current === AppEnvironment.PROD).assertTrue();
      // SETTLED 后再点重试不再清理。
      expect(await bootstrap.retry()).assertEqual(EnvironmentGate.SETTLED);
      expect(log.join(',')).assertEqual('p,p,p');
    });

    it('automatic_retry_succeeds_on_the_second_attempt', 0, async () => {
      // 第一次清理失败、第二次成功（注册两个清理器：第一个只失败一次）。
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'staging');
      const log: string[] = [];
      const flaky: FlakyCleaner = new FlakyCleaner(log);
      const bootstrap: EnvironmentBootstrap = new EnvironmentBootstrap(new StagingCatalogPort());
      const gate: EnvironmentGate = await bootstrap.start(AppEnvironment.TEST, record, registryWith(flaky));
      expect(gate).assertEqual(EnvironmentGate.SETTLED);
      expect(bootstrap.attempts).assertEqual(2);
      expect(log.join(',')).assertEqual('flaky:fail,flaky:ok');
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('test');
      const source: EnvironmentSource | undefined = bootstrap.environment();
      expect(source instanceof EnvironmentSwitcher).assertTrue();
      expect(source !== undefined && source.current === AppEnvironment.TEST).assertTrue();
    });

    it('record_write_failure_also_blocks', 0, async () => {
      // 首次安装但记录写不进去：放行的话以后覆盖安装会被当成首次而跳过清理，所以同样阻断。
      const record: MemoryRecord = new MemoryRecord();
      record.failPutKey = '*';
      const bootstrap: EnvironmentBootstrap = new EnvironmentBootstrap();
      const gate: EnvironmentGate =
        await bootstrap.start(AppEnvironment.PROD, record, registryWith(new RecordingCleaner('p', [])));
      expect(gate).assertEqual(EnvironmentGate.BLOCKED);
      expect(bootstrap.endpoints() === undefined).assertTrue();
      expect(record.values.has(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertFalse();
      record.failPutKey = '';
      expect(await bootstrap.retry()).assertEqual(EnvironmentGate.SETTLED);
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('prod');
    });

    it('unchanged_launch_settles_immediately', 0, async () => {
      const log: string[] = [];
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'prod');
      const bootstrap: EnvironmentBootstrap = new EnvironmentBootstrap();
      const gate: EnvironmentGate =
        await bootstrap.start(AppEnvironment.PROD, record, registryWith(new RecordingCleaner('p', log)));
      expect(gate).assertEqual(EnvironmentGate.SETTLED);
      expect(bootstrap.attempts).assertEqual(1);
      expect(log.length).assertEqual(0);
    });
  });

  describe('EnvironmentCatalog', () => {
    it('release_catalog_is_prod_only_and_ignores_selection', 0, async () => {
      expect(ENVIRONMENT_SWITCH_COMPILED).assertFalse();
      const keys: AppEnvironment[] = Array.from(ReleaseCatalog.endpoints().keys());
      expect(keys.join(',')).assertEqual('prod');
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentSelection.KEY, 'test');
      expect(await ReleaseCatalog.launchEnvironment(AppEnvironment.TEST, record)).assertEqual(AppEnvironment.PROD);
      const source: EnvironmentSource = ReleaseCatalog.createSource(AppEnvironment.TEST, record, new LocalDataCleanerRegistry());
      expect(source.current).assertEqual(AppEnvironment.PROD);
      expect(source instanceof EnvironmentSwitcher).assertFalse();
    });

    it('staging_catalog_prefers_a_valid_persisted_selection', 0, async () => {
      const record: MemoryRecord = new MemoryRecord();
      expect(await StagingCatalog.launchEnvironment(AppEnvironment.TEST, record)).assertEqual(AppEnvironment.TEST);
      record.values.set(EnvironmentSelection.KEY, 'local');
      expect(await StagingCatalog.launchEnvironment(AppEnvironment.TEST, record)).assertEqual(AppEnvironment.LOCAL);
      record.values.set(EnvironmentSelection.KEY, 'bogus');
      expect(await StagingCatalog.launchEnvironment(AppEnvironment.STAGING, record)).assertEqual(AppEnvironment.STAGING);
      record.failGet = true;
      expect(await StagingCatalog.launchEnvironment(AppEnvironment.STAGING, record)).assertEqual(AppEnvironment.STAGING);
    });
  });

  describe('EnvironmentSwitcher', () => {
    it('switch_cleans_then_persists_selection_and_changes_environment', 0, async () => {
      const log: string[] = [];
      const record: MemoryRecord = new MemoryRecord();
      const switcher: EnvironmentSwitcher =
        new EnvironmentSwitcher(AppEnvironment.TEST, fourEnvironments(), registryWith(new RecordingCleaner('p', log)), record);
      expect(switcher.current).assertEqual(AppEnvironment.TEST);
      expect(switcher.canSwitch()).assertTrue();
      const result: SwitchResult = await switcher.switchTo(AppEnvironment.STAGING);
      expect(result.outcome).assertEqual(SwitchOutcome.SWITCHED);
      expect(log.join(',')).assertEqual('p');
      expect(switcher.current).assertEqual(AppEnvironment.STAGING);
      expect(switcher.endpoints.apiBase).assertEqual('https://api.staging.unit.invalid');
      expect(record.values.get(EnvironmentSelection.KEY)).assertEqual('staging');
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('staging');
    });

    it('selection_survives_restart_without_cleaning_again', 0, async () => {
      const log: string[] = [];
      const registry: LocalDataCleanerRegistry = registryWith(new RecordingCleaner('p', log));
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, fourEnvironments(), registry, record);
      await switcher.switchTo(AppEnvironment.LOCAL);
      const relaunch: AppEnvironment = await StagingCatalog.launchEnvironment(AppEnvironment.TEST, record);
      expect(relaunch).assertEqual(AppEnvironment.LOCAL);
      const report: LaunchReport = await EnvironmentLaunchReconciler.reconcile(relaunch, record, registry);
      expect(report.outcome).assertEqual(LaunchOutcome.UNCHANGED);
      expect(log.join(',')).assertEqual('p');
    });

    it('same_environment_is_unchanged_and_does_not_clean', 0, async () => {
      const log: string[] = [];
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.STAGING, fourEnvironments(),
        registryWith(new RecordingCleaner('p', log)), new MemoryRecord());
      const result: SwitchResult = await switcher.switchTo(AppEnvironment.STAGING);
      expect(result.outcome).assertEqual(SwitchOutcome.UNCHANGED);
      expect(log.length).assertEqual(0);
    });

    it('failed_cleaning_keeps_environment_and_selection', 0, async () => {
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentSelection.KEY, 'test');
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, fourEnvironments(),
        registryWith(new RecordingCleaner('p', [], true)), record);
      const result: SwitchResult = await switcher.switchTo(AppEnvironment.PROD);
      expect(result.outcome).assertEqual(SwitchOutcome.CLEAN_FAILED);
      expect(switcher.current).assertEqual(AppEnvironment.TEST);
      expect(record.values.get(EnvironmentSelection.KEY)).assertEqual('test');
      // 清理可能只做了一半：留下「切换未完成」标记，下次启动（即使仍是 test）强制再清一次。
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual(EnvironmentRecordKeys.UNSETTLED_MARK);
    });

    it('selection_write_failure_keeps_environment', 0, async () => {
      const record: MemoryRecord = new MemoryRecord();
      record.failPutKey = EnvironmentSelection.KEY;
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, fourEnvironments(),
        registryWith(new RecordingCleaner('p', [])), record);
      const result: SwitchResult = await switcher.switchTo(AppEnvironment.LOCAL);
      expect(result.outcome).assertEqual(SwitchOutcome.RECORD_FAILED);
      expect(switcher.current).assertEqual(AppEnvironment.TEST);
      expect(record.values.has(EnvironmentSelection.KEY)).assertFalse();
    });

    it('last_effective_write_failure_is_not_switched_and_release_overwrite_still_cleans', 0, async () => {
      // R2-02 复现：上次生效 prod（面板已选 prod），切到 test：清理成功、选择写入成功，但 LAST_EFFECTIVE=test 写失败。
      const log: string[] = [];
      const registry: LocalDataCleanerRegistry = registryWith(new RecordingCleaner('session', log));
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'prod');
      record.values.set(EnvironmentSelection.KEY, 'prod');
      record.failPutEntry = EnvironmentRecordKeys.LAST_EFFECTIVE + '=test';
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.PROD, fourEnvironments(), registry, record);
      const result: SwitchResult = await switcher.switchTo(AppEnvironment.TEST);
      expect(result.outcome).assertEqual(SwitchOutcome.RECORD_FAILED);
      expect(switcher.current).assertEqual(AppEnvironment.PROD);
      expect(switcher.endpoints.apiBase).assertEqual(PROD_ENDPOINTS.apiBase);
      expect(record.values.get(EnvironmentSelection.KEY)).assertEqual('prod');
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual(EnvironmentRecordKeys.UNSETTLED_MARK);
      expect(log.join(',')).assertEqual('session');
      // 随后覆盖安装 Release：目标 prod，但记录不是 prod → 仍会清理并记录 prod。
      record.failPutEntry = '';
      const releaseEnv: AppEnvironment = await ReleaseCatalog.launchEnvironment(AppEnvironment.PROD, record);
      const report: LaunchReport = await EnvironmentLaunchReconciler.reconcile(releaseEnv, record, registry);
      expect(report.outcome).assertEqual(LaunchOutcome.CLEANED);
      expect(log.join(',')).assertEqual('session,session');
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('prod');
    });

    it('last_effective_write_failure_removes_a_selection_that_did_not_exist', 0, async () => {
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      record.failPutEntry = EnvironmentRecordKeys.LAST_EFFECTIVE + '=local';
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, fourEnvironments(),
        registryWith(new RecordingCleaner('p', [])), record);
      const result: SwitchResult = await switcher.switchTo(AppEnvironment.LOCAL);
      expect(result.outcome).assertEqual(SwitchOutcome.RECORD_FAILED);
      expect(switcher.current).assertEqual(AppEnvironment.TEST);
      expect(record.values.has(EnvironmentSelection.KEY)).assertFalse();
      // Debug 重启：没有选择 → 构建默认 test，但记录是「切换未完成」→ 强制清理。
      const log: string[] = [];
      const relaunch: AppEnvironment = await StagingCatalog.launchEnvironment(AppEnvironment.TEST, record);
      expect(relaunch).assertEqual(AppEnvironment.TEST);
      const report: LaunchReport =
        await EnvironmentLaunchReconciler.reconcile(relaunch, record, registryWith(new RecordingCleaner('p', log)));
      expect(report.outcome).assertEqual(LaunchOutcome.CLEANED);
      expect(log.join(',')).assertEqual('p');
    });

    it('marker_write_failure_changes_nothing_and_does_not_clean', 0, async () => {
      const log: string[] = [];
      const record: MemoryRecord = new MemoryRecord();
      record.values.set(EnvironmentRecordKeys.LAST_EFFECTIVE, 'test');
      record.failPutKey = EnvironmentRecordKeys.LAST_EFFECTIVE;
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, fourEnvironments(),
        registryWith(new RecordingCleaner('p', log)), record);
      const result: SwitchResult = await switcher.switchTo(AppEnvironment.STAGING);
      expect(result.outcome).assertEqual(SwitchOutcome.RECORD_FAILED);
      expect(switcher.current).assertEqual(AppEnvironment.TEST);
      expect(log.length).assertEqual(0);
      expect(record.values.get(EnvironmentRecordKeys.LAST_EFFECTIVE)).assertEqual('test');
      expect(record.values.has(EnvironmentSelection.KEY)).assertFalse();
    });

    it('prod_only_table_cannot_switch', 0, async () => {
      const log: string[] = [];
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, prodOnly(),
        registryWith(new RecordingCleaner('p', log)), new MemoryRecord());
      expect(switcher.current).assertEqual(AppEnvironment.PROD);
      expect(switcher.canSwitch()).assertFalse();
      const result: SwitchResult = await switcher.switchTo(AppEnvironment.STAGING);
      expect(result.outcome).assertEqual(SwitchOutcome.NOT_AVAILABLE);
      expect(log.length).assertEqual(0);
    });
  });

  describe('DebugCapabilities', () => {
    it('prod_keeps_only_switch_server', 0, () => {
      for (const capability of DebugCapabilities.ALL) {
        const expected: boolean = capability === DebugCapability.SWITCH_SERVER;
        expect(DebugCapabilities.isAvailable(capability, AppEnvironment.PROD)).assertEqual(expected);
      }
    });

    it('non_prod_enables_everything', 0, () => {
      const envs: AppEnvironment[] = [AppEnvironment.LOCAL, AppEnvironment.TEST, AppEnvironment.STAGING];
      for (const env of envs) {
        for (const capability of DebugCapabilities.ALL) {
          expect(DebugCapabilities.isAvailable(capability, env)).assertTrue();
        }
      }
    });
  });
}
