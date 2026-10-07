// 客户端核心（APP-03b）的统一出口：三端测试接线约定（Codex 的 ClientCoreVector.test.ets 从这里导入）。
// 只做重导出，不实现任何判断。ClientEvents 是 specs/events.yaml 的生成构造器（generated 模块）。
export { ClientEvent, ClientEventValue, ClientEvents } from 'generated';
export { ClientPlatformRaw, PrivacyStateRaw, DeviceIdDecision, DeviceIdPolicy } from './DeviceIdPolicy';
export { JsonRecord, ConfigResolver } from './ConfigResolver';
export {
  ConfigReply, ConfigSourceRaw, ConfigSnapshot, ConfigListener, ConfigFetcher, ConfigLayers, ConfigStore
} from './ConfigStore';
export { AsyncEventSink, EventSink, TrackerQueue, UploadTicket } from './TrackerQueue';
export {
  TrackerQueueCleaner, RepeatingTimer, SystemRepeatingTimer, TrackerFlushScheduler
} from './TrackerLifecycle';
export {
  PermissionStatusRaw, PermissionTypeRaw, PermissionResult, PermissionStatusPort, RationalePort, SystemRequestPort,
  SettingsGuidePort, PermissionRequester
} from './PermissionRequester';
export { Sha256 } from './Sha256';
