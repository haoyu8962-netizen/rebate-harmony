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
// 旧的逐层现验（BridgeOrigins.ets）由实现步整体删除（D10-3512 (d)）；写测步只撤掉旧接口名的导出，名字让给新的验签器。
export { PendingContractBridgeOriginsVerifier, BridgeOrigins } from './BridgeOrigins';
export {
  BridgeOriginsLastGood, BridgeOriginsCheck, ConfigSignKeyEntry, ConfigSignKeys, Es256Port, CryptoKitEs256, Es256, Base64Url,
  BridgeOriginsVerdict, BridgeOriginsVerifier, BridgeOriginsWiring
} from './BridgeOriginsVerifier';
export {
  ExternalNavFrame, ExternalUnionOutcome, ExternalNoticeKey, ExternalNavOutcome, ExternalNavHooks, AuthPageRules,
  RegisteredDomain, ExternalPageNavigator, WebBackPolicy
} from './ExternalPageNavigator';
export { ExternalNavEvents } from './ExternalNavEvents';
export {
  StatusBarStyle, NavBarState, NavBarPort, NavBarHandler, ExternalNavStyle, ExternalPageOptions, WebFullScreen
} from './WebChrome';
