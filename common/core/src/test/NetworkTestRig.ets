// APP-03a 网络测试的本地假服务与装配（NetworkIntegration、NetworkReviewR1 共用）。不连任何真实地址。
import {
  ApiAppIdentity, ApiClient, ApiClientDeps, ApiRequest, CredentialSource, DeviceRegistrar, ErrorEffect,
  EnvironmentEndpoints,
  HttpTransport, MemoryPendingKeyBackend, MemorySessionTokens, NetworkContext, NetworkHeaders, NetworkRandom,
  NetworkTimer, PendingKeyStore, RcpRawResponse, RcpRequestSpec, RcpSender, SessionTokens, SessionTokenSet,
  TransportRequest,
  TransportResponse, UpdatePort
} from '../../Index';
import { ReferenceDigest } from './TestDigest';

export type Handler = (request: TransportRequest) => Promise<TransportResponse>;

export class Deferred {
  resolve: (response: TransportResponse) => void = (_r: TransportResponse) => {
  };
  readonly promise: Promise<TransportResponse>;

  constructor() {
    this.promise = new Promise<TransportResponse>((resolve: (response: TransportResponse) => void) => {
      this.resolve = resolve;
    });
  }
}

/** 本地假服务：按请求路径分派，记录每次收到的请求。 */
export class FakeServer implements HttpTransport {
  readonly received: TransportRequest[] = [];
  /** 被 ApiClient 取消的请求（撤回同意 / 切换环境 / 超时，lessons 22）。 */
  readonly cancelled: TransportRequest[] = [];
  handler: Handler = (_r: TransportRequest) => Promise.resolve(envelope(0, '{}'));

  send(request: TransportRequest): Promise<TransportResponse> {
    this.received.push(request);
    return this.handler(request);
  }

  cancel(request: TransportRequest): void {
    this.cancelled.push(request);
  }

  count(pathPart: string): number {
    return this.received.filter((r: TransportRequest) => r.url.indexOf(pathPart) >= 0).length;
  }

  last(pathPart: string): TransportRequest {
    const list: TransportRequest[] = this.received.filter((r: TransportRequest) => r.url.indexOf(pathPart) >= 0);
    return list[list.length - 1];
  }
}

/** 可注入的 RCP 发送层：记录每次交给 RCP 的请求与配置、被取消的请求，按脚本返回。 */
export class FakeRcpSender implements RcpSender {
  readonly specs: RcpRequestSpec[] = [];
  readonly cancelled: RcpRequestSpec[] = [];
  reply: (spec: RcpRequestSpec) => Promise<RcpRawResponse> = (_s: RcpRequestSpec) =>
  Promise.resolve(new RcpRawResponse(200, {}, '{"code":0,"msg":"","data":{},"trace_id":"t"}'));

  send(spec: RcpRequestSpec): Promise<RcpRawResponse> {
    this.specs.push(spec);
    return this.reply(spec);
  }

  cancel(spec: RcpRequestSpec): void {
    this.cancelled.push(spec);
  }
}

/** 退避（≤ 1 秒）立即结束并记录；超时定时器挂起，直到 fire()。 */
export class FakeTimer implements NetworkTimer {
  readonly delays: number[] = [];
  onBackoff: () => void = () => {
  };
  /** 为 true 时退避（≤ 1 秒）也挂起，直到 releaseBackoffs()（APP-08 R2-01：在退避期间插入别的请求）。 */
  holdBackoff: boolean = false;
  private pending: (() => void)[] = [];
  private backoffs: (() => void)[] = [];

  delay(millis: number): Promise<void> {
    this.delays.push(millis);
    if (millis <= 1000) {
      this.onBackoff();
      if (this.holdBackoff) {
        return new Promise<void>((resolve: () => void) => {
          this.backoffs.push(resolve);
        });
      }
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void) => {
      this.pending.push(resolve);
    });
  }

  get heldBackoffs(): number {
    return this.backoffs.length;
  }

  releaseBackoffs(): void {
    const list: (() => void)[] = this.backoffs;
    this.backoffs = [];
    for (const resolve of list) {
      resolve();
    }
  }

  fire(): void {
    const list: (() => void)[] = this.pending;
    this.pending = [];
    for (const resolve of list) {
      resolve();
    }
  }
}

export class FakeRandom implements NetworkRandom {
  nonces: string[] = [];
  private counter: number = 0;

  nonce(): string {
    if (this.nonces.length > 0) {
      return this.nonces.shift() as string;
    }
    this.counter++;
    const hex: string = this.counter.toString(16);
    return '0'.repeat(32 - hex.length) + hex;
  }

  uuid(): string {
    this.counter++;
    return 'uuid-0000-' + this.counter;
  }
}

export class FakeContext implements NetworkContext {
  privacyRaw: string = 'full';
  readable: boolean = true;
  settled: boolean = true;

  endpoints(): EnvironmentEndpoints | undefined {
    return this.settled ? new EnvironmentEndpoints('https://api.test.invalid', 'https://h5.test.invalid') : undefined;
  }

  privacy(): string {
    return this.privacyRaw;
  }

  credentialsReadable(): boolean {
    return this.readable;
  }
}

export class FakeUpdate implements UpdatePort {
  stateRaw: string = 'supported';
  calls: (string | null)[] = [];

  state(): string {
    return this.stateRaw;
  }

  on10405(minSupported: string | null): void {
    this.calls.push(minSupported);
  }
}

export class FakeCredentials implements CredentialSource {
  device: string | null = 'device-fixture';
  secret: string | null = 'test-only.install.device-a';

  deviceId(): string | null {
    return this.device;
  }

  installSecret(): string | null {
    return this.secret;
  }
}

/** 10402 的重新注册（APP-03b 的替身）：默认不能注册；result 可换成可控的 promise。 */
export class FakeRegistrar implements DeviceRegistrar {
  calls: number = 0;
  /** 每次调用时被拒请求带的 device_id。 */
  usedDeviceIds: (string | null)[] = [];
  result: () => Promise<boolean> = () => Promise.resolve(false);

  /** 每次调用带的调用方有效性（R3-03；null = 独立调用方）。 */
  callers: ((() => boolean) | null)[] = [];

  reregister(usedDeviceId: string | null, caller: (() => boolean) | null): Promise<boolean> {
    this.calls++;
    this.usedDeviceIds.push(usedDeviceId);
    this.callers.push(caller);
    return this.result();
  }

  callersChanged(): void {
  }

  /** 不走重新注册的 10402 隔离（F-ALL-08 共性 25）：只记下来。 */
  isolated: (string | null)[] = [];

  isolate(usedDeviceId: string | null): void {
    this.isolated.push(usedDeviceId);
  }
}

export class Rig {
  readonly server: FakeServer = new FakeServer();
  readonly timer: FakeTimer = new FakeTimer();
  readonly random: FakeRandom = new FakeRandom();
  readonly context: FakeContext = new FakeContext();
  readonly update: FakeUpdate = new FakeUpdate();
  readonly credentials: FakeCredentials = new FakeCredentials();
  readonly tokens: MemorySessionTokens;
  readonly pendingBackend: MemoryPendingKeyBackend;
  readonly registrar: FakeRegistrar = new FakeRegistrar();
  readonly pending: PendingKeyStore;
  readonly sessionEffects: ErrorEffect[] = [];
  /** 与 sessionEffects 一一对应：网络层确定清理时被清掉的会话世代（APP-05a 共性 26）。 */
  readonly clearedGenerations: number[] = [];
  /** App 的会话级回调（APP-05a 共性 25、26：测试把它接到 Router 的「原会话被清除」分界）。 */
  onSessionEffect: ((effect: ErrorEffect, clearedGeneration: number) => void) | null = null;
  /** 异步刷新的作用域变化通知（世代:作用域）。 */
  readonly refreshNotices: string[] = [];
  /** 与 refreshNotices 一一对应：这次通知是否要恢复待办（F-HM-09）。 */
  readonly refreshResume: boolean[] = [];
  readonly client: ApiClient;
  nowMillis: number = 1790661600 * 1000;
  /** App 的会话级 Effect 回调抛异常（R1-04）。 */
  throwOnSessionEffect: boolean = false;
  /** 下一次网络层读时钟时执行一次（harmony-review-r3 R3-02：在刷新结论定下与结算之间插入会话变化）。 */
  onClock: (() => void) | null = null;

  constructor(tokens: SessionTokenSet | null = new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'),
    transport: HttpTransport | null = null, tokenStore: MemorySessionTokens | null = null,
    pendingBackend: MemoryPendingKeyBackend | null = null, updatePort: UpdatePort | null = null,
    credentials: CredentialSource | null = null, registrar: DeviceRegistrar | null = null,
    sessionTokens: SessionTokens | null = null) {
    this.tokens = tokenStore ?? new MemorySessionTokens(tokens);
    this.pendingBackend = pendingBackend ?? new MemoryPendingKeyBackend();
    this.pending = new PendingKeyStore(this.pendingBackend, (): number => this.nowMillis);
    this.pending.coldStart('user-1');
    const deps: ApiClientDeps = new ApiClientDeps(transport ?? this.server, this.context,
      new ApiAppIdentity('couli', 'harmony', '1.2.0', '100', 'agc'), sessionTokens ?? this.tokens,
      updatePort ?? this.update);
    // APP-03b：可换成真实的 DeviceRegistry（凭据源与 10402 的重新注册）。
    deps.credentials = credentials ?? this.credentials;
    deps.digest = new ReferenceDigest();
    deps.pendingKeys = this.pending;
    deps.deviceRegistrar = registrar ?? this.registrar;
    deps.timer = this.timer;
    deps.random = this.random;
    deps.clock = (): number => {
      const hook: (() => void) | null = this.onClock;
      if (hook !== null) {
        this.onClock = null;
        hook();
      }
      return this.nowMillis;
    };
    deps.sessionEffect = (effect: ErrorEffect, clearedGeneration: number): void => {
      this.sessionEffects.push(effect);
      this.clearedGenerations.push(clearedGeneration);
      const hook: ((effect: ErrorEffect, clearedGeneration: number) => void) | null = this.onSessionEffect;
      if (hook !== null) {
        hook(effect, clearedGeneration);
      }
      if (this.throwOnSessionEffect) {
        throw new Error('session effect handler failed');
      }
    };
    // F-HM-08（APP-05a 共性 14）：记录异步刷新带世代的作用域变化通知。
    deps.sessionRefreshed = (generation: number, scope: string): void => {
      this.refreshNotices.push(generation + ':' + scope);
    };
    // F-HM-09（APP-05a 共性 19）：带触发来源的同一通知（resumePending：App 级屏障为 true）。
    deps.sessionRefreshedFrom = (generation: number, scope: string, resumePending: boolean): void => {
      this.refreshNotices.push(generation + ':' + scope);
      this.refreshResume.push(resumePending);
    };
    this.client = new ApiClient(deps);
  }
}

export function envelope(code: number, dataJson: string, headers: Record<string, string> = {}): TransportResponse {
  return TransportResponse.ok(code === 0 ? 200 : 400, headers,
    '{"code":' + code + ',"msg":"","data":' + dataJson + ',"trace_id":"trace-abcdef123456"}');
}

export function tokenPair(access: string, refresh: string, scope: string): string {
  return '{"access_token":"' + access + '","access_expires_at":"2026-10-02T13:30:00+08:00","refresh_token":"' + refresh
    + '","refresh_expires_at":"2026-11-01T11:30:00+08:00","session_scope":"' + scope + '"}';
}

export function header(request: TransportRequest, name: string): string | undefined {
  return request.headers[name];
}

export async function flush(): Promise<void> {
  for (let i: number = 0; i < 30; i++) {
    await Promise.resolve();
  }
}

/** 带 Bearer old-access 的业务请求回 10002，带 new-access 的成功；刷新由 deferred 控制。 */
export function refreshScenario(rig: Rig, refresh: Deferred): void {
  rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
    if (request.url.indexOf('/v1/auth/refresh') >= 0) {
      return refresh.promise;
    }
    if (header(request, NetworkHeaders.AUTHORIZATION) === 'Bearer new-access') {
      return Promise.resolve(envelope(0, '{"ok":true}'));
    }
    return Promise.resolve(envelope(10002, '{}'));
  };
}

export function openLinkRequest(): ApiRequest {
  const params: Record<string, string> = {};
  params['link_id'] = 'abc';
  return new ApiRequest('openLink', params, 'src=agent', '{"no_rebate":false}');
}
