// Debug / Staging（core 模块 staging target）：传输入口以外的调试替身统一过同一道环境闸门（F-X-02，APP-11 rule-gaps H26）。
// 只在 product=staging 编译，由 src/staging/ets/config/DebugOnly.ets 导出；Release 没有本文件。
// 早于 APP-11 的替身（钱包、「我的」的契约端口，微信适配器，淘宝 web_code 授权，推送令牌，未决记录的内存存储，以及截图覆盖值）
// 原来只看「本机假服务已打开」。这里把它们统一改成「假服务打开 且 当前环境允许 MOCK_DATA」（DebugMockGate.allowed），
// 并且每次使用时重新判断：替身在 test 环境创建、之后切到 prod，同一个实例也立即走真实路径或返回空，不给假数据。
import { AppEnvironment } from '../../../main/ets/config/AppEnvironment';
import { HomeContractPort } from '../../../main/ets/home/HomeController';
import { ThirdPartyAuthAdapter, ThirdPartyAuthKind, ThirdPartyAuthResult } from '../../../main/ets/login/OAuthLoginService';
import { MeContractPort } from '../../../main/ets/me/MeSession';
import { ApiResult } from '../../../main/ets/network/ApiClient';
import { LocalRejectReason } from '../../../main/ets/network/NetworkPolicy';
import { MemoryPendingKeyBackend, PendingKeyBackend, PendingKeyRecord } from '../../../main/ets/network/PendingKeyStore';
import { PushTokenSource } from '../../../main/ets/push/PushReport';
import { AuthStepResult, WebCodeAuthorizer } from '../../../main/ets/trade/TradeServices';
import { WalletContractPort } from '../../../main/ets/wallet/WalletSession';
import { DebugMockGate } from './DebugMockTransport';

/** 替身闸门的构造与取值（entry 的 DebugFakeServer.mockGate 用它建出进程内唯一的闸门）。 */
export class DebugSubstitutes {
  /**
   * 每次调用都重新判断的闸门：假服务打开 且 当前环境允许 MOCK_DATA（环境未定、prod 一律不放行）。读取出错按不放行。
   * environment 缺省读进程当前环境（AppConfig）；单测注入。
   */
  static gate(enabled: () => boolean,
    environment: () => AppEnvironment | undefined = (): AppEnvironment | undefined => DebugMockGate.currentEnvironment()):
    () => boolean {
    return (): boolean => {
      try {
        return DebugMockGate.allowed(enabled(), environment());
      } catch (e) {
        return false;
      }
    };
  }

  /**
   * 只看环境的闸门（FU-HM-0720，APP-05b 共性 24，iOS R1-06）：当前环境允许 MOCK_DATA（环境已定且不是 prod）即放行，不要求本机假服务打开。
   * 只给第三方登录的假授权器用：Debug / Staging 默认显示第三方按钮并走假授权（凭证只交给当前非 prod 环境，本机假服务没开时由该环境按错误表拒绝）；
   * prod、环境未定照旧关闭（F-X-02）。
   */
  static environmentGate(
    environment: () => AppEnvironment | undefined = (): AppEnvironment | undefined => DebugMockGate.currentEnvironment()):
    () => boolean {
    return DebugSubstitutes.gate((): boolean => true, environment);
  }

  /** 闸门放行时取替身值，否则取真实值（与 Release 相同；没有真实实现的为 null）。 */
  static choose<T>(gate: () => boolean, fake: T, real: T): T {
    return gate() ? fake : real;
  }

  /**
   * 契约替身的一次调用（FU-HM-0711b R1-04）：调用前核对闸门，关闭时本地拒绝、不调用替身；替身的结果交付前再核对一次——等待期间
   * 切到 prod（或环境未定、假服务关闭），假结果不交出，同样本地拒绝（读、写都一样）。替身抛错或失败原样交回（不是假数据）。
   */
  static deliver(gate: () => boolean, call: () => Promise<ApiResult>): Promise<ApiResult> {
    if (!gate()) {
      return Promise.resolve(DebugSubstitutes.blocked());
    }
    return call().then((r: ApiResult): ApiResult => gate() ? r : DebugSubstitutes.blocked());
  }

  static blocked(): ApiResult {
    return ApiResult.rejected(LocalRejectReason.SEND_BLOCKED);
  }
}

/**
 * 改昵称与通知设置的待定接口（APP-12 G01、G02）：闸门关闭时与 Release 一样不发请求（本地拒绝），不调用替身；替身结果交付前再核对
 * 一次（R1-04：等待期间切到 prod 不交出假结果）。
 */
export class GatedMeContractPort implements MeContractPort {
  private readonly fake: MeContractPort;
  private readonly gate: () => boolean;

  constructor(fake: MeContractPort, gate: () => boolean) {
    this.fake = fake;
    this.gate = gate;
  }

  updateNickname(nickname: string, sendAllowed: () => boolean): Promise<ApiResult> {
    return DebugSubstitutes.deliver(this.gate, (): Promise<ApiResult> => this.fake.updateNickname(nickname, sendAllowed));
  }

  getNotificationSettings(sendAllowed: () => boolean): Promise<ApiResult> {
    return DebugSubstitutes.deliver(this.gate, (): Promise<ApiResult> => this.fake.getNotificationSettings(sendAllowed));
  }

  putNotificationSettings(service: boolean, sendAllowed: () => boolean): Promise<ApiResult> {
    return DebugSubstitutes.deliver(this.gate, (): Promise<ApiResult> => this.fake.putNotificationSettings(service, sendAllowed));
  }
}

/** 实名提交与劳务协议的待定接口（APP-09 G01、G02）：闸门关闭时本地拒绝，不调用替身；交付前再核对一次（R1-04）。 */
export class GatedWalletContractPort implements WalletContractPort {
  private readonly fake: WalletContractPort;
  private readonly gate: () => boolean;

  constructor(fake: WalletContractPort, gate: () => boolean) {
    this.fake = fake;
    this.gate = gate;
  }

  submitRealname(name: string, idNo: string): Promise<ApiResult> {
    return DebugSubstitutes.deliver(this.gate, (): Promise<ApiResult> => this.fake.submitRealname(name, idNo));
  }

  getLaborAgreement(): Promise<ApiResult> {
    return DebugSubstitutes.deliver(this.gate, (): Promise<ApiResult> => this.fake.getLaborAgreement());
  }

  signLaborAgreement(version: string, textSha256: string): Promise<ApiResult> {
    return DebugSubstitutes.deliver(this.gate, (): Promise<ApiResult> => this.fake.signLaborAgreement(version, textSha256));
  }
}

/** 微信登录的假适配器（APP-05b）：闸门关闭时与 Release 的 UnavailableWechatAdapter 相同（不可用、检测不了、拉不起）。 */
export class GatedAuthAdapter implements ThirdPartyAuthAdapter {
  readonly provider: string;
  private readonly fake: ThirdPartyAuthAdapter;
  private readonly gate: () => boolean;

  constructor(fake: ThirdPartyAuthAdapter, gate: () => boolean) {
    this.fake = fake;
    this.gate = gate;
    this.provider = fake.provider;
  }

  adapterAvailable(): boolean {
    return this.gate() && this.fake.adapterAvailable();
  }

  installed(): boolean | null {
    return this.gate() ? this.fake.installed() : null;
  }

  /** 授权回来时再核对一次：等待期间切到了 prod，假凭证不交出。 */
  authorize(nonce: string): Promise<ThirdPartyAuthResult> {
    if (!this.gate()) {
      return Promise.resolve(ThirdPartyAuthResult.of(ThirdPartyAuthKind.UNAVAILABLE));
    }
    return this.fake.authorize(nonce).then((r: ThirdPartyAuthResult): ThirdPartyAuthResult =>
      this.gate() ? r : ThirdPartyAuthResult.of(ThirdPartyAuthKind.UNAVAILABLE));
  }
}

/** 淘宝 web_code 假授权（APP-06b）：闸门关闭时与 Release 的 UnavailableWebCodeAuthorizer 相同。 */
export class GatedWebCodeAuthorizer implements WebCodeAuthorizer {
  private readonly fake: WebCodeAuthorizer;
  private readonly gate: () => boolean;

  constructor(fake: WebCodeAuthorizer, gate: () => boolean) {
    this.fake = fake;
    this.gate = gate;
  }

  available(): boolean {
    return this.gate() && this.fake.available();
  }

  authorize(authUrl: string, state: string): Promise<AuthStepResult> {
    if (!this.gate()) {
      return Promise.resolve(new AuthStepResult(AuthStepResult.FAILED));
    }
    return this.fake.authorize(authUrl, state).then((r: AuthStepResult): AuthStepResult =>
      this.gate() ? r : new AuthStepResult(AuthStepResult.FAILED));
  }
}

/** 推送令牌的 Debug 假来源（APP-12 G17）：闸门关闭时与 Release 的 NoPushTokenSource 一样没有令牌。 */
export class GatedPushTokenSource implements PushTokenSource {
  private readonly fake: PushTokenSource;
  private readonly gate: () => boolean;

  constructor(fake: PushTokenSource, gate: () => boolean) {
    this.fake = fake;
    this.gate = gate;
  }

  start(): void {
    this.fake.start();
  }

  stop(): void {
    this.fake.stop();
  }

  current(): string | null {
    return this.gate() ? this.fake.current() : null;
  }

  subscribe(listener: () => void): () => void {
    return this.fake.subscribe(listener);
  }
}

/**
 * 未决记录的存储（APP-05b，模拟器的 Asset 不支持批量查询）：闸门放行时放内存，否则与 Release 一样用安全存储。每次调用重新选；
 * clear 两边都清（切换环境时）。
 */
export class GatedPendingKeyBackend implements PendingKeyBackend {
  private readonly secure: PendingKeyBackend;
  private readonly memory: PendingKeyBackend;
  private readonly gate: () => boolean;

  constructor(secure: PendingKeyBackend, gate: () => boolean, memory: PendingKeyBackend = new MemoryPendingKeyBackend()) {
    this.secure = secure;
    this.gate = gate;
    this.memory = memory;
  }

  private pick(): PendingKeyBackend {
    return this.gate() ? this.memory : this.secure;
  }

  read(account: string, key: string): PendingKeyRecord | null {
    return this.pick().read(account, key);
  }

  list(account: string): PendingKeyRecord[] {
    return this.pick().list(account);
  }

  write(record: PendingKeyRecord): void {
    this.pick().write(record);
  }

  remove(account: string, key: string): void {
    this.pick().remove(account, key);
  }

  clear(): void {
    this.memory.clear();
    this.secure.clear();
  }
}

/**
 * 首页待定接口（getPage、listSectionItems）的替身（FU-HM-0711b R1-03）：普通首页与 HomePreview 共用。每次调用前、替身结果交付前都
 * 核对闸门——在 test 环境拿到的实例，切到 prod 后调用一律本地拒绝、不调用替身；等待期间切到 prod，假页面、假商品不交出。
 * cancel 原样转交（只作废替身里的在途请求，不产生数据）。
 */
export class GatedHomeContractPort implements HomeContractPort {
  private readonly fake: HomeContractPort;
  private readonly gate: () => boolean;

  constructor(fake: HomeContractPort, gate: () => boolean) {
    this.fake = fake;
    this.gate = gate;
  }

  getPage(pageKey: string, anonymous: boolean, sendAllowed: () => boolean): Promise<ApiResult> {
    return DebugSubstitutes.deliver(this.gate, (): Promise<ApiResult> =>
    this.fake.getPage(pageKey, anonymous, sendAllowed));
  }

  listSectionItems(pageKey: string, sectionId: string, cursor: string | null, anonymous: boolean,
    sendAllowed: () => boolean): Promise<ApiResult> {
    return DebugSubstitutes.deliver(this.gate, (): Promise<ApiResult> =>
    this.fake.listSectionItems(pageKey, sectionId, cursor, anonymous, sendAllowed));
  }

  cancel(owner: number): void {
    this.fake.cancel(owner);
  }
}

/**
 * 模拟用户动作的启动参数（couli_debug_clip 写剪贴板样例、couli_debug_share 模拟系统分享；FU-HM-0711b R1-05）：执行时过替身闸门，
 * prod、假服务关闭时丢弃。冷启动时环境还没定（或运行中切换、闸门关闭）先暂存（同名后到的覆盖），环境就绪（settle）时再按此刻的
 * 闸门一次性执行或丢弃——非 prod 的截图流程照常，只是晚到环境就绪那一刻。单线程（UI 线程）使用。
 */
export class DebugLaunchDeferral {
  static readonly RUN: string = 'run';
  static readonly DEFERRED: string = 'deferred';
  static readonly DROPPED: string = 'dropped';

  private readonly ready: () => boolean;
  private readonly gate: () => boolean;
  private pending: Map<string, () => void> = new Map<string, () => void>();

  /** ready：环境已就绪（SETTLED 且不在切换中）；gate：替身闸门（DebugFakeServer.mockGate）。 */
  constructor(ready: () => boolean, gate: () => boolean) {
    this.ready = ready;
    this.gate = gate;
  }

  get pendingCount(): number {
    return this.pending.size;
  }

  /** 环境已就绪：闸门放行就执行，否则丢弃；未就绪：暂存。返回 RUN / DEFERRED / DROPPED。 */
  submit(key: string, action: () => void): string {
    if (!DebugLaunchDeferral.safe(this.ready)) {
      this.pending.set(key, action);
      return DebugLaunchDeferral.DEFERRED;
    }
    this.pending.delete(key);
    return this.decide(action);
  }

  /** 环境就绪时调用（冷启动对账通过、阻断页重试通过、切换后闸门重新打开）：暂存的逐个执行或丢弃，清空。返回执行的个数。 */
  settle(): number {
    if (!DebugLaunchDeferral.safe(this.ready) || this.pending.size === 0) {
      return 0;
    }
    const actions: (() => void)[] = Array.from(this.pending.values());
    this.pending.clear();
    let ran: number = 0;
    for (const action of actions) {
      if (this.decide(action) === DebugLaunchDeferral.RUN) {
        ran++;
      }
    }
    return ran;
  }

  /**
   * 延时执行（分享样例的 600 毫秒）：到点时再核对一次闸门，期间切到 prod 或关掉假服务就不执行。schedule 缺省 setTimeout；单测注入。
   */
  static delayed(gate: () => boolean, millis: number, run: () => void,
    schedule: (fire: () => void, millis: number) => void = (fire: () => void, ms: number): void => {
      setTimeout(fire, ms);
    }): void {
    schedule((): void => {
      if (DebugLaunchDeferral.safe(gate)) {
        run();
      }
    }, millis);
  }

  private decide(action: () => void): string {
    if (!DebugLaunchDeferral.safe(this.gate)) {
      return DebugLaunchDeferral.DROPPED;
    }
    try {
      action();
    } catch (e) {
      // 样例写入失败不影响启动。
    }
    return DebugLaunchDeferral.RUN;
  }

  private static safe(check: () => boolean): boolean {
    try {
      return check();
    } catch (e) {
      return false;
    }
  }
}
