// Core：config（环境）与 router（APP-02a：入口守卫、深链、pending_action、启动排队、推送落点）；其余子目录为占位。
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
export { PrivacyGate } from './src/main/ets/privacy/PrivacyGate';
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
export * from 'core/ets/config/DebugOnly';
