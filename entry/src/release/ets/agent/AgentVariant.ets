// Release（entry 模块 default target）：Agent 页没有端口（G01：锁定契约没有任何 /v1/agent/* 接口，四个待定 operation 只由 Debug / Staging
// 的本地假服务实现）。Agent 页显示「未开放」、不显示输入框、不弹同意框、不发任何 agent 请求；设置页不显示【撤回 AI 服务同意】。
// 同名文件在 src/staging/ets/agent/AgentVariant.ets。TODO(N-36)：契约补上后由 ApiClient 管线实现同一端口。
import { Want } from '@kit.AbilityKit';
import { AgentContractPort, AgentController } from 'core';

export class AgentVariant {
  static contract(): AgentContractPort | null {
    return null;
  }

  static consentRecorded(_accepted: boolean): void {
  }

  static applyLaunch(_want: Want): void {
  }

  /** Release 没有启动参数自动发送（R1-11：实现只在 staging 源码集）。 */
  static onAgentShown(_current: () => AgentController | null): void {
  }
}
