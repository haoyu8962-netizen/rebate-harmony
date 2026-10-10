// FU-HM-0711b 鸿蒙跟进合集的回归测试（F-HM-27 的用例在 AgentIntegration.test.ets，与 R3-02 同一套撤回流程）：
// - F-X-02：传输入口以外的调试替身统一过「假服务打开 且 当前环境允许 MOCK_DATA」，且每次使用时重新判断——在 test 环境创建的替身，
//   切到 prod 后一律走真实路径或返回空，不给假数据（core staging 的 DebugSubstitutes，按相对路径引入，同 HomeFixR2）。
// - F-X-03：「状态先发布、屏障后竖」时序审计。撤回同意、切换环境、退出登录三条路径，在对外可见的状态已发布、清理器还没运行时，
//   恢复一个发布之前就开始、正在退避等待的旧请求：凭据（令牌、device_id、install_secret）零读取、零发送。
// - 第 1 轮评审修复（r1_0x_*）：R1-01 新请求与会话查询在切换 / 撤回进行中零读取；R1-02 真实 LoginService.logout 被撤回或切环境
//   取消后恢复，零读取；R1-03 首页端口持有旧实例切 prod；R1-04 契约包装等待期间切 prod；R1-05 剪贴板、分享样例的暂存与闸门。
// - 第 2 轮评审修复（r2_0x_*）：R2-01 实际 DeviceRegistry、TrackerQueue 在切换窗口与撤回窗口里零读取（缓存与存储都不读），
//   就绪后照常读取的对照；R2-02 环境未就绪时确认 / 放弃上一笔与 HEAD 逐项对照的四种拒绝分类。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClient, ApiOutcome, ApiRequest, ApiResult, AppEnvironment, AuthStepResult, ClientEvents, CredentialSource, DeviceIdReader,
  DeviceRegistry, EnvironmentEndpoints, MemoryDeviceCredentialStore, PrivacyStateRaw, StoredDevice, TrackerQueue,
  EnvironmentRecord, EnvironmentSwitchGate, HomeContractPort, LocalDataCleaner, LocalDataCleanerRegistry,
  LocalRejectReason, LoginHost, NetworkHeaders, LoginService, MeContractPort, MemoryPendingKeyBackend, MemoryPrivacyStore,
  MemorySessionTokens, NetworkComposition, OAuthProvider, PendingKeyRecord, PrivacyGate, PushTokenSource, SessionTokens,
  SessionTokenSet, ThirdPartyAuthAdapter, ThirdPartyAuthKind, ThirdPartyAuthResult, TransportFailure, TransportRequest,
  TransportResponse, WalletContractPort, WebCodeAuthorizer
} from '../../Index';
import {
  DebugLaunchDeferral, DebugSubstitutes, GatedAuthAdapter, GatedHomeContractPort, GatedMeContractPort,
  GatedPendingKeyBackend, GatedPushTokenSource, GatedWalletContractPort, GatedWebCodeAuthorizer
} from '../staging/ets/network/DebugSubstitutes';
import { HomeDebugSources } from '../staging/ets/home/HomePreviewSession';
import { EnvironmentSwitcher, SwitchResult } from '../staging/ets/config/EnvironmentSwitcher';
import { FakeContext, flush, Rig } from './NetworkTestRig';

// ---------------------------------------------------------------- F-X-02 替身

function okResult(): ApiResult {
  return new ApiResult(ApiOutcome.SUCCESS, 0, '', {}, 'trace-fake', 200, TransportFailure.NONE, null, null, null);
}

class CountingMe implements MeContractPort {
  calls: number = 0;

  updateNickname(_n: string, _s: () => boolean): Promise<ApiResult> {
    this.calls++;
    return Promise.resolve(okResult());
  }

  getNotificationSettings(_s: () => boolean): Promise<ApiResult> {
    this.calls++;
    return Promise.resolve(okResult());
  }

  putNotificationSettings(_v: boolean, _s: () => boolean): Promise<ApiResult> {
    this.calls++;
    return Promise.resolve(okResult());
  }
}

class CountingWallet implements WalletContractPort {
  calls: number = 0;

  submitRealname(_n: string, _i: string): Promise<ApiResult> {
    this.calls++;
    return Promise.resolve(okResult());
  }

  getLaborAgreement(): Promise<ApiResult> {
    this.calls++;
    return Promise.resolve(okResult());
  }

  signLaborAgreement(_v: string, _h: string): Promise<ApiResult> {
    this.calls++;
    return Promise.resolve(okResult());
  }
}

/** 假微信适配器：authorize 可挂起（模拟授权等待期间切环境）。 */
class FakeAuth implements ThirdPartyAuthAdapter {
  readonly provider: string = OAuthProvider.WECHAT;
  calls: number = 0;
  private resolvers: ((r: ThirdPartyAuthResult) => void)[] = [];

  adapterAvailable(): boolean {
    return true;
  }

  installed(): boolean | null {
    return true;
  }

  authorize(_nonce: string): Promise<ThirdPartyAuthResult> {
    this.calls++;
    return new Promise<ThirdPartyAuthResult>((resolve: (r: ThirdPartyAuthResult) => void): void => {
      this.resolvers.push(resolve);
    });
  }

  answer(nonce: string): void {
    const all: ((r: ThirdPartyAuthResult) => void)[] = this.resolvers.splice(0, this.resolvers.length);
    for (const r of all) {
      r(new ThirdPartyAuthResult(ThirdPartyAuthKind.CREDENTIAL, 'debug-stub-wechat-code', nonce));
    }
  }
}

class FakeWebCode implements WebCodeAuthorizer {
  calls: number = 0;

  available(): boolean {
    return true;
  }

  authorize(_u: string, _s: string): Promise<AuthStepResult> {
    this.calls++;
    return Promise.resolve(AuthStepResult.webCode('debug-fake-code'));
  }
}

class FakePush implements PushTokenSource {
  started: boolean = false;

  start(): void {
    this.started = true;
  }

  stop(): void {
    this.started = false;
  }

  current(): string | null {
    return this.started ? 'debug-push-token-1' : null;
  }

  subscribe(_l: () => void): () => void {
    return (): void => {
    };
  }
}

function record(key: string): PendingKeyRecord {
  return new PendingKeyRecord(key, 'bindPhone', '{}', 'summary', 'user-1', 0, 'in_flight', false);
}

// ---------------------------------------------------------------- F-X-03 凭据读取计数

/** 令牌读取计数（access / refresh）；clear 可关掉，模拟「删除令牌的清理器还没运行」。 */
class CountingTokens implements SessionTokens {
  readonly inner: MemorySessionTokens;
  reads: number = 0;
  clearEnabled: boolean = true;

  constructor(tokens: SessionTokenSet | null) {
    this.inner = new MemorySessionTokens(tokens);
  }

  accessToken(): string | null {
    this.reads++;
    return this.inner.accessToken();
  }

  refreshToken(): string | null {
    this.reads++;
    return this.inner.refreshToken();
  }

  scope(): string {
    this.reads++;
    return this.inner.scope();
  }

  account(): string | null {
    this.reads++;
    return this.inner.account();
  }

  readStatus(): string {
    this.reads++;
    return this.inner.readStatus();
  }

  save(tokens: SessionTokenSet): void {
    this.inner.save(tokens);
  }

  clear(): void {
    if (this.clearEnabled) {
      this.inner.clear();
    }
  }
}

class CountingCredentials implements CredentialSource {
  reads: number = 0;

  deviceId(): string | null {
    this.reads++;
    return 'device-fixture';
  }

  installSecret(): string | null {
    this.reads++;
    return 'test-only.install.device-a';
  }
}

/** 凭据可读取与否按真实 PrivacyGate 实时取（App：AppNetwork.credentialsReadable → AppPrivacy.credentialsReadable）。 */
class PrivacyContext extends FakeContext {
  private readonly gate: PrivacyGate;

  constructor(gate: PrivacyGate) {
    super();
    this.gate = gate;
  }

  credentialsReadable(): boolean {
    return this.gate.credentialsReadable();
  }
}

/** 地址按真实 EnvironmentSwitchGate 实时取（App：AppConfig.endpoints 在闸门关闭时为 undefined）。 */
class SwitchContext extends FakeContext {
  private readonly gate: EnvironmentSwitchGate;

  constructor(gate: EnvironmentSwitchGate) {
    super();
    this.gate = gate;
  }

  endpoints(): EnvironmentEndpoints | undefined {
    return this.gate.open ? super.endpoints() : undefined;
  }
}

/** 读环境记录一直挂起：switchTo 停在第一个 await，清理器一个都没运行。 */
class HangingRecord implements EnvironmentRecord {
  gets: number = 0;

  get(_key: string): Promise<string | undefined> {
    this.gets++;
    return new Promise<string | undefined>((_resolve: (v: string | undefined) => void): void => {
    });
  }

  put(_key: string, _value: string): Promise<void> {
    return Promise.resolve();
  }

  remove(_key: string): Promise<void> {
    return Promise.resolve();
  }
}

class CountingCleaner implements LocalDataCleaner {
  readonly name: string;
  runs: number = 0;

  constructor(name: string) {
    this.name = name;
  }

  clean(): Promise<void> {
    this.runs++;
    return Promise.resolve();
  }
}

function switchTable(): Map<AppEnvironment, EnvironmentEndpoints> {
  const map: Map<AppEnvironment, EnvironmentEndpoints> = new Map<AppEnvironment, EnvironmentEndpoints>();
  map.set(AppEnvironment.TEST, new EnvironmentEndpoints('https://api.test.invalid', 'https://h5.test.invalid'));
  map.set(AppEnvironment.STAGING, new EnvironmentEndpoints('https://api.staging.invalid', 'https://h5.staging.invalid'));
  return map;
}

/** 旧请求：GET /v1/me 第一次断连，进入退避（挂起），等待恢复。 */
class HeldRequest {
  result: ApiResult | null = null;
}

async function startHeld(rig: Rig): Promise<HeldRequest> {
  rig.timer.holdBackoff = true;
  rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
  Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
  const held: HeldRequest = new HeldRequest();
  rig.client.request(new ApiRequest('getMe')).then((r: ApiResult): void => {
    held.result = r;
  });
  await flush();
  return held;
}

// ---------------------------------------------------------------- 第 1 轮评审修复用的替身

/** 清理器一直挂起：清理前钩子（真实 invalidate）已执行，令牌清理没有完成。 */
class HangingCleaner implements LocalDataCleaner {
  readonly name: string;
  runs: number = 0;

  constructor(name: string) {
    this.name = name;
  }

  clean(): Promise<void> {
    this.runs++;
    return new Promise<void>((_resolve: () => void): void => {
    });
  }
}

class RecordingHost implements LoginHost {
  readonly calls: string[] = [];

  updateState(): string {
    return 'supported';
  }

  hasPendingAction(): boolean {
    return false;
  }

  closeLogin(): void {
    this.calls.push('closeLogin');
  }

  resumePending(): void {
    this.calls.push('resumePending');
  }

  discardPending(): void {
    this.calls.push('discardPending');
  }

  enterForceUpdate(): void {
    this.calls.push('enterForceUpdate');
  }

  sessionChanged(): void {
    this.calls.push('sessionChanged');
  }

  sessionSynced(): void {
    this.calls.push('sessionSynced');
  }

  sessionEnded(): void {
    this.calls.push('sessionEnded');
  }
}

/** 手动兑现的结果（契约替身、首页替身的「等待期间」）。 */
class Pending {
  private resolvers: ((r: ApiResult) => void)[] = [];

  next(): Promise<ApiResult> {
    return new Promise<ApiResult>((resolve: (r: ApiResult) => void): void => {
      this.resolvers.push(resolve);
    });
  }

  get waiting(): number {
    return this.resolvers.length;
  }

  answerAll(): void {
    const all: ((r: ApiResult) => void)[] = this.resolvers.splice(0, this.resolvers.length);
    for (const r of all) {
      r(okResult());
    }
  }
}

class SlowMe implements MeContractPort {
  readonly pending: Pending = new Pending();

  updateNickname(_n: string, _s: () => boolean): Promise<ApiResult> {
    return this.pending.next();
  }

  getNotificationSettings(_s: () => boolean): Promise<ApiResult> {
    return this.pending.next();
  }

  putNotificationSettings(_v: boolean, _s: () => boolean): Promise<ApiResult> {
    return this.pending.next();
  }
}

class SlowWallet implements WalletContractPort {
  readonly pending: Pending = new Pending();

  submitRealname(_n: string, _i: string): Promise<ApiResult> {
    return this.pending.next();
  }

  getLaborAgreement(): Promise<ApiResult> {
    return this.pending.next();
  }

  signLaborAgreement(_v: string, _h: string): Promise<ApiResult> {
    return this.pending.next();
  }
}

class SlowHome implements HomeContractPort {
  readonly pending: Pending = new Pending();
  calls: number = 0;
  cancels: number[] = [];

  getPage(_k: string, _a: boolean, _s: () => boolean): Promise<ApiResult> {
    this.calls++;
    return this.pending.next();
  }

  listSectionItems(_k: string, _id: string, _c: string | null, _a: boolean, _s: () => boolean): Promise<ApiResult> {
    this.calls++;
    return this.pending.next();
  }

  cancel(owner: number): void {
    this.cancels.push(owner);
  }
}

class Box {
  value: boolean | null = null;
}

class Results {
  readonly list: ApiResult[] = [];
}

function collect(results: Results, p: Promise<ApiResult>): void {
  p.then((r: ApiResult): void => {
    results.list.push(r);
  });
}

function expectBlocked(r: ApiResult): void {
  expect(r.ok).assertFalse();
  expect(r.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
  expect(r.localRejectReason).assertEqual(LocalRejectReason.SEND_BLOCKED);
}

/** 新请求与全部会话查询入口（R1-01）：返回 getMe 的结果；查询结果按「没有会话」断言。 */
async function queryEverything(rig: Rig): Promise<ApiResult[]> {
  const results: ApiResult[] = [];
  results.push(await rig.client.request(new ApiRequest('getMe')));
  results.push(await rig.client.request(new ApiRequest('logout')));
  results.push(await rig.client.confirmPending('k-1'));
  results.push(await rig.client.abandonPending('k-1'));
  expect(rig.client.sessionAccount()).assertNull();
  expect(rig.client.sessionReadable()).assertFalse();
  expect(rig.client.sessionScope()).assertEqual('full');
  expect(rig.client.captureScope().account).assertNull();
  expect(rig.client.pendingFor('bindPhone')).assertNull();
  expect(rig.client.pendingState('k-1').record).assertNull();
  expect(await rig.client.refreshRestrictedSession()).assertFalse();
  expect(await rig.client.refreshRestrictedSession((): boolean => true)).assertFalse();
  rig.client.onUpdateStateChanged();
  return results;
}


// ---------------------------------------------------------------- 第 2 轮评审修复用的替身

/** 设备凭据存储的读取计数（R2-01：零读取 = read 一次都没调用）。 */
class CountingDeviceStore extends MemoryDeviceCredentialStore {
  reads: number = 0;

  read(): StoredDevice {
    this.reads++;
    return super.read();
  }
}

class FixedOdid implements DeviceIdReader {
  reads: number = 0;

  read(): string | null {
    this.reads++;
    return 'b0f3c2a1d4e5f60718293a4b5c6d7e8f';
  }
}

/** 环境记录立即完成（切换能走完、闸门重新打开；对照用）。 */
class ImmediateRecord implements EnvironmentRecord {
  readonly values: Map<string, string> = new Map<string, string>();

  get(key: string): Promise<string | undefined> {
    return Promise.resolve(this.values.get(key));
  }

  put(key: string, value: string): Promise<void> {
    this.values.set(key, value);
    return Promise.resolve();
  }

  remove(key: string): Promise<void> {
    this.values.delete(key);
    return Promise.resolve();
  }
}

/** 实际 DeviceRegistry 接实际 ApiClient（凭据源、10402 重新注册）与实际 TrackerQueue（埋点 device_id 取自 registry）。 */
class DeviceRig {
  readonly store: CountingDeviceStore = new CountingDeviceStore();
  readonly odid: FixedOdid = new FixedOdid();
  readonly tokens: CountingTokens =
    new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
  readonly registry: DeviceRegistry;
  readonly rig: Rig;
  readonly tracker: TrackerQueue;
  privacyRaw: string = PrivacyStateRaw.CONSENTED;

  constructor(context: FakeContext, switchGate: EnvironmentSwitchGate | null) {
    this.store.deviceId = 'device-a';
    this.store.installSecret = 'test-only.install.device-a';
    let client: ApiClient | null = null;
    this.registry = new DeviceRegistry('harmony', this.odid, this.store, (): string => this.privacyRaw,
      (): ApiClient | null => client);
    if (switchGate !== null) {
      this.registry.attachEnvironment(switchGate);
    }
    this.rig = new Rig(null, null, null, null, null, this.registry, this.registry, this.tokens, context);
    client = this.rig.client;
    this.tracker = new TrackerQueue((): string | null => null, (_v: string | null): void => {
    }, (_e: string[]): boolean => true, PrivacyStateRaw.CONSENTED, (): string | null => null, '', 'harmony', '1.2.0',
      'session-1', (): number => 0, (): boolean => false);
    // 与 AppClientCore 相同的接线：device_id 取自 DeviceRegistry.deviceId()。
    this.tracker.deviceIdSource = (): string | null => this.registry.deviceId();
  }

  devicesSent(): number {
    return this.rig.server.received.filter((r: TransportRequest) => r.url.indexOf('/v1/devices') >= 0).length;
  }
}

/** 窗口内的全部设备凭据读取入口：都按没有凭据返回，缓存与存储零读取，埋点不接受，注册不开始。 */
async function expectDeviceReadsNothing(d: DeviceRig): Promise<void> {
  const storeReads: number = d.store.reads;
  const odidReads: number = d.odid.reads;
  const sends: number = d.rig.server.received.length;
  expect(d.registry.credentialsReadable()).assertFalse();
  expect(d.registry.deviceId()).assertNull();
  expect(d.registry.installSecret()).assertNull();
  expect(d.registry.registered).assertFalse();
  const queued: number = d.tracker.queueSize;
  expect(d.tracker.track(ClientEvents.appLaunch('Home'))).assertFalse();
  expect(d.tracker.queueSize).assertEqual(queued);
  expect(await d.registry.register()).assertFalse();
  expect(await d.registry.reregister('device-a')).assertFalse();
  d.registry.isolate('device-a');
  const r: ApiResult = await d.rig.client.request(new ApiRequest('getMe'));
  expect(r.ok).assertFalse();
  expect(d.store.reads).assertEqual(storeReads);
  expect(d.odid.reads).assertEqual(odidReads);
  expect(d.store.clearCount).assertEqual(0);
  expect(d.rig.server.received.length).assertEqual(sends);
}

/** R2-02 的四种情况。 */
enum PendingCase {
  VALID = 'valid',
  MISSING = 'missing',
  GUEST = 'guest',
  MISMATCH = 'mismatch'
}

const PENDING_KEY: string = 'k-r2-02';

/**
 * HEAD（1a80ebb）在环境未就绪时的结论（逐项读 HEAD 的 confirmPending / abandonPending：先读可信会话账号 → 游客
 * account_unknown；pendingOwner → 记录属于别的账号 account_mismatch；没有记录 → pending_key_unresolved；有效记录走到
 * runCall，RequestHeaderPolicy.decide 以 environment_unsettled 拒绝）。两个方法相同。
 */
function headReason(c: PendingCase): string {
  switch (c) {
    case PendingCase.VALID:
      return LocalRejectReason.ENVIRONMENT_UNSETTLED;
    case PendingCase.MISSING:
      return LocalRejectReason.PENDING_KEY_UNRESOLVED;
    case PendingCase.GUEST:
      return LocalRejectReason.ACCOUNT_UNKNOWN;
    default:
      return LocalRejectReason.ACCOUNT_MISMATCH;
  }
}

class PendingScenario {
  readonly switchGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
  readonly tokens: CountingTokens;
  readonly creds: CountingCredentials = new CountingCredentials();
  readonly rig: Rig;
  readonly registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
  readonly cleaner: CountingCleaner = new CountingCleaner('session_tokens');

  constructor(c: PendingCase) {
    this.tokens = new CountingTokens(c === PendingCase.GUEST ? null :
      new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
    this.rig = new Rig(null, null, null, null, null, this.creds, null, this.tokens, new SwitchContext(this.switchGate));
    this.registry.register(this.cleaner);
    NetworkComposition.install(this.rig.client, this.registry, (): void => {
    }, this.switchGate);
    // 环境就绪时的正常使用：user-1 有一笔结果未知的提现（缺失记录的情况不建）；发起页先查未决状态（绑定会话归属）。
    if (c !== PendingCase.MISSING) {
      this.rig.pendingBackend.write(new PendingKeyRecord(PENDING_KEY, 'createWithdrawal', '{"amount_cent":1000}',
        'summary', 'user-1', 0, 'unknown', true));
    }
    this.rig.pending.restore('user-1');
    this.rig.client.pendingState(PENDING_KEY);
    if (c === PendingCase.MISMATCH) {
      // 登录流程以外换成 user-2（NetworkReviewR1 r1_02 的情形），之后一次可读的会话查询读到了 user-2；未决存储仍指向 user-1。
      this.tokens.inner.save(new SessionTokenSet('b-access', 'b-refresh', 'full', 'user-2'));
      expect(this.rig.client.sessionAccount()).assertEqual('user-2');
      expect(this.rig.pending.currentAccount).assertEqual('user-1');
    }
  }

  /** 开始切换：闸门同步关闭 → invalidate，停在读环境记录，清理器没运行。 */
  startSwitch(): void {
    const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, switchTable(), this.registry,
      new HangingRecord(), this.switchGate);
    switcher.switchTo(AppEnvironment.STAGING);
    expect(this.switchGate.open).assertFalse();
    expect(this.cleaner.runs).assertEqual(0);
  }

  call(abandon: boolean): Promise<ApiResult> {
    return abandon ? this.rig.client.abandonPending(PENDING_KEY) : this.rig.client.confirmPending(PENDING_KEY);
  }
}

export default function followupHM0711bTest() {
  describe('FollowupHM0711b', () => {
    // ---------------------------------------------------------------- F-X-02
    it('fx02_gate_requires_fake_on_and_mock_data_environment_each_use', 0, () => {
      let on: boolean = true;
      let env: AppEnvironment | undefined = AppEnvironment.TEST;
      const gate: () => boolean = DebugSubstitutes.gate((): boolean => on, (): AppEnvironment | undefined => env);
      expect(gate()).assertTrue();
      // 同一个闸门：切到 prod 立即关闭（不是建的时候算一次）。
      env = AppEnvironment.PROD;
      expect(gate()).assertFalse();
      env = undefined;
      expect(gate()).assertFalse();
      env = AppEnvironment.TEST;
      on = false;
      expect(gate()).assertFalse();
      on = true;
      expect(gate()).assertTrue();
      const throwing: () => boolean = DebugSubstitutes.gate((): boolean => {
        throw new Error('flag unreadable');
      }, (): AppEnvironment | undefined => AppEnvironment.TEST);
      expect(throwing()).assertFalse();
      expect(DebugSubstitutes.choose<string | null>(gate, 'fake', null)).assertEqual('fake');
      env = AppEnvironment.PROD;
      expect(DebugSubstitutes.choose<string | null>(gate, 'fake', null)).assertNull();
      expect(DebugSubstitutes.choose<number>(gate, 9000, 2000)).assertEqual(2000);
    });

    it('fx02_contract_ports_created_in_test_reject_in_prod_without_calling_fake', 0, async () => {
      let env: AppEnvironment | undefined = AppEnvironment.TEST;
      const gate: () => boolean = DebugSubstitutes.gate((): boolean => true, (): AppEnvironment | undefined => env);
      const me: CountingMe = new CountingMe();
      const wallet: CountingWallet = new CountingWallet();
      const mePort: MeContractPort = new GatedMeContractPort(me, gate);
      const walletPort: WalletContractPort = new GatedWalletContractPort(wallet, gate);
      expect((await mePort.updateNickname('n', (): boolean => true)).ok).assertTrue();
      expect((await walletPort.getLaborAgreement()).ok).assertTrue();
      expect(me.calls).assertEqual(1);
      expect(wallet.calls).assertEqual(1);
      // 端口在 test 环境拿到、之后切到 prod：同一个实例的每个方法都本地拒绝，替身一次都不调用。
      env = AppEnvironment.PROD;
      const results: ApiResult[] = [
        await mePort.updateNickname('n', (): boolean => true),
        await mePort.getNotificationSettings((): boolean => true),
        await mePort.putNotificationSettings(true, (): boolean => true),
        await walletPort.submitRealname('张三', '110101199001011234'),
        await walletPort.getLaborAgreement(),
        await walletPort.signLaborAgreement('v1', 'sha')
      ];
      for (const r of results) {
        expect(r.ok).assertFalse();
        expect(r.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        expect(r.localRejectReason).assertEqual(LocalRejectReason.SEND_BLOCKED);
      }
      expect(me.calls).assertEqual(1);
      expect(wallet.calls).assertEqual(1);
    });

    it('fx02_auth_webcode_push_and_pending_store_fall_back_to_real_in_prod', 0, async () => {
      let env: AppEnvironment | undefined = AppEnvironment.TEST;
      const gate: () => boolean = DebugSubstitutes.gate((): boolean => true, (): AppEnvironment | undefined => env);
      // 微信假适配器：test 可用；授权等待期间切到 prod，假凭证不交出；prod 下与 Release 一样不可用。
      const fakeAuth: FakeAuth = new FakeAuth();
      const auth: GatedAuthAdapter = new GatedAuthAdapter(fakeAuth, gate);
      expect(auth.adapterAvailable()).assertTrue();
      expect(auth.installed()).assertTrue();
      const pending: Promise<ThirdPartyAuthResult> = auth.authorize('nonce-1');
      env = AppEnvironment.PROD;
      fakeAuth.answer('nonce-1');
      expect((await pending).kind).assertEqual(ThirdPartyAuthKind.UNAVAILABLE);
      expect(auth.adapterAvailable()).assertFalse();
      expect(auth.installed()).assertNull();
      expect((await auth.authorize('nonce-2')).kind).assertEqual(ThirdPartyAuthKind.UNAVAILABLE);
      expect(fakeAuth.calls).assertEqual(1);
      // 淘宝 web_code 假授权。
      const fakeWeb: FakeWebCode = new FakeWebCode();
      const web: GatedWebCodeAuthorizer = new GatedWebCodeAuthorizer(fakeWeb, gate);
      expect(web.available()).assertFalse();
      expect((await web.authorize('https://auth.invalid', 's')).kind).assertEqual(AuthStepResult.FAILED);
      expect(fakeWeb.calls).assertEqual(0);
      env = AppEnvironment.TEST;
      expect(web.available()).assertTrue();
      expect((await web.authorize('https://auth.invalid', 's')).kind).assertEqual(AuthStepResult.CREDENTIAL);
      // 推送令牌：test 有令牌；切到 prod 后同一个来源不给令牌。
      const fakePush: FakePush = new FakePush();
      const push: GatedPushTokenSource = new GatedPushTokenSource(fakePush, gate);
      push.start();
      expect(push.current()).assertEqual('debug-push-token-1');
      env = AppEnvironment.PROD;
      expect(push.current()).assertNull();
      // 未决记录：test 写进内存；prod 下读写都走安全存储（真实路径），看不到内存里的假记录。
      env = AppEnvironment.TEST;
      const secure: MemoryPendingKeyBackend = new MemoryPendingKeyBackend();
      const memory: MemoryPendingKeyBackend = new MemoryPendingKeyBackend();
      const store: GatedPendingKeyBackend = new GatedPendingKeyBackend(secure, gate, memory);
      store.write(record('k-test'));
      expect(memory.list('user-1').length).assertEqual(1);
      expect(secure.list('user-1').length).assertEqual(0);
      env = AppEnvironment.PROD;
      expect(store.read('user-1', 'k-test')).assertNull();
      expect(store.list('user-1').length).assertEqual(0);
      store.write(record('k-prod'));
      expect(secure.list('user-1').length).assertEqual(1);
      expect(memory.list('user-1').length).assertEqual(1);
      store.clear();
      expect(secure.list('user-1').length + memory.list('user-1').length).assertEqual(0);
    });

    // ---------------------------------------------------------------- F-X-03
    it('fx03_withdraw_marker_published_cleaners_not_run_old_request_reads_and_sends_nothing', 0, async () => {
      const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
      gate.agree(0);
      let cleanupCalls: number = 0;
      // 清理器（含网络作废的清理前钩子）一个都不运行：只记下被发起。
      gate.withdrawalCleanup = (): void => {
        cleanupCalls++;
      };
      const tokens: CountingTokens = new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      const creds: CountingCredentials = new CountingCredentials();
      const rig: Rig = new Rig(null, null, null, null, null, creds, null, tokens, new PrivacyContext(gate));
      const held: HeldRequest = await startHeld(rig);
      expect(rig.server.received.length).assertEqual(1);
      expect(rig.timer.heldBackoffs).assertEqual(1);
      expect(held.result === null).assertTrue();
      // 发布撤回标记（基本模式 + 待清理已落盘）。AppRouting.privacyState 这时还没重新发布（仍是 full，最坏情况）。
      gate.withdraw(0);
      expect(gate.withdrawalCleanupPending).assertTrue();
      expect(cleanupCalls).assertEqual(1);
      const sends: number = rig.server.received.length;
      const tokenReads: number = tokens.reads;
      const credReads: number = creds.reads;
      // 恢复旧请求：凭据零读取、零发送，以取消收口。
      rig.timer.releaseBackoffs();
      await flush();
      expect(rig.server.received.length).assertEqual(sends);
      expect(tokens.reads).assertEqual(tokenReads);
      expect(creds.reads).assertEqual(credReads);
      expect(held.result !== null).assertTrue();
      expect((held.result as ApiResult).ok).assertFalse();
      expect((held.result as ApiResult).localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
    });

    it('fx03_switch_gate_closed_cleaners_not_run_old_request_reads_and_sends_nothing', 0, async () => {
      const switchGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      const tokens: CountingTokens = new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      const creds: CountingCredentials = new CountingCredentials();
      const rig: Rig = new Rig(null, null, null, null, null, creds, null, tokens, new SwitchContext(switchGate));
      // 不登记 onClosed → client.invalidate 的监听：只靠「闸门已关闭」这个已发布的状态本身。
      const cleaner: CountingCleaner = new CountingCleaner('session_tokens');
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      registry.register(cleaner);
      let hookRuns: number = 0;
      registry.setBeforeClear('network', (): void => {
        hookRuns++;
      });
      const record: HangingRecord = new HangingRecord();
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, switchTable(), registry, record,
        switchGate);
      const held: HeldRequest = await startHeld(rig);
      expect(rig.server.received.length).assertEqual(1);
      expect(rig.timer.heldBackoffs).assertEqual(1);
      // 开始切换：同步关闭闸门（switching 已对外可见），随后停在读环境记录的 await，清理器与清理前钩子都没运行。
      const switching: Promise<SwitchResult> = switcher.switchTo(AppEnvironment.STAGING);
      expect(switchGate.open).assertFalse();
      expect(record.gets).assertEqual(1);
      expect(hookRuns).assertEqual(0);
      expect(cleaner.runs).assertEqual(0);
      const sends: number = rig.server.received.length;
      const tokenReads: number = tokens.reads;
      const credReads: number = creds.reads;
      rig.timer.releaseBackoffs();
      await flush();
      expect(rig.server.received.length).assertEqual(sends);
      expect(tokens.reads).assertEqual(tokenReads);
      expect(creds.reads).assertEqual(credReads);
      expect(held.result !== null).assertTrue();
      expect((held.result as ApiResult).localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      expect(cleaner.runs).assertEqual(0);
      expect(switching !== null).assertTrue();
    });

    it('fx03_logout_session_ended_published_tokens_not_deleted_old_request_reads_and_sends_nothing', 0, async () => {
      const tokens: CountingTokens = new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      const creds: CountingCredentials = new CountingCredentials();
      const rig: Rig = new Rig(null, null, null, null, null, creds, null, tokens);
      const held: HeldRequest = await startHeld(rig);
      expect(rig.server.received.length).assertEqual(1);
      expect(rig.timer.heldBackoffs).assertEqual(1);
      // 退出登录的本地清除（LoginService.logout 回来后调用的同一个入口）：删除令牌的清理器不运行（令牌仍在存储里），
      // 「会话已结束」在 afterClear 里对外发布（App：Router.sessionEnded、页面换游客态）。
      tokens.clearEnabled = false;
      let published: number = 0;
      expect(rig.client.clearSessionIfEpoch(rig.client.loginEpoch(), (): void => {
        published++;
      })).assertTrue();
      expect(published).assertEqual(1);
      expect(tokens.inner.accessToken()).assertEqual('old-access');
      const sends: number = rig.server.received.length;
      const tokenReads: number = tokens.reads;
      const credReads: number = creds.reads;
      rig.timer.releaseBackoffs();
      await flush();
      expect(rig.server.received.length).assertEqual(sends);
      expect(tokens.reads).assertEqual(tokenReads);
      expect(creds.reads).assertEqual(credReads);
      expect(held.result !== null).assertTrue();
      expect((held.result as ApiResult).localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
    });

    // ---------------------------------------------------------------- 第 2 轮评审修复
    it('r2_01_switch_window_real_device_registry_and_tracker_read_nothing', 0, async () => {
      for (const preloaded of [false, true]) {
        const switchGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
        const d: DeviceRig = new DeviceRig(new SwitchContext(switchGate), switchGate);
        const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
        const cleaner: CountingCleaner = new CountingCleaner('device_identity');
        registry.register(cleaner);
        NetworkComposition.install(d.rig.client, registry, (): void => {
        }, switchGate);
        if (preloaded) {
          // 切换前已读过一次：缓存里有旧凭据（评审复现里「已加载时仍返回旧凭据」的情形）。
          expect(d.registry.deviceId()).assertEqual('device-a');
          expect(d.store.reads).assertEqual(1);
        } else {
          expect(d.store.reads).assertEqual(0);
        }
        const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, switchTable(), registry,
          new HangingRecord(), switchGate);
        switcher.switchTo(AppEnvironment.STAGING);
        // 闸门已关闭、invalidate 已执行，环境记录读取挂起，清理器没运行。
        expect(switchGate.open).assertFalse();
        expect(cleaner.runs).assertEqual(0);
        const tokenReads: number = d.tokens.reads;
        await expectDeviceReadsNothing(d);
        expect(d.tokens.reads).assertEqual(tokenReads);
      }
    });

    it('r2_01_withdraw_window_real_device_registry_and_tracker_read_nothing', 0, async () => {
      for (const preloaded of [false, true]) {
        const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
        gate.agree(0);
        // registry 自己的隐私口径保持 consented（只靠统一判定里的撤回清理状态拦下）。
        const d: DeviceRig = new DeviceRig(new PrivacyContext(gate), null);
        const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
        const cleaner: HangingCleaner = new HangingCleaner('device_identity');
        registry.register(cleaner);
        NetworkComposition.install(d.rig.client, registry, (): void => {
        }, new EnvironmentSwitchGate());
        gate.withdrawalCleanup = (): void => {
          registry.cleanOnly(['device_identity']);
        };
        if (preloaded) {
          expect(d.registry.deviceId()).assertEqual('device-a');
          expect(d.store.reads).assertEqual(1);
        }
        gate.withdraw(0);
        // 撤回标记已写、invalidate 已执行，设备身份清理挂起（存储里仍有旧凭据）。
        expect(gate.withdrawalCleanupPending).assertTrue();
        expect(cleaner.runs).assertEqual(1);
        expect(d.store.deviceId).assertEqual('device-a');
        const tokenReads: number = d.tokens.reads;
        await expectDeviceReadsNothing(d);
        expect(d.tokens.reads).assertEqual(tokenReads);
      }
    });

    it('r2_01_control_ready_reads_normally_and_resume_after_switch_completes', 0, async () => {
      const switchGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      const d: DeviceRig = new DeviceRig(new SwitchContext(switchGate), switchGate);
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      NetworkComposition.install(d.rig.client, registry, (): void => {
      }, switchGate);
      // 就绪：照常读取（第一次读存储，之后用缓存），埋点带 device_id 入队，签名请求带 device_id。
      expect(d.registry.credentialsReadable()).assertTrue();
      expect(d.registry.deviceId()).assertEqual('device-a');
      expect(d.registry.installSecret()).assertEqual('test-only.install.device-a');
      expect(d.registry.registered).assertTrue();
      expect(d.store.reads).assertEqual(1);
      expect(d.tracker.track(ClientEvents.appLaunch('Home'))).assertTrue();
      expect(d.tracker.queueSize).assertEqual(1);
      expect(await d.registry.register()).assertTrue();
      expect(d.devicesSent()).assertEqual(0);
      const r: ApiResult = await d.rig.client.request(new ApiRequest('getMe'));
      expect(r.ok).assertTrue();
      const sent: TransportRequest = d.rig.server.received[d.rig.server.received.length - 1];
      expect(sent.headers[NetworkHeaders.DEVICE_ID]).assertEqual('device-a');
      // 切换走完（闸门重新打开）后恢复读取（本例没登记设备身份清理项，凭据仍在）。
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, switchTable(), registry,
        new ImmediateRecord(), switchGate);
      const result: SwitchResult = await switcher.switchTo(AppEnvironment.STAGING);
      expect(result !== null).assertTrue();
      expect(switchGate.open).assertTrue();
      expect(d.registry.deviceId()).assertEqual('device-a');
      expect(d.tracker.track(ClientEvents.appLaunch('Home'))).assertTrue();
      expect(d.tracker.queueSize).assertEqual(2);
      // 撤回清理完成、重新同意后也恢复读取。
      const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
      gate.agree(0);
      const w: DeviceRig = new DeviceRig(new PrivacyContext(gate), null);
      gate.withdraw(0);
      expect(w.registry.deviceId()).assertNull();
      expect(w.store.reads).assertEqual(0);
      gate.withdrawalCleanupDone();
      gate.agree(0);
      expect(gate.withdrawalCleanupPending).assertFalse();
      expect(w.registry.deviceId()).assertEqual('device-a');
      expect(w.store.reads).assertEqual(1);
    });

    it('r2_02_unsettled_confirm_and_abandon_keep_head_reject_reasons_with_zero_reads', 0, async () => {
      const cases: PendingCase[] = [PendingCase.VALID, PendingCase.MISSING, PendingCase.GUEST, PendingCase.MISMATCH];
      for (const c of cases) {
        for (const abandon of [false, true]) {
          // 基线：同一场景、环境就绪时的本地结论（有效记录会真的发出去，不比；其余三种与 HEAD 相同的本地核对）。
          if (c !== PendingCase.VALID) {
            const settled: PendingScenario = new PendingScenario(c);
            const base: ApiResult = await settled.call(abandon);
            expect(base.localRejectReason).assertEqual(headReason(c));
          }
          const s: PendingScenario = new PendingScenario(c);
          s.startSwitch();
          const tokenReads: number = s.tokens.reads;
          const credReads: number = s.creds.reads;
          const sends: number = s.rig.server.received.length;
          const r: ApiResult = await s.call(abandon);
          expect(r.ok).assertFalse();
          expect(r.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
          // 与 HEAD 逐项相同。
          expect(r.localRejectReason).assertEqual(headReason(c));
          // 零凭据读取、零发送；有效记录没被改成在途（结果仍未知，可在环境就绪后再确认 / 放弃）。
          expect(s.tokens.reads).assertEqual(tokenReads);
          expect(s.creds.reads).assertEqual(credReads);
          expect(s.rig.server.received.length).assertEqual(sends);
          const kept: PendingKeyRecord | null = s.rig.pendingBackend.read('user-1', PENDING_KEY);
          if (c === PendingCase.MISSING) {
            expect(kept).assertNull();
          } else {
            expect(kept !== null && kept.stateRaw === 'unknown').assertTrue();
          }
        }
      }
    });

    it('r2_02_unsettled_binding_dropped_after_cleanup_or_external_session_change', 0, async () => {
      // 切换的清理器已把未决存储整体清掉（令牌一并清除）而环境仍未就绪：已绑定的归属不再沿用，按游客（HEAD：令牌已清 → account_unknown）。
      const s: PendingScenario = new PendingScenario(PendingCase.VALID);
      s.startSwitch();
      s.rig.pending.resetAfterClear();
      s.tokens.inner.clear();
      const tokenReads: number = s.tokens.reads;
      expect((await s.call(false)).localRejectReason).assertEqual(LocalRejectReason.ACCOUNT_UNKNOWN);
      expect((await s.call(true)).localRejectReason).assertEqual(LocalRejectReason.ACCOUNT_UNKNOWN);
      expect(s.tokens.reads).assertEqual(tokenReads);
      // 撤回同意的作废也丢掉绑定；环境未就绪本身不丢（切换的 invalidate 之后仍按 user-1 判定，见上一个用例）。
      const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
      gate.agree(0);
      const ctx: PrivacyContext = new PrivacyContext(gate);
      const tokens: CountingTokens = new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      const rig: Rig = new Rig(null, null, null, null, null, new CountingCredentials(), null, tokens, ctx);
      rig.pendingBackend.write(new PendingKeyRecord(PENDING_KEY, 'createWithdrawal', '{}', 'summary', 'user-1', 0,
        'unknown', true));
      rig.pending.restore('user-1');
      rig.client.pendingState(PENDING_KEY);
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      registry.register(new HangingCleaner('session_tokens'));
      NetworkComposition.install(rig.client, registry, (): void => {
      }, new EnvironmentSwitchGate());
      gate.withdrawalCleanup = (): void => {
        registry.cleanOnly(['session_tokens']);
      };
      gate.withdraw(0);
      gate.withdrawalCleanupDone();
      gate.agree(0);
      expect(gate.withdrawalCleanupPending).assertFalse();
      // 撤回清理完成、重新同意，但环境此刻未定：不沿用撤回前的绑定。
      ctx.settled = false;
      const reads: number = tokens.reads;
      expect((await rig.client.confirmPending(PENDING_KEY)).localRejectReason).assertEqual(LocalRejectReason.ACCOUNT_UNKNOWN);
      expect(tokens.reads).assertEqual(reads);
    });

    // ---------------------------------------------------------------- 第 1 轮评审修复
    it('r1_01_switch_invalidated_cleanup_not_started_new_request_and_session_queries_read_nothing', 0, async () => {
      const switchGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      const tokens: CountingTokens = new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      const creds: CountingCredentials = new CountingCredentials();
      const rig: Rig = new Rig(null, null, null, null, null, creds, null, tokens, new SwitchContext(switchGate));
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      const cleaner: CountingCleaner = new CountingCleaner('session_tokens');
      registry.register(cleaner);
      // 真实接线：清理前第一步与闸门关闭都接到 ApiClient.invalidate。
      NetworkComposition.install(rig.client, registry, (): void => {
      }, switchGate);
      // 切换前一切正常：会话可读（会话查询同时绑定了会话归属 user-1）。
      expect(rig.client.sessionReadable()).assertTrue();
      expect(rig.client.sessionAccount()).assertEqual('user-1');
      const epochBefore: number = rig.client.loginEpoch();
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, switchTable(), registry,
        new HangingRecord(), switchGate);
      const switching: Promise<SwitchResult> = switcher.switchTo(AppEnvironment.STAGING);
      // invalidate 已执行（闸门关闭时同步通知），清理还没开始（停在读环境记录）。
      expect(rig.client.loginEpoch() !== epochBefore).assertTrue();
      expect(cleaner.runs).assertEqual(0);
      const sends: number = rig.server.received.length;
      const tokenReads: number = tokens.reads;
      const credReads: number = creds.reads;
      const results: ApiResult[] = await queryEverything(rig);
      // 原有拒绝原因不变：新请求环境未定 → environment_unsettled；确认 / 放弃一个不存在的 k-1 → pending_key_unresolved
      // （R2-02：与 HEAD 相同；有效记录的 environment_unsettled 见 r2_02 用例）。
      for (const r of results) {
        expect(r.ok).assertFalse();
      }
      expect(results[0].localRejectReason).assertEqual(LocalRejectReason.ENVIRONMENT_UNSETTLED);
      expect(results[1].localRejectReason).assertEqual(LocalRejectReason.ENVIRONMENT_UNSETTLED);
      expect(results[2].localRejectReason).assertEqual(LocalRejectReason.PENDING_KEY_UNRESOLVED);
      expect(results[3].localRejectReason).assertEqual(LocalRejectReason.PENDING_KEY_UNRESOLVED);
      expect(tokens.reads).assertEqual(tokenReads);
      expect(creds.reads).assertEqual(credReads);
      expect(rig.server.received.length).assertEqual(sends);
      expect(switching !== null).assertTrue();
    });

    it('r1_01_withdraw_invalidated_cleanup_not_started_new_request_and_session_queries_read_nothing', 0, async () => {
      const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
      gate.agree(0);
      const tokens: CountingTokens = new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      const creds: CountingCredentials = new CountingCredentials();
      const rig: Rig = new Rig(null, null, null, null, null, creds, null, tokens, new PrivacyContext(gate));
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      const cleaner: HangingCleaner = new HangingCleaner('session_tokens');
      registry.register(cleaner);
      NetworkComposition.install(rig.client, registry, (): void => {
      }, new EnvironmentSwitchGate());
      // 真实撤回：标记落盘 → cleanOnly 同步跑清理前钩子（invalidate）→ 令牌清理挂起。
      gate.withdrawalCleanup = (): void => {
        registry.cleanOnly(['session_tokens']);
      };
      const epochBefore: number = rig.client.loginEpoch();
      gate.withdraw(0);
      expect(rig.client.loginEpoch() !== epochBefore).assertTrue();
      expect(cleaner.runs).assertEqual(1);
      const sends: number = rig.server.received.length;
      const tokenReads: number = tokens.reads;
      const credReads: number = creds.reads;
      const results: ApiResult[] = await queryEverything(rig);
      // 原有拒绝原因：新请求 credentials_unreadable；确认 / 放弃上一笔 account_unknown（不读会话就没有可信账号）。
      expect(results[0].localRejectReason).assertEqual(LocalRejectReason.CREDENTIALS_UNREADABLE);
      expect(results[1].localRejectReason).assertEqual(LocalRejectReason.CREDENTIALS_UNREADABLE);
      expect(results[2].localRejectReason).assertEqual(LocalRejectReason.ACCOUNT_UNKNOWN);
      expect(results[3].localRejectReason).assertEqual(LocalRejectReason.ACCOUNT_UNKNOWN);
      expect(tokens.reads).assertEqual(tokenReads);
      expect(creds.reads).assertEqual(credReads);
      expect(rig.server.received.length).assertEqual(sends);
    });

    it('r1_02_real_logout_cancelled_by_env_switch_resumes_without_reading_tokens', 0, async () => {
      const switchGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      const tokens: CountingTokens = new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      const creds: CountingCredentials = new CountingCredentials();
      const rig: Rig = new Rig(null, null, null, null, null, creds, null, tokens, new SwitchContext(switchGate));
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      const cleaner: CountingCleaner = new CountingCleaner('session_tokens');
      registry.register(cleaner);
      NetworkComposition.install(rig.client, registry, (): void => {
      }, switchGate);
      // logout 请求一直挂起（等服务端）。
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      new Promise<TransportResponse>((_resolve: (v: TransportResponse) => void): void => {
      });
      const host: RecordingHost = new RecordingHost();
      const service: LoginService = new LoginService(rig.client, tokens, host);
      const done: Box = new Box();
      service.logout().then((v: boolean): void => {
        done.value = v;
      });
      await flush();
      expect(rig.server.received.length).assertEqual(1);
      expect(done.value === null).assertTrue();
      const sends: number = rig.server.received.length;
      // 切换开始：闸门关闭 → invalidate 取消 logout；环境记录读取挂起，清理器没运行。
      const switcher: EnvironmentSwitcher = new EnvironmentSwitcher(AppEnvironment.TEST, switchTable(), registry,
        new HangingRecord(), switchGate);
      const switching: Promise<SwitchResult> = switcher.switchTo(AppEnvironment.STAGING);
      const tokenReads: number = tokens.reads;
      const credReads: number = creds.reads;
      await flush();
      expect(done.value === false).assertTrue();
      expect(tokens.reads).assertEqual(tokenReads);
      expect(creds.reads).assertEqual(credReads);
      expect(rig.server.received.length).assertEqual(sends);
      // 登录世代已变：不删、不发布「已退出」，只通知会话变化；令牌留给切换的清理器。
      expect(host.calls.indexOf('sessionEnded')).assertEqual(-1);
      expect(host.calls.indexOf('sessionChanged') >= 0).assertTrue();
      expect(tokens.inner.accessToken()).assertEqual('old-access');
      expect(cleaner.runs).assertEqual(0);
      expect(switching !== null).assertTrue();
    });

    it('r1_02_real_logout_cancelled_by_withdraw_resumes_without_reading_tokens', 0, async () => {
      const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
      gate.agree(0);
      const tokens: CountingTokens = new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      const creds: CountingCredentials = new CountingCredentials();
      const rig: Rig = new Rig(null, null, null, null, null, creds, null, tokens, new PrivacyContext(gate));
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      const cleaner: HangingCleaner = new HangingCleaner('session_tokens');
      registry.register(cleaner);
      NetworkComposition.install(rig.client, registry, (): void => {
      }, new EnvironmentSwitchGate());
      gate.withdrawalCleanup = (): void => {
        registry.cleanOnly(['session_tokens']);
      };
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      new Promise<TransportResponse>((_resolve: (v: TransportResponse) => void): void => {
      });
      const host: RecordingHost = new RecordingHost();
      const service: LoginService = new LoginService(rig.client, tokens, host);
      const done: Box = new Box();
      service.logout().then((v: boolean): void => {
        done.value = v;
      });
      await flush();
      expect(rig.server.received.length).assertEqual(1);
      expect(done.value === null).assertTrue();
      // 撤回：标记落盘、清理前钩子 invalidate 取消 logout，令牌清理挂起。
      gate.withdraw(0);
      const tokenReads: number = tokens.reads;
      const credReads: number = creds.reads;
      await flush();
      expect(done.value === false).assertTrue();
      expect(tokens.reads).assertEqual(tokenReads);
      expect(creds.reads).assertEqual(credReads);
      expect(rig.server.received.length).assertEqual(1);
      expect(host.calls.indexOf('sessionEnded')).assertEqual(-1);
      expect(cleaner.runs).assertEqual(1);
    });

    it('r1_02_guarded_clear_entry_checks_epoch_then_readability_before_reading', 0, () => {
      const switchGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      const tokens: CountingTokens = new CountingTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      const rig: Rig = new Rig(null, null, null, null, null, null, null, tokens, new SwitchContext(switchGate));
      // 世代不符：零读取，返回 false，不清。
      let before: number = tokens.reads;
      expect(rig.client.clearOwnedSession(rig.client.loginEpoch() - 1, (_p: boolean): void => {
      })).assertFalse();
      expect(tokens.reads).assertEqual(before);
      expect(tokens.inner.accessToken()).assertEqual('old-access');
      // 世代相符但闸门关闭（未登记 invalidate，只有状态）：不读，按原会话已被别处清除（false）交给出口，照常清。
      switchGate.close();
      before = tokens.reads;
      const present: Box = new Box();
      expect(rig.client.clearOwnedSession(rig.client.loginEpoch(), (p: boolean): void => {
        present.value = p;
      })).assertTrue();
      expect(tokens.reads).assertEqual(before);
      expect(present.value === false).assertTrue();
      expect(tokens.inner.accessToken()).assertNull();
      // 对照：可读时读出原会话还在。
      const rig2: Rig = new Rig();
      const present2: Box = new Box();
      expect(rig2.client.clearOwnedSession(rig2.client.loginEpoch(), (p: boolean): void => {
        present2.value = p;
      })).assertTrue();
      expect(present2.value === true).assertTrue();
    });

    it('r1_03_home_port_held_from_test_rejects_in_prod_per_call_and_on_return', 0, async () => {
      let env: AppEnvironment | undefined = AppEnvironment.TEST;
      const gate: () => boolean = DebugSubstitutes.gate((): boolean => true, (): AppEnvironment | undefined => env);
      const fake: SlowHome = new SlowHome();
      const port: HomeContractPort | null = HomeDebugSources.guarded(gate, fake);
      expect(port !== null).assertTrue();
      const p: HomeContractPort = port as HomeContractPort;
      // test：正常交付。
      const ok: Results = new Results();
      collect(ok, p.getPage('home', false, (): boolean => true));
      await flush();
      fake.pending.answerAll();
      await flush();
      expect(ok.list.length).assertEqual(1);
      expect(ok.list[0].ok).assertTrue();
      // 等待期间切到 prod：假页面、假商品不交出。
      const waiting: Results = new Results();
      collect(waiting, p.getPage('home', false, (): boolean => true));
      collect(waiting, p.listSectionItems('home', 's1', null, false, (): boolean => true));
      await flush();
      expect(fake.pending.waiting).assertEqual(2);
      env = AppEnvironment.PROD;
      fake.pending.answerAll();
      await flush();
      expect(waiting.list.length).assertEqual(2);
      for (const r of waiting.list) {
        expectBlocked(r);
      }
      // 持有旧实例、切到 prod 之后再调用：本地拒绝，替身一次都不调用。
      const calls: number = fake.calls;
      expectBlocked(await p.getPage('home', false, (): boolean => true));
      expectBlocked(await p.listSectionItems('home', 's1', 'c1', true, (): boolean => true));
      expect(fake.calls).assertEqual(calls);
      // cancel 照常转交；prod 下取不到新实例。
      p.cancel(7);
      expect(fake.cancels.length).assertEqual(1);
      expect(HomeDebugSources.guarded(gate, fake) === null).assertTrue();
      env = undefined;
      expect(HomeDebugSources.guarded(gate, fake) === null).assertTrue();
      const direct: GatedHomeContractPort = new GatedHomeContractPort(fake, gate);
      expectBlocked(await direct.getPage('home', false, (): boolean => true));
    });

    it('r1_04_contract_ports_switching_to_prod_while_waiting_deliver_no_fake_result', 0, async () => {
      let env: AppEnvironment | undefined = AppEnvironment.TEST;
      const gate: () => boolean = DebugSubstitutes.gate((): boolean => true, (): AppEnvironment | undefined => env);
      const me: SlowMe = new SlowMe();
      const wallet: SlowWallet = new SlowWallet();
      const mePort: MeContractPort = new GatedMeContractPort(me, gate);
      const walletPort: WalletContractPort = new GatedWalletContractPort(wallet, gate);
      // 读、写各三个，全部在 test 发起、在等待期间切到 prod。
      const results: Results = new Results();
      collect(results, mePort.getNotificationSettings((): boolean => true));
      collect(results, mePort.putNotificationSettings(true, (): boolean => true));
      collect(results, mePort.updateNickname('n', (): boolean => true));
      collect(results, walletPort.getLaborAgreement());
      collect(results, walletPort.signLaborAgreement('v1', 'sha'));
      collect(results, walletPort.submitRealname('张三', '110101199001011234'));
      await flush();
      expect(me.pending.waiting).assertEqual(3);
      expect(wallet.pending.waiting).assertEqual(3);
      env = AppEnvironment.PROD;
      me.pending.answerAll();
      wallet.pending.answerAll();
      await flush();
      expect(results.list.length).assertEqual(6);
      for (const r of results.list) {
        expectBlocked(r);
      }
      // 对照：一直在 test 时照常交付。
      env = AppEnvironment.TEST;
      const ok: Results = new Results();
      collect(ok, mePort.getNotificationSettings((): boolean => true));
      collect(ok, walletPort.getLaborAgreement());
      await flush();
      me.pending.answerAll();
      wallet.pending.answerAll();
      await flush();
      expect(ok.list.length).assertEqual(2);
      expect(ok.list[0].ok && ok.list[1].ok).assertTrue();
    });

    it('r1_05_debug_clip_share_deferred_until_settled_then_gated', 0, () => {
      let ready: boolean = false;
      let env: AppEnvironment | undefined = undefined;
      const gate: () => boolean = DebugSubstitutes.gate((): boolean => true, (): AppEnvironment | undefined => env);
      const deferral: DebugLaunchDeferral = new DebugLaunchDeferral((): boolean => ready, gate);
      const ran: string[] = [];
      // 冷启动：环境还没定，先暂存（同名后到的覆盖），一个都不执行；就绪之前 settle 不动。
      expect(deferral.submit('clip', (): void => {
        ran.push('clip-a');
      })).assertEqual(DebugLaunchDeferral.DEFERRED);
      expect(deferral.submit('clip', (): void => {
        ran.push('clip-b');
      })).assertEqual(DebugLaunchDeferral.DEFERRED);
      expect(deferral.submit('share', (): void => {
        ran.push('share');
      })).assertEqual(DebugLaunchDeferral.DEFERRED);
      expect(deferral.settle()).assertEqual(0);
      expect(ran.length).assertEqual(0);
      expect(deferral.pendingCount).assertEqual(2);
      // 环境定为 prod：一次性丢弃。
      ready = true;
      env = AppEnvironment.PROD;
      expect(deferral.settle()).assertEqual(0);
      expect(ran.length).assertEqual(0);
      expect(deferral.pendingCount).assertEqual(0);
      // 已就绪的 prod 下直接提交：丢弃。
      expect(deferral.submit('clip', (): void => {
        ran.push('clip-prod');
      })).assertEqual(DebugLaunchDeferral.DROPPED);
      expect(ran.length).assertEqual(0);
      // 非 prod 的截图流程：冷启动暂存，环境定为 test 后执行（只执行最后一次的样例）。
      ready = false;
      env = undefined;
      deferral.submit('clip', (): void => {
        ran.push('clip-a');
      });
      deferral.submit('clip', (): void => {
        ran.push('clip-b');
      });
      ready = true;
      env = AppEnvironment.TEST;
      expect(deferral.settle()).assertEqual(1);
      expect(ran.join(',')).assertEqual('clip-b');
      expect(deferral.submit('share', (): void => {
        ran.push('share-now');
      })).assertEqual(DebugLaunchDeferral.RUN);
      expect(ran.join(',')).assertEqual('clip-b,share-now');
      // 分享的定时回调：到点时再核对一次闸门。
      const fires: (() => void)[] = [];
      const schedule: (fire: () => void, ms: number) => void = (fire: () => void, _ms: number): void => {
        fires.push(fire);
      };
      let shared: number = 0;
      DebugLaunchDeferral.delayed(gate, 600, (): void => {
        shared++;
      }, schedule);
      DebugLaunchDeferral.delayed(gate, 600, (): void => {
        shared++;
      }, schedule);
      fires[0]();
      expect(shared).assertEqual(1);
      env = AppEnvironment.PROD;
      fires[1]();
      expect(shared).assertEqual(1);
    });
  });
}
