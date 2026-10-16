// lint-fixtures-exit4 的正常源码（无违反）：证明 exit 4 来自 entry/src/main 里边界无法确认的那个文件，而不是「没有源码」。
import { DebugFakeServer } from './DebugFakeServer';

export class Ok {
  static mock(): boolean {
    return DebugFakeServer.mockGate();
  }
}
