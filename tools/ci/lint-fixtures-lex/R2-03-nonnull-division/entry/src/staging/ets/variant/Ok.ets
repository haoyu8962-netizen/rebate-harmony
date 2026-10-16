// lint-fixtures-lex 的正常源码（无违反）：HM-LINT-10 的范围里放一个正常文件，违反只来自旁边那个样例。
import { DebugFakeServer } from './DebugFakeServer';

export class Ok {
  static mock(): boolean {
    return DebugFakeServer.mockGate();
  }
}
