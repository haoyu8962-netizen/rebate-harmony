// 调试面板的版本检查假数据（只在 Debug / Staging 编译；Release 只有真实检查器 ApiUpdateChecker，release-scan 查
// AppVersionCheckExample.MARKER 与本文件的偏好文件名）。数据一律从契约 openapi GET /v1/app-versions/check 的响应示例
// （AppVersionCheckExample.DATA_JSON，gen.py 生成）改几个字段得到，不臆造报文字段。
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  AppConfig, DebugCapabilities, DebugCapability, EnvironmentSource, parseAppEnvironment, AppEnvironment,
  UpdateCheckAdapter, UpdateCheckOutcome, UpdateChecker, UpdateCheckResult
} from 'core';
import { AppVersionCheckExample } from 'generated';

/** 调试场景（五种，任务书 §2.2）。 */
export enum DebugUpdateScenario {
  /** 正常：recommended_version 改成与 min_supported_version 相同（本机 1.0.0 不低于两者）。 */
  NORMAL = 'normal',
  /** 建议更新：契约示例原样（min 1.0.0、recommended 1.1.0、latest 1.2.0）。 */
  RECOMMEND = 'recommend',
  /** 强制更新：min_supported_version 改成 latest_version。 */
  FORCE = 'force',
  /** 商店都不可用：强制更新，且各商店 listed_version 都为 null（没有已知上架版本）。 */
  STORES_UNAVAILABLE = 'stores_unavailable',
  /** 请求失败。 */
  FAILURE = 'failure',
  /** 不用假数据：转给真实检查器（F-X-01，经 ApiClient 请求当前环境的 GET /v1/app-versions/check）。 */
  LIVE = 'live'
}

export const DEBUG_UPDATE_SCENARIOS: DebugUpdateScenario[] = [
  DebugUpdateScenario.NORMAL, DebugUpdateScenario.RECOMMEND, DebugUpdateScenario.FORCE,
  DebugUpdateScenario.STORES_UNAVAILABLE, DebugUpdateScenario.FAILURE, DebugUpdateScenario.LIVE
];

function parseScenario(raw: string): DebugUpdateScenario {
  for (const s of DEBUG_UPDATE_SCENARIOS) {
    if (s === raw) {
      return s;
    }
  }
  return DebugUpdateScenario.NORMAL;
}

/** 调试场景的选择：存在 couli_debug_update（调试专用，不在 CouliPreferences 的业务命名空间里，切换环境不清）。 */
export class DebugUpdateScenarioStore {
  static readonly PREFERENCES: string = 'couli_debug_update';
  private static readonly KEY: string = 'scenario';
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private prefs(): preferences.Preferences {
    return preferences.getPreferencesSync(this.context, { name: DebugUpdateScenarioStore.PREFERENCES });
  }

  get current(): DebugUpdateScenario {
    try {
      const raw: preferences.ValueType = this.prefs().getSync(DebugUpdateScenarioStore.KEY, '');
      return parseScenario(typeof raw === 'string' ? raw : '');
    } catch (e) {
      return DebugUpdateScenario.NORMAL;
    }
  }

  set current(value: DebugUpdateScenario) {
    try {
      const p: preferences.Preferences = this.prefs();
      p.putSync(DebugUpdateScenarioStore.KEY, value);
      p.flushSync();
    } catch (e) {
      // 调试选择写失败：本次按内存值不变处理。
    }
  }
}

interface ExampleListing {
  store: string;
  listed_version: string | null;
}

interface ExampleData {
  latest_version: string;
  min_supported_version: string | null;
  recommended_version: string | null;
  update_title: string;
  update_notes: string;
  store_url: string;
  default_store: string;
  stores: ExampleListing[];
}

/** 契约示例按场景改字段后的 check.data（JSON 文本）。 */
export function scenarioData(scenario: DebugUpdateScenario): string {
  const data: ExampleData = JSON.parse(AppVersionCheckExample.DATA_JSON) as ExampleData;
  if (scenario === DebugUpdateScenario.NORMAL) {
    data.recommended_version = data.min_supported_version;
  } else if (scenario === DebugUpdateScenario.FORCE) {
    data.min_supported_version = data.latest_version;
  } else if (scenario === DebugUpdateScenario.STORES_UNAVAILABLE) {
    data.min_supported_version = data.latest_version;
    for (const listing of data.stores) {
      listing.listed_version = null;
    }
  }
  return JSON.stringify(data);
}

/** 当前环境允许调试假数据（prod 环境下只剩「切换服务器地址」，03 §3.6；不允许时转给真实检查器）。 */
function mockDataAllowed(): boolean {
  const source: EnvironmentSource | undefined = AppConfig.environment();
  const env: AppEnvironment | undefined = source === undefined ? undefined : parseAppEnvironment(source.current);
  return env !== undefined && DebugCapabilities.isAvailable(DebugCapability.MOCK_DATA, env);
}

/**
 * 读调试场景、返回假结果的检查器；模拟一点网络耗时，让「检查中」可见。不用假数据时（场景 live，或当前环境不允许调试假数据，
 * 如调试面板切到 prod）原样转给真实检查器（F-X-01），不再按失败。
 */
export class DebugUpdateChecker implements UpdateChecker {
  static readonly FAKE_LATENCY_MILLIS: number = 300;
  readonly scenarios: DebugUpdateScenarioStore;
  private readonly real: UpdateChecker;

  constructor(context: common.Context, real: UpdateChecker) {
    this.scenarios = new DebugUpdateScenarioStore(context);
    this.real = real;
  }

  check(): Promise<UpdateCheckOutcome> {
    if (!mockDataAllowed() || this.scenarios.current === DebugUpdateScenario.LIVE) {
      return this.real.check();
    }
    return new Promise<UpdateCheckOutcome>((resolve: (value: UpdateCheckOutcome) => void) => {
      setTimeout(() => {
        const scenario: DebugUpdateScenario = this.scenarios.current;
        if (!mockDataAllowed() || scenario === DebugUpdateScenario.LIVE) {
          // 等待期间切到了 live 或 prod：转给真实检查器。
          this.real.check().then(resolve);
          return;
        }
        if (scenario === DebugUpdateScenario.FAILURE) {
          resolve(UpdateCheckOutcome.failure());
          return;
        }
        const result: UpdateCheckResult | null = UpdateCheckAdapter.fromJson(scenarioData(scenario));
        resolve(result === null ? UpdateCheckOutcome.failure() : UpdateCheckOutcome.success(result));
      }, DebugUpdateChecker.FAKE_LATENCY_MILLIS);
    });
  }
}
