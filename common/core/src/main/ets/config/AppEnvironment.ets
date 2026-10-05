/**
 * 服务器环境（03 §3.6）。四个名字在所有构建配置里都存在（解析持久化记录要用）；
 * 但 local / test / staging 的地址只写在 src/staging/ets/config/EnvironmentCatalog.ets，
 * Release（src/release）只编译 prod 的地址。
 */
export enum AppEnvironment {
  LOCAL = 'local',
  TEST = 'test',
  STAGING = 'staging',
  PROD = 'prod'
}

export function parseAppEnvironment(raw: string): AppEnvironment | undefined {
  switch (raw) {
    case 'local':
      return AppEnvironment.LOCAL;
    case 'test':
      return AppEnvironment.TEST;
    case 'staging':
      return AppEnvironment.STAGING;
    case 'prod':
      return AppEnvironment.PROD;
    default:
      return undefined;
  }
}

/** 某个环境的 API 与 H5 基址。 */
export class EnvironmentEndpoints {
  readonly apiBase: string;
  readonly h5Base: string;

  constructor(apiBase: string, h5Base: string) {
    this.apiBase = apiBase;
    this.h5Base = h5Base;
  }
}

/** prod 地址（三套配置都有）。取值是 .invalid 占位，真实域名待定（needs.md N-05）。 */
export const PROD_ENDPOINTS: EnvironmentEndpoints =
  new EnvironmentEndpoints('https://api.prod.couli.invalid', 'https://h5.prod.couli.invalid');

/**
 * 只读的「当前环境」。业务代码（网络层等）只依赖这个接口。
 * Release 的实现是 FixedEnvironment（恒 prod）；Debug / Staging 的实现是 src/staging 里可切换的实现，
 * 切换入口只在那里，src/main 里没有任何改变当前环境的方法。
 */
export interface EnvironmentSource {
  readonly current: AppEnvironment;
  readonly endpoints: EnvironmentEndpoints;
}

/** 固定环境（Release 用）。启动对账失败时不装入任何环境（见 AppConfig 的 EnvironmentGate），不用它兜底。 */
export class FixedEnvironment implements EnvironmentSource {
  readonly current: AppEnvironment;
  readonly endpoints: EnvironmentEndpoints;

  constructor(current: AppEnvironment, endpoints: EnvironmentEndpoints) {
    this.current = current;
    this.endpoints = endpoints;
  }
}
