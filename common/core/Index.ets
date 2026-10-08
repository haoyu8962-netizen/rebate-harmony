// Core：config（环境）、router（APP-02a：入口守卫、深链、pending_action、启动排队、推送落点）、privacy（APP-02b：隐私闸门）
// 与 update（APP-02c：强更检查）；network、session、storage（APP-03a：请求管线、签名、单飞刷新、ErrorActionMapper、未决键、
// 令牌与安全存储）；clientcore、device（APP-03b：设备注册、ConfigStore + LKG、TrackerQueue、PermissionRequester）；
// bridge（APP-04）：桥协议、宿主与外部页导航判定；其余子目录为占位。
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
export { EnvironmentSwitchGate } from './src/main/ets/config/EnvironmentSwitchGate';
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
export { PathStack, UPGRADE_PROMPT_PAGE, StackNavigator, RoutingSync } from './src/main/ets/router/StackNavigator';
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
  ApiClient, ClientScope
} from './src/main/ets/network/ApiClient';
export { UpdateNetworkPort, NetworkComposition } from './src/main/ets/network/NetworkComposition';
export {
  SessionTokenSet, SessionTokens, SessionReadStatus, MemorySessionTokens, SecureSessionTokens, SessionTokensCleaner
} from './src/main/ets/session/SessionTokens';
export { SecureEntry, SecureStore, MemorySecureStore, AssetSecureStore } from './src/main/ets/storage/SecureStore';
export { FileOps, SystemFileOps, FileSlot } from './src/main/ets/storage/FileSlot';
// clientcore（APP-03b）：设备标识判定、配置与 LKG、埋点队列、权限申请；设备注册（device）。
export * from './src/main/ets/clientcore/ClientCore';
export { ApiConfigFetcher } from './src/main/ets/clientcore/ApiConfigFetcher';
export {
  DeviceIdReader, OdidReader, StoredDeviceKind, StoredDevice, DeviceCredentialStore, MemoryDeviceCredentialStore,
  KeyValueSlot, PreferencesSlot, SecureDeviceCredentialStore
} from './src/main/ets/device/DeviceCredentialStore';
export { DeviceRegistry, DeviceIdentityCleaner } from './src/main/ets/device/DeviceRegistry';
// login（APP-05a）：短信登录纯逻辑（向量 specs/login-vectors.json）与执行器（页面在 features/auth）。
export {
  PhoneResult, PhoneNumber, AgreementState, SmsCountdownResult, SmsCountdown, CodeShape, CodeInput, LoginErrorResult,
  LoginErrorMapper, InviteDecision, InviteField, AfterLoginAction, AfterLoginUpdate, AfterLogin, LegalVersions
} from './src/main/ets/login/LoginFlow';
export {
  LoginHost, SendCodeOutcome, LoginOutcome, SmsSendDeadlines, LoginRateLimits, LoginService, PhoneEntry, LoginSendState,
  AttemptTicket, WriteObserver, SendDeadline
} from './src/main/ets/login/LoginService';
// login（APP-05b）：第三方登录、绑手机与并号的纯逻辑（向量 specs/oauth-login-vectors.json）与执行器；桥 auth.login 的等待（F-HM-10）。
export {
  OAuthProvider, DroppedCallback, OAuthAttemptSession, OAuthRouteResult, OAuthLoginRoute, OAuthErrorResult,
  OAuthLoginErrorAction, ThirdPartyButtons, BindActionResult, BindPhoneAction, MergeResult, MergeDecision
} from './src/main/ets/login/OAuthLoginFlow';
export {
  ThirdPartyAuthKind, ThirdPartyAuthResult, ThirdPartyAuthAdapter, UnavailableWechatAdapter, PhoneBindingState,
  OAuthLoginOutcome, OAuthLoginService
} from './src/main/ets/login/OAuthLoginService';
export { BindOutcome, BindPhoneHost, BindPhoneService } from './src/main/ets/login/BindPhoneService';
export { AuthFeedback } from './src/main/ets/login/AuthFeedback';
export { AuthAnnouncement, BindPhoneAnnouncer } from './src/main/ets/login/BindPhoneAnnouncer';
export { BridgeLoginWait } from './src/main/ets/login/BridgeLoginWait';
export { RouterLoginHost } from './src/main/ets/login/RouterLoginHost';
export { SessionEffectHost, SessionEffectRouting } from './src/main/ets/login/SessionEffectRouting';
// search（APP-06a）：搜索与商品详情的纯逻辑（向量 specs/search-product-vectors.json）与执行器（页面在 features/search、product）。
export {
  SearchQueryResult, SearchQuery, SearchTabs, SearchStateRaw, SearchPager, SearchResultView, SearchResultState,
  SearchSession, ProductDetailView, ProductDetailState
} from './src/main/ets/search/SearchProductFlow';
export {
  SearchApiPort, ApiClientSearchPort, SearchPhase, SearchSnapshot, SearchController, ProductPhase, ProductSnapshot,
  ProductDetailController, SearchConfigPort, disableMillisOf, trace6Of,
  SearchTextFormatter, SearchErrorText, withTrace6, SearchConditions, DetailPurchasePort
} from './src/main/ets/search/SearchController';
// FU-HM-1112：搜索与详情的页面级规则（购买状态、入账说明、路由名、页面状态持久化与自动恢复）。
export {
  PURCHASE_ON, PURCHASE_MAINTENANCE, PURCHASE_NOT_LAUNCHED, PlatformPurchase, PurchaseStatusPort, CreditNote,
  SearchRoutes, SearchDraft, DetailIdentity, SearchPageRecord, PageStateStore, ScrollRestoreStep, ScrollRestore,
  ScrollAnchorTracker,
  PageRestorer, DetailNotes, SearchLayout, SearchRows, ViewportTop, ScrollKeeperHost, RestoreStage, ScrollRestoreJob,
  SearchScrollKeeper, RestoreExpectation, SearchPageLife, SearchPageStates
} from './src/main/ets/search/SearchPageState';
// bridge（APP-04 / HM-03）：JSBridge 协议判定、宿主、外部页导航判定（容器在 features/web）。
export * from './src/main/ets/bridge/Bridge';
export * from 'core/ets/config/DebugOnly';
