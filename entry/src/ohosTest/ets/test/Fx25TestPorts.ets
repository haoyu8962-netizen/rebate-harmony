// entry 自带设备夹具，只替换网络 / 凭据 / 环境端口；会话保存、订阅、清理和重载均走产品代码。
// 不从其他模块的 src/test 导入，不加载 BridgeHost.test 的整套单测。
import {
  ApiAppIdentity, ApiClient, ApiClientDeps, BridgeStatePort, CredentialSource, EnvironmentEndpoints,
  HttpTransport, MemorySessionTokens, NetworkContext, SessionTokenSet, TransportRequest, TransportResponse,
  UpdateCheckStatus, UpdatePort, UpdateState
} from 'core';

class Fx25Server implements HttpTransport {
  handler: (request: TransportRequest) => Promise<TransportResponse> = (_request: TransportRequest) =>
    Promise.reject(new Error('unexpected FX25 request'));

  send(request: TransportRequest): Promise<TransportResponse> {
    return this.handler(request);
  }

  cancel(_request: TransportRequest): void {}
}

class Fx25Context implements NetworkContext {
  endpoints(): EnvironmentEndpoints {
    return new EnvironmentEndpoints('https://api.test.invalid', 'https://h5.test.invalid');
  }

  privacy(): string { return 'full'; }

  credentialsReadable(): boolean { return true; }
}

class Fx25Update implements UpdatePort {
  state(): string { return 'supported'; }

  on10405(_minSupported: string | null): void {}
}

class Fx25Credentials implements CredentialSource {
  deviceId(): string { return 'device-fixture'; }

  installSecret(): string { return 'test-only.install.device-a'; }
}

export class Fx25NetworkRig {
  readonly server: Fx25Server = new Fx25Server();
  readonly tokens: MemorySessionTokens;
  readonly client: ApiClient;

  constructor(initial: SessionTokenSet) {
    this.tokens = new MemorySessionTokens(initial);
    const deps: ApiClientDeps = new ApiClientDeps(this.server, new Fx25Context(),
      new ApiAppIdentity('couli', 'harmony', '1.2.0', '100', 'agc'), this.tokens, new Fx25Update());
    deps.credentials = new Fx25Credentials();
    deps.clock = (): number => 1790661600 * 1000;
    // 设备上保留真实摘要、随机源和计时器；不复制 Core 的判定 / 调度实现。
    this.client = new ApiClient(deps);
  }
}

export class Fx25BridgeState implements BridgeStatePort {
  trustedOrigins(): string[] { return ['https://h5.example.test']; }

  linkPatterns(): string {
    return '{"version":"t","rules":[{"platform":"taobao","category":"union_host",' +
      '"hosts":["taobao.example.test"],"path_patterns":[]}]}';
  }

  shareDomains(): string[] { return ['s.example.test']; }

  privacy(): string { return 'consented'; }

  loggedIn(): boolean { return true; }

  update(): UpdateCheckStatus { return UpdateCheckStatus.finished(UpdateState.OK); }

  fromForceUpdatePage(): boolean { return false; }

  binding(): string { return 'binding-0'; }
}

export function envelope(code: number, dataJson: string): TransportResponse {
  return TransportResponse.ok(code === 0 ? 200 : 400, {},
    '{"code":' + code + ',"msg":"","data":' + dataJson + ',"trace_id":"trace-abcdef123456"}');
}

export function tokenPair(access: string, refresh: string, scope: string): string {
  return '{"access_token":"' + access + '","access_expires_at":"2026-10-02T13:30:00+08:00","refresh_token":"' + refresh
    + '","refresh_expires_at":"2026-11-01T11:30:00+08:00","session_scope":"' + scope + '"}';
}
