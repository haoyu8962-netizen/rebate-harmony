// Debug / Staging（core 模块 staging target）：本机一致性测试源的 origin 口径（APP-04，03 §5.5）。
// 只在 product=staging 编译；Release 的同名文件不认任何非 https origin。是否放行仍只看白名单——回环源只在 Debug 构建
// （entry 的 BuildVariant.debugTrustedOrigins）加入。release-scan 要求 Debug / Staging 命中、Release 不得出现这些字面量。

class DevOriginRules {
  static readonly LOOPBACK_HOSTS: string[] = ['127.0.0.1', 'localhost'];
}

/** http 且主机是本机回环地址时按 http 默认端口 80 规范化；其余 null。 */
export function devOriginDefaultPort(scheme: string, host: string): number | null {
  return scheme === 'http' && DevOriginRules.LOOPBACK_HOSTS.indexOf(host) >= 0 ? 80 : null;
}
