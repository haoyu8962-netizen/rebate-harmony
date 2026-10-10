// Debug / Staging（core 模块 staging target）：本机假服务的传输入口闸门（鸿蒙第 2 轮评审 R2-01，跨端共性第 16 条）。
// 只在 product=staging 编译，由 src/staging/ets/config/DebugOnly.ets 导出；Release 没有本文件。
// entry 的 DebugFakeServer 把 send / cancel 整个交给它：每次实际发包时统一检查「假服务打开 + 当前环境允许调试假数据（MOCK_DATA）」，
// 两者都满足才由本机假服务回答，否则走真实传输层（prod 只剩 SWITCH_SERVER，03 §3.6）。不按接口逐个检查，新加的假响应（草稿
// previewPage、公告 listArticles、以后的任何接口）自动受同一道检查。
import { AppConfig } from '../../../main/ets/config/AppConfig';
import { AppEnvironment, EnvironmentSource } from '../../../main/ets/config/AppEnvironment';
import { HttpTransport, TransportRequest, TransportResponse } from '../../../main/ets/network/HttpTransport';
import { DebugCapabilities, DebugCapability } from '../config/DebugCapabilities';

/** 调试假数据的统一判断（传输入口、首页数据源、截图替身共用）。 */
export class DebugMockGate {
  /** 假服务打开且当前环境允许调试假数据（环境未定按不允许）。 */
  static allowed(fakeEnabled: boolean, environment: AppEnvironment | undefined): boolean {
    return fakeEnabled && environment !== undefined
      && DebugCapabilities.isAvailable(DebugCapability.MOCK_DATA, environment);
  }

  /** 进程当前环境（AppConfig；未 SETTLED 为 undefined）。 */
  static currentEnvironment(): AppEnvironment | undefined {
    const source: EnvironmentSource | undefined = AppConfig.environment();
    return source === undefined ? undefined : source.current;
  }

  /** 按进程当前环境判断。 */
  static allowedNow(fakeEnabled: boolean): boolean {
    return DebugMockGate.allowed(fakeEnabled, DebugMockGate.currentEnvironment());
  }
}

/**
 * 实际传输入口：fake 是本机假服务（只回答、不连网），real 是真实传输层。send 时按此刻的开关与环境选一边；
 * cancel 交给当初接下这个请求的那一边（发出后切了环境也能取消掉本机假服务的等待）。
 */
export class DebugMockTransport implements HttpTransport {
  private readonly fake: HttpTransport;
  private readonly real: HttpTransport;
  private readonly enabled: () => boolean;
  private readonly environment: () => AppEnvironment | undefined;
  /** 由本机假服务接下、还没结束的请求。 */
  private readonly faked: Set<TransportRequest> = new Set<TransportRequest>();

  constructor(fake: HttpTransport, real: HttpTransport, enabled: () => boolean,
    environment: () => AppEnvironment | undefined = (): AppEnvironment | undefined => DebugMockGate.currentEnvironment()) {
    this.fake = fake;
    this.real = real;
    this.enabled = enabled;
    this.environment = environment;
  }

  /** 此刻是否由本机假服务回答。 */
  mockAllowed(): boolean {
    let enabled: boolean = false;
    let env: AppEnvironment | undefined = undefined;
    try {
      enabled = this.enabled();
      env = this.environment();
    } catch (e) {
      return false;
    }
    return DebugMockGate.allowed(enabled, env);
  }

  send(request: TransportRequest): Promise<TransportResponse> {
    if (!this.mockAllowed()) {
      return this.real.send(request);
    }
    this.faked.add(request);
    return this.fake.send(request).finally(() => {
      this.faked.delete(request);
    });
  }

  cancel(request: TransportRequest): void {
    if (this.faked.has(request)) {
      this.faked.delete(request);
      this.fake.cancel(request);
      return;
    }
    this.real.cancel(request);
  }
}
