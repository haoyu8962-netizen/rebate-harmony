// Debug / Staging（core 模块 staging target）：导出环境切换实现与调试能力判断。
// core/Index.ets 用 export * from 'core/ets/config/DebugOnly' 导出，由 hvigor 按 target 选本文件或 src/release 的替身。
import { AppConfig } from '../../../main/ets/config/AppConfig';
import { EnvironmentSource } from '../../../main/ets/config/AppEnvironment';
import { EnvironmentSwitcher } from './EnvironmentSwitcher';

export { DebugCapability, DebugCapabilities } from './DebugCapabilities';
export { EnvironmentSelection, SwitchOutcome, SwitchResult, EnvironmentSwitcher } from './EnvironmentSwitcher';
// APP-11：首页草稿预览的纯策略（HomePreview 只在 Debug / Staging）。
export { HomePreviewPolicy } from '../home/HomePreviewPolicy';
export {
  HomeDebugSources, HomePreviewDeps, HomePreviewDisplay, HomePreviewNav, HomePreviewSession, HomePreviewState
} from '../home/HomePreviewSession';
// APP-10：Agent 四个待定 operation 的本机假服务（G01；Release 没有端口）。
export {
  AGENT_FAKE_MARKER, AgentFakeScript, AgentFakeService, AgentDebugSources
} from '../agent/AgentFakeService';
// R2-01：本机假服务的传输入口闸门（prod 一律走真实传输）。
export { DebugMockGate, DebugMockTransport } from '../network/DebugMockTransport';
// F-X-02：传输入口以外的调试替身统一过同一道环境闸门（每次使用时重新判断）。
export {
  DebugLaunchDeferral, DebugSubstitutes, GatedAuthAdapter, GatedHomeContractPort, GatedMeContractPort,
  GatedPendingKeyBackend, GatedPushTokenSource, GatedWalletContractPort, GatedWebCodeAuthorizer
} from '../network/DebugSubstitutes';

export const ENVIRONMENT_SWITCH_COMPILED: boolean = true;

/** 调试面板拿可切换的当前环境；环境闸门不是 SETTLED（未装入或 BLOCKED）时返回 undefined。 */
export function currentEnvironmentSwitcher(): EnvironmentSwitcher | undefined {
  const source: EnvironmentSource | undefined = AppConfig.environment();
  return source instanceof EnvironmentSwitcher ? source : undefined;
}
