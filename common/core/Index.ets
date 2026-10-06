// Core：config（环境）、router（APP-02a：入口守卫、深链、pending_action、启动排队、推送落点）、privacy（APP-02b：隐私闸门）
// 与 update（APP-02c：强更检查）；network、session、storage（APP-03a：请求管线、签名、单飞刷新、ErrorActionMapper、未决键、
// 令牌与安全存储）；其余子目录为占位。
// 'core/ets/config/DebugOnly' 由 hvigor 按 target 选目录：staging target（Debug / Staging）→ src/staging，
// 导出环境切换实现（EnvironmentSwitcher）与调试能力判断（DebugCapabilities）；
// default target（Release）→ src/release，只导出 ENVIRONMENT_SWITCH_COMPILED = false。
export {
  AppEnvironment, parseAppEnvironment, EnvironmentEndpoints, PROD_ENDPOINTS, EnvironmentSource, FixedEnvironment
} from './src/main/ets/config/AppEnvironment';
export { LocalDataCleaner, CleanReport, LocalDataCleanerRegistry } from './src/main/ets/config/LocalDataCleaner';
export { CouliPreferences, PreferencesNamespaceCleaner } from './src/main/ets/config/PreferencesNamespaceCleaner';
export { EnvironmentRecord, EnvironmentRecordKeys, PreferencesEnvironmentRecord } from './src/main/ets/config/EnvironmentRecord';
export { LaunchOutcome, LaunchReport, EnvironmentLaunchReconciler } from './src/main/ets/config/EnvironmentLaunchReconciler';
export {
  AppConfig, BuildEnvironmentCatalog, EnvironmentBootstrap, EnvironmentCatalogPort, EnvironmentGate
} from './src/main/ets/config/AppConfig';
export {
  PrivacyDecision, PrivacyPromptStage, parsePrivacyDecision, PrivacyGateState, PrivacyStore, MemoryPrivacyStore,
  RetryScheduler, TimerRetryScheduler, PrivacyInitSteps, PrivacyGate
} from './src/main/ets/privacy/PrivacyGate';
export { PrivacyStoreKeys, PreferencesPrivacyStore } from './src/main/ets/privacy/PreferencesPrivacyStore';
export { PrivacyWithdrawalCleaners, PlaceholderCleaner } from './src/main/ets/privacy/PrivacyWithdrawal';
export { PrivacyPromptCover } from './src/main/ets/privacy/PrivacyPromptCover';
export {
  RouteSource, parseRouteSource, entryOf, RouteRequest, emptyParams, paramCount
} from './src/main/ets/router/RouteRequest';
export {
  PrivacyState, UpdateState, SessionState, parsePrivacyState, parseUpdateState, parseSessionState,
  RouteTargetAllowlist, GuardState
} from './src/main/ets/router/GuardState';
export { GuardDecisionKind, GuardReason, GuardDecision } from './src/main/ets/router/GuardDecision';
export { RoutePolicy, RouteTable, AppVersion } from './src/main/ets/router/RoutePolicy';
export { RouteParamValidator, HttpsTarget, RouteTargetCheck } from './src/main/ets/router/RouteParamValidator';
export { RouteLookup, EntryGuard } from './src/main/ets/router/EntryGuard';
export { DeepLinkConfig, DeepLinkParser } from './src/main/ets/router/DeepLinkParser';
export {
  PendingActionBackend, MemoryPendingBackend, PreferencesPendingBackend, PendingAction, PendingActionStore
} from './src/main/ets/router/PendingActionStore';
export {
  LaunchIntent, UpdateCheckStatus, LaunchReadiness, LaunchRelease, LaunchQueue
} from './src/main/ets/router/LaunchQueue';
export {
  PushLookupKind, PushLookupResult, PushLookup, PushLandingResult, PushLanding
} from './src/main/ets/router/PushLanding';
export { RouteDestination, RouteNavigator, Router } from './src/main/ets/router/Router';
// update：UpdateGate 的 UpdateState 与 router 的强更结果枚举 UpdateState 同名，这里导出为 UpdateGateState。
export {
  DEFAULT_RECHECK_INTERVAL_SEC, UpdateStatusRaw, UpdateStoreListing, UpdateCheckResult, UpdateState as UpdateGateState,
  StoreChoice, UpdatePersisted, UpdateStore, MemoryUpdateStore, UpdateGate, UpdateCheckOutcome, UpdateChecker,
  PlaceholderUpdateChecker
} from './src/main/ets/update/UpdateGate';
export { PreferencesUpdateStore } from './src/main/ets/update/PreferencesUpdateStore';
export { UpdateCheckAdapter } from './src/main/ets/update/UpdateCheckAdapter';
export { UpdateRouting } from './src/main/ets/update/UpdateRouting';
export { UpdateCheckCoordinator } from './src/main/ets/update/UpdateCheckCoordinator';
// network（APP-03a）
export { ApiOperation, ApiOperations } from 'generated';
export {
  NetworkHeaders, LocalRejectReason, NetworkPrivacy, SessionScope, NetworkRequestState, HeaderDecision, RequestHeaderPolicy,
  RetryPlan, RetryPolicy, PendingResolution
} from './src/main/ets/network/NetworkPolicy';
export {
  EffectKind, ReauthorizeIn, ReplayKind, ErrorUpdateState, ErrorActionState, ErrorActionInput, ErrorEffect, ErrorActionMapper
} from './src/main/ets/network/ErrorActionMapper';
export { RefreshCompletion, RefreshRequest, RefreshCoordinator } from './src/main/ets/network/RefreshCoordinator';
export {
  PendingKeyStateRaw, PendingResponseKind, PendingKeyRecord, PendingKeyBackend, MemoryPendingKeyBackend,
  SecurePendingKeyBackend, PendingKeyState, PendingKeyStore, PendingKeysCleaner, PendingStoreError
} from './src/main/ets/network/PendingKeyStore';
export { DigestPort, CryptoKitDigest, SigningInput, RequestSigner } from './src/main/ets/network/RequestSigner';
export {
  TransportRequest, TransportResponse, TransportFailure, HttpTransport, RcpRequestSpec, RcpRawResponse, RcpSender,
  SystemRcpSender, RcpTransport
} from './src/main/ets/network/HttpTransport';
export {
  ApiAppIdentity, CredentialSource, NoDeviceCredentials, NetworkContext, UpdatePort, DeviceRegistrar, NoDeviceRegistrar,
  NetworkTimer, SystemNetworkTimer, NetworkRandom, SystemNetworkRandom, ApiClientDeps, ApiRequest, ApiOutcome, ApiResult,
  ApiClient
} from './src/main/ets/network/ApiClient';
export { UpdateNetworkPort, NetworkComposition } from './src/main/ets/network/NetworkComposition';
export {
  SessionTokenSet, SessionTokens, MemorySessionTokens, SecureSessionTokens, SessionTokensCleaner
} from './src/main/ets/session/SessionTokens';
export { SecureEntry, SecureStore, MemorySecureStore, AssetSecureStore } from './src/main/ets/storage/SecureStore';
export * from 'core/ets/config/DebugOnly';
