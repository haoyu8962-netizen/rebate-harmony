import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiAppIdentity, ApiClient, ApiClientDeps, AppConfig, AssetSecureStore, EnvironmentEndpoints, ErrorEffect,
  NetworkComposition, NetworkContext, PendingKeysCleaner, PendingKeyStore, RcpTransport, SecurePendingKeyBackend,
  SecureSessionTokens, SessionTokensCleaner, UpdateNetworkPort, UpdateState
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
 */
export class AppNetwork {
  private static instance: ApiClient | null = null;
  private static updateHandler: (() => void) | null = null;

  /** 已组合的 ApiClient（compose 之前为 null）。 */
  static get client(): ApiClient | null {
    return AppNetwork.instance;
  }

  /** 组合并返回 AppUpdate.onChanged 要用的处理函数。 */
  static compose(): () => void {
    const existing: (() => void) | null = AppNetwork.updateHandler;
    if (existing !== null) {
      return existing;
    }
    const tokens: SecureSessionTokens = new SecureSessionTokens(new AssetSecureStore('couli_session'));
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
    return new ApiAppIdentity(APP_ID, HARMONY_PLATFORM, versionName, versionCode, HARMONY_CHANNEL);
  }
}
