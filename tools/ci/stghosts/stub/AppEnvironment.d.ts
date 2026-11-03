// FU-X-STAGING-HOSTS-harmony 测试作者 v1：新接口声明桩（= tests-harmony-handback.md §3）。只给 check-arkts.cjs 默认模式用：
// 产品还没有 streamBase 时，'.../main/ets/config/AppEnvironment' 解析到这里；--real 模式不用它。与真实 AppEnvironment.ets 的差别只有
// EnvironmentEndpoints 的第三个构造参数与 streamBase 字段。
export declare enum AppEnvironment {
  LOCAL = 'local',
  TEST = 'test',
  STAGING = 'staging',
  PROD = 'prod'
}

export declare function parseAppEnvironment(raw: string): AppEnvironment | undefined;

export declare class EnvironmentEndpoints {
  readonly apiBase: string;
  readonly h5Base: string;
  /** stream 入口基址；'' = 不分流（/v1/agent/* 仍走 apiBase）。 */
  readonly streamBase: string;

  constructor(apiBase: string, h5Base: string, streamBase?: string);
}

export declare const PROD_ENDPOINTS: EnvironmentEndpoints;

export interface EnvironmentSource {
  readonly current: AppEnvironment;
  readonly endpoints: EnvironmentEndpoints;
}

export declare class FixedEnvironment implements EnvironmentSource {
  readonly current: AppEnvironment;
  readonly endpoints: EnvironmentEndpoints;

  constructor(current: AppEnvironment, endpoints: EnvironmentEndpoints);
}
