// Debug / Staging（core 模块 staging target）：导出环境切换实现与调试能力判断。
// core/Index.ets 用 export * from 'core/ets/config/DebugOnly' 导出，由 hvigor 按 target 选本文件或 src/release 的替身。
import { AppConfig } from '../../../main/ets/config/AppConfig';
import { EnvironmentSource } from '../../../main/ets/config/AppEnvironment';
import { EnvironmentSwitcher } from './EnvironmentSwitcher';

export { DebugCapability, DebugCapabilities } from './DebugCapabilities';
export { EnvironmentSelection, SwitchOutcome, SwitchResult, EnvironmentSwitcher } from './EnvironmentSwitcher';

export const ENVIRONMENT_SWITCH_COMPILED: boolean = true;

/** 调试面板拿可切换的当前环境；环境闸门不是 SETTLED（未装入或 BLOCKED）时返回 undefined。 */
export function currentEnvironmentSwitcher(): EnvironmentSwitcher | undefined {
  const source: EnvironmentSource | undefined = AppConfig.environment();
  return source instanceof EnvironmentSwitcher ? source : undefined;
}
