// HM-LINT-10 违反样例：替身直接看「假服务已打开」，没有经过环境闸门（F-X-02）；第二处经导入别名读（FU-HM-0711b R1-06）。
// 第三处在模板表达式里、前面的字符串含右花括号（FU-HM-0711b R2-03）。注释、字符串、正则字面量里的 DebugFakeServer.enabled 不算
// （正反例的完整清单见 lint.py --self-test-hm10）。
import { DebugFakeServer, DebugFakeServer as Fake } from './DebugFakeServer';

export class BuildVariant {
  static readonly note: string = 'DebugFakeServer.enabled';
  static readonly pattern: RegExp = /DebugFakeServer.enabled/;

  static stepUpPhone(_account: string): string | null {
    return DebugFakeServer.enabled ? '13800000000' : null;
  }

  static guideBarOverride(): boolean | null {
    return Fake.enabled ? true : null;
  }

  static label(): string {
    return `${ /* DebugFakeServer.enabled */ '}' + DebugFakeServer.enabled }`;
  }
}
