// APP-10：Agent 页（AgentTabRoot）、卡片渲染器（AgentCards）与 AgentConsent 弹窗。纯逻辑与执行层在 Core（common/core/src/main/ets/agent），
// 组合在 entry/agent（AppAgent）。规则：本模块不得依赖其他 feature；跨功能跳转只经路由名（Router）。

export class AgentFeature {
  static readonly MODULE_NAME: string = 'agent';
}
