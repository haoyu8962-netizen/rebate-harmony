import { bundleManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiAppIdentity, ApiClient, ApiClientDeps, AppConfig, AssetSecureStore, ClientPlatformRaw, DeviceIdentityCleaner,
  DeviceRegistry, EnvironmentEndpoints, EnvironmentSwitchGate, ErrorEffect, NetworkComposition, NetworkContext, OdidReader, PendingKeysCleaner,
  PendingKeyStore, PreferencesSlot, PrivacyState, PrivacyStateRaw, RcpTransport, SecureDeviceCredentialStore,
  SecurePendingKeyBackend, SecureSessionTokens, SessionTokens, SessionTokensCleaner, UpdateNetworkPort, UpdateState
} from 'core';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';
import { HARMONY_CHANNEL, HARMONY_PLATFORM } from '../update/HarmonyStoreAccess';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliNetwork';
/** TODO(N-19)：X-App-Id 的取值契约里没有登记，与 Android 一样先用占位 couli。 */
const APP_ID: string = 'couli';

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
export class AppNetwork {
  private static instance: ApiClient | null = null;
  private static updateHandler: (() => void) | null = null;
  private static registry: DeviceRegistry | null = null;
  private static sessionTokens: SessionTokens | null = null;
  private static versionName: string = '';

  /** 已组合的 ApiClient（compose 之前为 null）。 */
  static get client(): ApiClient | null {
    return AppNetwork.instance;
  }

  /** 设备注册（compose 之前为 null）。 */
  static get devices(): DeviceRegistry | null {
    return AppNetwork.registry;
  }

  /** 会话令牌（compose 之前为 null；埋点只读账号标识）。 */
  static get tokens(): SessionTokens | null {
    return AppNetwork.sessionTokens;
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
    const tokens: SecureSessionTokens = new SecureSessionTokens(new AssetSecureStore('couli_session'));
    AppNetwork.sessionTokens = tokens;
    const pendingBackend: SecurePendingKeyBackend =
      new SecurePendingKeyBackend(new AssetSecureStore('couli_pending_keys'));
    const pendingKeys: PendingKeyStore = new PendingKeyStore(pendingBackend, (): number => Date.now());
    SessionTokensCleaner.register(AppConfig.cleaners, tokens);
    AppConfig.cleaners.register(new PendingKeysCleaner(pendingBackend, pendingKeys));
    const update: UpdateNetworkPort = new UpdateNetworkPort(
      (): UpdateState => AppUpdate.shared.inAppUpdate(),
      (minSupported: string | null): void => AppUpdate.shared.on10405(minSupported));
    const deps: ApiClientDeps = new ApiClientDeps(new RcpTransport(), new AppNetworkContext(), AppNetwork.identity(),
      tokens, update);
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
    deps.sessionEffect = (effect: ErrorEffect): void => {
      // 刷新失败清会话：普通状态跳登录；强更状态下只清会话、停在强更页（route 为 null）。登录页本身在 APP-05。
      hilog.info(DOMAIN, TAG, 'session effect %{public}s', effect.effectKindRaw);
      if (effect.route !== null) {
        AppRouting.shared.openInApp(effect.route);
      }
    };
    const client: ApiClient = new ApiClient(deps);
    const handler: () => void = NetworkComposition.install(client, AppConfig.cleaners,
      (): void => AppRouting.shared.stateChanged());
    AppNetwork.instance = client;
    AppNetwork.updateHandler = handler;
    return handler;
  }

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
