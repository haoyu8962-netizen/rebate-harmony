// 违反样例：在 PrivacyGate 以外初始化第三方 SDK。
declare class MobPush {
  static init(appKey: string): void;
}

export function boot(): void {
  MobPush.init('placeholder');
}
