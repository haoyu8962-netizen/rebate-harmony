// 桥协议的统一出口（三端测试接线约定：Codex 的 BridgeVector.test.ets 从这里导入）。只做重导出，不实现任何判断。
export {
  BridgeCode, BridgeEnvelope, BridgeContext, BridgeDecision, BridgeWire, BridgeProtocol
} from './BridgeProtocol';
export { ExternalNavAction, ExternalNavDecision, ExternalNavPolicy } from './ExternalNavPolicy';
export { BridgeJson, BridgeSchema } from './BridgeSchema';
export { OriginRules, StandardUrl, NormalizedHttpsUrl, LinkRule, LinkRuleTable } from './LinkRules';
export { TrustedNavAction, TrustedNavDecision, TrustedNavPolicy } from './TrustedNavPolicy';
export {
  BridgeResult, BridgeCall, BridgeHandler, BridgeCaller, BridgeStatePort, BridgeClock, SystemBridgeClock, BridgeGesture,
  BridgeTouchKind, BridgeTrackPort, BridgeHost, BridgeReplyChannel
} from './BridgeHost';
export {
  BridgeApiPort, BridgeRoutePort, BridgeRouteOpening, BridgeRouteDecider, BridgeBinding, BridgeHandlers
} from './BridgeHandlers';
export { BridgeFrames, BridgePageSession } from './BridgeFrames';
export { AuthChangeDecision } from './AuthChangeDecision';
export {
  FileTrustedAuthJournal, FileTrustedWebOwnerRecord, TrustedAuthJournal, TrustedAuthPage, TrustedAuthStore, TrustedAuthSync,
  TrustedWebOwnerRecord
} from './TrustedAuthSync';
export { BridgeOriginsVerifier, PendingContractBridgeOriginsVerifier, BridgeOrigins } from './BridgeOrigins';
export {
  ExternalNavFrame, ExternalUnionOutcome, ExternalNoticeKey, ExternalNavOutcome, ExternalNavHooks, AuthPageRules,
  RegisteredDomain, ExternalPageNavigator, WebBackPolicy
} from './ExternalPageNavigator';
export { ExternalNavEvents } from './ExternalNavEvents';
export {
  StatusBarStyle, NavBarState, NavBarPort, NavBarHandler, ExternalNavStyle, ExternalPageOptions, WebFullScreen
} from './WebChrome';
