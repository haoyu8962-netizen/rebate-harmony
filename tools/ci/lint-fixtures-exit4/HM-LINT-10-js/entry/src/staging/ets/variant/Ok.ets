// lint-fixtures-exit4 的正常源码（HM-LINT-10 无违反）：证明 exit 4 来自旁边那个不支持的文件，而不是「没有源码」。
import { DebugFakeServer } from './DebugFakeServer';

export class Ok {
  static mock(): boolean {
    return DebugFakeServer.mockGate();
  }
}
