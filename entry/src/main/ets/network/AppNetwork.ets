import { bundleManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiAppIdentity, ApiClient, ApiClientDeps, AppConfig, AssetSecureStore, ClientPlatformRaw, DeviceIdentityCleaner, FileSlot,
  DeviceRegistry, EnvironmentEndpoints, EnvironmentSwitchGate, ErrorEffect, HttpTransport, NetworkComposition, NetworkContext, OdidReader, PendingKeysCleaner,
  PendingKeyBackend, PendingKeyStore, PreferencesSlot, PrivacyState, PrivacyStateRaw, SecureDeviceCredentialStore,
  SecurePendingKeyBackend, SecureSessionTokens, SessionEffectHost, SessionEffectRouting, SessionIdentity, SessionTokensCleaner,
  UpdateNetworkPort, UpdateState
} from 'core';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppLogin } from '../login/AppLogin';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';
import { HARMONY_CHANNEL, HARMONY_PLATFORM } from '../update/HarmonyStoreAccess';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliNetwork';
/** TODO(N-19)：X-App-Id 的取值契约里没有登记，与 Android 一样先用占位 couli。 */
const APP_ID: string = 'couli';
/** 会话撤销标记的沙盒文件（F-HM-34；不含凭据，只记被撤销会话的登录世代或短摘要）。 */
const SESSION_REVOKED_FILE: string = 'couli_session.revoked';

/**
 * 网络层要读的 App 状态：基址取当前环境（环境闸门 SETTLED 之前为 undefined，不发任何请求；Release 的环境目录只有
 * prod，见 BuildVariant / AppConfig），隐私结论取路由状态源，撤回清理未完成时凭据不可读。
 */
class AppNetworkContext implements NetworkContext {
  endpoints(): EnvironmentEndpoints | undefined {
    return AppConfig.endpoints();
  }

  privacy(): string {
    return AppRouting.shared.privacyState;
  }

  credentialsReadable(): boolean {
    return AppPrivacy.shared.credentialsReadable();
  }
}

/**
 * App 组合处的网络核心（APP-03a；harmony-review-r3 R3-04，lessons 35；Android 在 AppModule 里做同样的事）。
 * EntryAbility.onCreate 调 compose 一次（同一进程里 Ability 重建沿用同一个实例）：
 * - 会话令牌（Asset Store Kit）与未决幂等键：同一实例同时给 ApiClient 和清理注册表（令牌同名替换撤回同意的占位清理项；
 *   未决键只在切换环境 cleanAll 时清）；
 * - ApiClient.invalidate 登记为 AppConfig.cleaners 的「清理前第一步」：撤回同意（cleanOnly）与切换环境 / 覆盖安装
 *   对账（cleanAll）都最先作废并取消在途请求；
 * - 强更：UpdatePort 读 AppUpdate.inAppUpdate，确需强更（onForceUpdate）调 AppUpdate.on10405；返回的处理函数设为
 *   AppUpdate.onChanged：先通知 ApiClient.onUpdateStateChanged，再 AppRouting.stateChanged。
 * - 设备注册（APP-03b）：DeviceRegistry 同时是 ApiClient 的凭据源（签名改用服务端签发的 device_id、install_secret）与
 *   10402 的重新注册（单飞，重放 1 次）；device_id 进 Preferences、install_secret 进 Asset Store Kit。它的清理项同名替换
 *   撤回同意 / 切换环境的 device_identity 占位。PrivacyGate.onConsented 的设备注册步骤由 AppPrivacy 接到 registerDevice。
 */
/** 会话级 Effect 的 App 出口（登录页失效提示 + Router）。 */
class AppSessionEffectHost implements SessionEffectHost {
  markSessionExpired(): void {
    AppLogin.shared.markSessionExpired();
  }

  open(route: string): void {
    AppRouting.shared.openInApp(route);
  }

  stateChanged(): void {
    AppRouting.shared.stateChanged();
  }
}

export class AppNetwork {
  private static instance: ApiClient | null = null;
  private static updateHandler: (() => void) | null = null;
  private static registry: DeviceRegistry | null = null;
  private static secureTokens: SecureSessionTokens | null = null;
  private static versionName: string = '';

  /** 已组合的 ApiClient（compose 之前为 null）。 */
  static get client(): ApiClient | null {
    return AppNetwork.instance;
  }

  /** 设备注册（compose 之前为 null）。 */
  static get devices(): DeviceRegistry | null {
    return AppNetwork.registry;
  }

  /** 会话令牌（compose 之前为 null；埋点只读账号标识；切号处理读持久化登录世代，F-X-25）。 */
  static get tokens(): SecureSessionTokens | null {
    return AppNetwork.secureTokens;
  }

  /**
   * 令牌存储里的持久化登录世代（F-HM-25：订单恢复记录绑定它；F-HM-34：订单 / 钱包断网缓存也按它分区）。经 ApiClient.sessionLoginEpoch
   * 与会话归属同一口径（F-HM-34 ①）：compose 之前、凭据不可读、没有可信会话、隔离中、已撤销、读不出都为 null（按未知处理）。
   */
  static loginEpoch(): string | null {
    const client: ApiClient | null = AppNetwork.instance;
    return client === null ? null : client.sessionLoginEpoch(AppNetwork.secureTokens);
  }

  /** 订单、钱包与首页共用的身份快照；未组合时保持未知，令牌存储仅在网络组合层内访问。 */
  static sessionIdentity(): SessionIdentity {
    const client: ApiClient | null = AppNetwork.instance;
    return client === null ? new SessionIdentity(false, null, null) : client.sessionIdentity(AppNetwork.secureTokens);
  }

  /** X-App-Version 同一个版本号（埋点 app_version 用）。 */
  static get appVersion(): string {
    return AppNetwork.versionName;
  }

  /** PrivacyGate 的设备注册步骤（退避由 PrivacyGate 负责）。compose 之前为失败。 */
  static registerDevice(): Promise<boolean> {
    const registry: DeviceRegistry | null = AppNetwork.registry;
    return registry === null ? Promise.resolve(false) : registry.register();
  }

  /** 设备注册看到的隐私状态：已同意且撤回清理已完成才是 consented（BR-ID-11 同意前不读标识；lessons 2）。 */
  private static devicePrivacy(): string {
    return AppRouting.shared.privacyState === PrivacyState.CONSENTED && AppPrivacy.shared.credentialsReadable() ?
      PrivacyStateRaw.CONSENTED : PrivacyStateRaw.NOT_DECIDED;
  }

  /** 组合并返回 AppUpdate.onChanged 要用的处理函数。 */
  static compose(context: common.Context): () => void {
    const existing: (() => void) | null = AppNetwork.updateHandler;
    if (existing !== null) {
      return existing;
    }
    // F-HM-34：撤销标记另在沙盒文件里记一份（Asset 整体不可写时跨进程撤销，F-AND-32）。
    const tokens: SecureSessionTokens = new SecureSessionTokens(new AssetSecureStore('couli_session'),
      FileSlot.at(context.filesDir, SESSION_REVOKED_FILE));
    AppNetwork.secureTokens = tokens;
    // APP-05b：Debug / Staging 打开本机假服务时，未决记录放内存（模拟器的 Asset 不支持批量查询，step-up 操作发不出）；
    // Release 恒为 Asset。
    const pendingBackend: PendingKeyBackend =
      BuildVariant.pendingKeyBackend(new SecurePendingKeyBackend(new AssetSecureStore('couli_pending_keys')));
    const pendingKeys: PendingKeyStore = new PendingKeyStore(pendingBackend, (): number => Date.now());
    SessionTokensCleaner.register(AppConfig.cleaners, tokens);
    AppConfig.cleaners.register(new PendingKeysCleaner(pendingBackend, pendingKeys));
    const update: UpdateNetworkPort = new UpdateNetworkPort(
      (): UpdateState => AppUpdate.shared.inAppUpdate(),
      (minSupported: string | null): void => AppUpdate.shared.on10405(minSupported));
    // 传输层：Release 为 RcpTransport；Debug / Staging 外包一层只在启动参数打开时接管的本机假服务（APP-05a 冒烟与截图）。
    const transport: HttpTransport = BuildVariant.networkTransport();
    const deps: ApiClientDeps = new ApiClientDeps(transport, new AppNetworkContext(), AppNetwork.identity(),
      tokens, update);
    // APP-10b：流式请求（sendAgentMessage）经同一个传输入口（Release：同一个 RCP 会话；Debug / Staging：同一道假服务闸门）。
    deps.streamTransport = BuildVariant.networkStreamTransport(transport);
    deps.pendingKeys = pendingKeys;
    const registry: DeviceRegistry = new DeviceRegistry(ClientPlatformRaw.HARMONY, new OdidReader(),
      new SecureDeviceCredentialStore(
        new PreferencesSlot(context, SecureDeviceCredentialStore.DEVICE_NAMESPACE, SecureDeviceCredentialStore.DEVICE_ID_KEY),
        new AssetSecureStore('couli_device')),
      (): string => AppNetwork.devicePrivacy(), (): ApiClient | null => AppNetwork.instance);
    // 10402 后重新注册失败：交给 PrivacyGate 的退避流程；环境切换完成（新环境已提交）：立即重新开始注册（R1-02）。
    registry.onRestartNeeded = (immediate: boolean): void => AppPrivacy.shared.restartDeviceRegistration(immediate);
    // 注册绑定环境世代：切换中不开始，跨切换的结果作废，闸门关闭时放弃在途任务（R2-01），重新打开时重新开始（R1-01、R1-02）。
    registry.attachEnvironment(EnvironmentSwitchGate.shared);
    // 隐私世代（撤回同意加 1）：注册任务的 ticket 含它，撤回过的旧任务不再读标识、发送或保存（lessons 12、13）。
    registry.privacyEpoch = (): number => AppPrivacy.shared.consentCycle();
    DeviceIdentityCleaner.register(AppConfig.cleaners, registry);
    deps.credentials = registry;
    deps.deviceRegistrar = registry;
    AppNetwork.registry = registry;
    deps.sessionEffect = (effect: ErrorEffect, clearedGeneration: number): void => {
      // APP-05a 共性 25、26：网络层在确定清理的同步区里传出被清的会话世代；Router 记下「原会话被清除」的分界（之后新建的
      // pending_action 属于游客 / 新会话，登出收尾不清它）。不在这里读「当前世代」补作归属。
      AppRouting.shared.router.markSessionCleared(clearedGeneration);
      // 10404 与刷新失败清会话（F-HM-09，APP-05a 共性 18）：普通状态经 Router 打开 Login 并提示失效；强更状态下只清会话、
      // 停在强更页。守卫的会话状态随之现算为游客。判定在 Core 的 SessionEffectRouting（测试从真实 ApiClient 回调触发）。
      hilog.info(DOMAIN, TAG, 'session effect %{public}s', effect.effectKindRaw);
      SessionEffectRouting.apply(effect, new AppSessionEffectHost());
    };
    // F-HM-08（APP-05a 共性 14）：受限会话在异步刷新里变为 full 等作用域变化：世代仍是当前世代时交 Router 重算守卫状态
    // （stateChanged 先过守卫再恢复待办）；世代已变（登出、换号）的旧通知丢弃。
    // F-HM-09（APP-05a 共性 19）：按触发来源区分——冷启动 / 强更恢复的 App 级屏障变成 full：经 Router 守卫恢复待办；
    // 登录尝试的复查（有效时 LoginService 自己恢复，已取消时不该恢复）与业务请求的刷新：只同步状态（resumePending=false）。
    deps.sessionRefreshedFrom = (generation: number, scope: string, resumePending: boolean): void => {
      const current: ApiClient | null = AppNetwork.instance;
      if (current === null || current.sessionGenerationId() !== generation) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'session refreshed scope=%{public}s resume=%{public}s', scope, String(resumePending));
      AppRouting.shared.stateChanged(resumePending);
    };
    // APP-12 G03：个性化推荐关闭期间带 X-Personalization: off（本机偏好，按设备；匿名请求不带）。
    deps.personalizationOff = (): boolean => AppNetwork.personalizationOff();
    // APP-12 G09：任一请求得到 10006 → 经 Router 一处统一落到 RiskNotice（AppMe.on10006，组合后接上）。
    deps.riskNotice = (generation: number, mark: string, permit: (() => boolean) | null): void =>
      AppNetwork.riskNotice(generation, mark, permit);
    // APP-12 R1-08：调用入口时的导航标记（导航栈页面名 + 选中的 Tab），10006 落点据此不覆盖用户后续导航。
    deps.navigationMark = (): string => AppNetwork.navigationMark();
    const client: ApiClient = new ApiClient(deps);
    // F-HM-28：令牌清理器同名替换为「清除后同步把已绑定归属改为游客」的版本（保持上面登记的位置）。
    const handler: () => void = NetworkComposition.install(client, AppConfig.cleaners,
      (): void => AppRouting.shared.stateChanged(), EnvironmentSwitchGate.shared, tokens);
    AppNetwork.instance = client;
    AppNetwork.updateHandler = handler;
    return handler;
  }

  /** APP-12：本机个性化开关（AppMe 组合后接上；之前按开）。 */
  static personalizationOff: () => boolean = () => false;
  /** APP-12：10006 的统一落点（AppMe 组合后接上）。 */
  static riskNotice: (generation: number, mark: string, permit: (() => boolean) | null) => void =
    (_g: number, _m: string, _p: (() => boolean) | null) => {
    };
  /** APP-12：导航标记（AppMe 组合后接上；之前为空串 = 不核对）。 */
  static navigationMark: () => string = () => '';

  private static identity(): ApiAppIdentity {
    let versionName: string = '';
    let versionCode: string = '';
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      versionName = info.versionName;
      versionCode = String(info.versionCode);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read bundle version failed: %{public}s', JSON.stringify(e));
    }
    AppNetwork.versionName = versionName;
    return new ApiAppIdentity(APP_ID, HARMONY_PLATFORM, versionName, versionCode, HARMONY_CHANNEL);
  }
}
