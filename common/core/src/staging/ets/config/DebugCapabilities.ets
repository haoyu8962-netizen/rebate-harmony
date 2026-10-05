// 调试能力判断（03 §3.6），只在 Debug / Staging 编译；Release 产物里没有本文件（release-scan 检查）。
import { AppEnvironment } from '../../../main/ets/config/AppEnvironment';

/**
 * 调试能力。HomePreview 不在其中：它是独立的只读能力，连 prod 也可用，但同样不进 Release。
 * 取值带 'couli.debug.capability.' 前缀，是 release-scan 的标记之一。
 */
export enum DebugCapability {
  SWITCH_SERVER = 'couli.debug.capability.switch_server',
  DEBUG_ROUTES = 'couli.debug.capability.debug_routes',
  BRIDGE_CONFORMANCE = 'couli.debug.capability.bridge_conformance',
  DIAGNOSTICS = 'couli.debug.capability.diagnostics',
  RESULT_INJECTION = 'couli.debug.capability.result_injection',
  CLOCK_OFFSET = 'couli.debug.capability.clock_offset',
  MOCK_DATA = 'couli.debug.capability.mock_data'
}

export class DebugCapabilities {
  static readonly ALL: DebugCapability[] = [
    DebugCapability.SWITCH_SERVER, DebugCapability.DEBUG_ROUTES, DebugCapability.BRIDGE_CONFORMANCE,
    DebugCapability.DIAGNOSTICS, DebugCapability.RESULT_INJECTION, DebugCapability.CLOCK_OFFSET,
    DebugCapability.MOCK_DATA
  ];

  /**
   * 某项调试能力当前是否可用（本文件只存在于 Debug / Staging，Release 没有这些能力的代码）。
   * 当前环境是 prod 时只剩 SWITCH_SERVER，其余一律 false（客户端自行关闭，不依赖服务端开关）。
   */
  static isAvailable(capability: DebugCapability, environment: AppEnvironment): boolean {
    if (environment === AppEnvironment.PROD) {
      return capability === DebugCapability.SWITCH_SERVER;
    }
    return true;
  }
}
