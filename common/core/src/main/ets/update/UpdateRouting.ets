import { UpdateState as GuardUpdate } from '../router/GuardState';
import { UpdateCheckStatus } from '../router/LaunchQueue';
import { UpdateState, UpdateStatusRaw } from './UpdateGate';

/**
 * UpdateGate 的结论 → Router 的强更状态源（替换 APP-02a 的占位）。
 * - checking：本进程正在等这一次检查（冷启动、或之前没有成功结果）→ LaunchQueue 的「检查中」，从 startedAt 起最长等 5 秒；
 *   外部来源与 pending 恢复 defer（update_checking），App 内用户操作不等（03 §4.4，APP-02a 已有）。
 * - unknown（检查失败、基本模式不发检查）→ 直接按未知，不等待；ok / below_recommended / below_min 原样交给守卫。
 */
export class UpdateRouting {
  static status(state: UpdateState, checkStartedAt: number): UpdateCheckStatus {
    switch (state.statusRaw) {
      case UpdateStatusRaw.CHECKING:
        return UpdateCheckStatus.checking(checkStartedAt);
      case UpdateStatusRaw.OK:
        return UpdateCheckStatus.finished(GuardUpdate.OK);
      case UpdateStatusRaw.BELOW_RECOMMENDED:
        return UpdateCheckStatus.finished(GuardUpdate.BELOW_RECOMMENDED);
      case UpdateStatusRaw.BELOW_MIN:
        return UpdateCheckStatus.finished(GuardUpdate.BELOW_MIN);
      default:
        return UpdateCheckStatus.finished(GuardUpdate.UNKNOWN);
    }
  }
}
