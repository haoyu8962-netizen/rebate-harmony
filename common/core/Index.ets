// Core：本任务只有 config（环境）有内容；其余子目录为占位（TODO 见各文件）。
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
export * from 'core/ets/config/DebugOnly';
