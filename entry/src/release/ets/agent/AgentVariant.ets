// Release（entry 模块 default target）：Agent 没有任何本机假服务（APP-10b §2 第 12 条）。真实端口 ApiAgentContractPort 在 main 源码集，
// 由 AppAgent 组合（与构建类型无关）；「未开放」只按 agent.entry.visible、config.agent.enabled、本次进入的 30501 判断。
// 同名文件在 src/staging/ets/agent/AgentVariant.ets（Debug / Staging 的本机假服务与启动参数）。
import { Want } from '@kit.AbilityKit';
import { AgentController } from 'core';

export class AgentVariant {
  static consentRecorded(_accepted: boolean): void {
  }

  /** Release 没有入口开关的调试覆盖（只按 Config 的 agent.entry.visible）。 */
  static entryVisibleOverride(): boolean | null {
    return null;
  }

  static applyLaunch(_want: Want): void {
  }

  /** Release 没有启动参数自动发送（R1-11：实现只在 staging 源码集）。 */
  static onAgentShown(_current: () => AgentController | null): void {
  }
}
