import { PrivacyState, UpdateState as GuardUpdate } from '../router/GuardState';
import { UpdateCheckStatus } from '../router/LaunchQueue';
import { UpdateCheckOutcome, UpdateChecker, UpdateGate, UpdateState, UpdateStatusRaw } from './UpdateGate';
import { UpdateRouting } from './UpdateRouting';

/**
 * 强更检查的发起时机与 Router 状态源（APP-02c 鸿蒙修复轮 R1-01…R1-03；03 §4.1「检查时机」、§4.4「强更状态」）。
 * 纯逻辑（不碰界面、不打日志），entry 的 AppUpdate 包一层给界面用；单测按 entry 的调用顺序接 Router 复现时序。
 *
 * - 检查只在环境 SETTLED 且已同意当前隐私政策时发（同意前只允许请求协议文本与配置，BR-ID-11；基本模式不发，03 §4.4）。
 * - 需要一次「立即检查」的时刻：冷启动，以及每次离开基本模式（重新同意，R1-03）——基本模式里不发检查，也就谈不上
 *   「基本模式期间检查过」，所以重新同意一律立即补发，不看复查间隔。基本模式期间 Gate 按 enterBasicMode：
 *   已知 below_min 照旧，其余为 unknown。
 * - syncPrivacy 必须在隐私结论写给 Router 之后、consentHandled / 任何待办恢复之前调用（R1-01）：先把「检查中」发布出去，
 *   恢复因此 defer（等结果或满 5 秒），不会被同意那一刻的 unknown 判定删除。
 * - routerStatus：只要有检查在途，除已知 below_min 外一律报 checking（R1-02）——回前台复查时界面可以保留旧投影，
 *   但外部入口与待办恢复要 defer update_checking；App 内用户操作不等，按 inAppUpdate（检查中保留本进程已知结论，
 *   冷启动还没有结论时为 unknown）。
 * - 检查开始、结束都回调 changed(notify)：App 据此刷新界面并重新协调启动（设等待到期定时器 / 放行 / 恢复）。
 * - 复查失败（R2-01）：Gate 界面状态可保留旧结论，routerStatus 除已知 below_min 外报 unknown，直到下一次成功检查；
 *   inAppUpdate 仍按 Gate 结论（失败不拦用户在原生页面上自己的操作，03 §4.1）。
 * 单线程（UI 线程）使用。
 */
export class UpdateCheckCoordinator {
  readonly gate: UpdateGate;
  private readonly checker: UpdateChecker;
  private readonly clock: () => number;
  /** 环境闸门 SETTLED（App 接上）。 */
  environmentSettled: () => boolean = () => false;
  /** 隐私闸门当前结论（App 接上 AppRouting.privacyState）。 */
  privacy: () => PrivacyState = () => PrivacyState.NOT_DECIDED;
  /**
   * 检查开始、结束，或基本模式切换后：App 刷新界面字段；notify 为 true 时还要重新协调启动（AppRouting.stateChanged）。
   * 在 AppRouting.stateChanged / AppPrivacy.publish 当中调用的 syncPrivacy 传 false（调用方随后自己协调）。
   */
  changed: (notify: boolean) => void = (_notify: boolean) => {
  };
  /** 一次检查结束（App 据此在【重试】后再选店、打日志）。 */
  finished: (outcome: UpdateCheckOutcome, thenPickStore: boolean) => void =
    (_o: UpdateCheckOutcome, _p: boolean) => {
    };

  /** 下一次能查时要立即检查（冷启动、离开基本模式）。 */
  private checkDue: boolean = true;
  private running: boolean = false;
  private checkStartedAt: number = 0;
  /**
   * 最近一次检查失败、之后还没有成功检查（R2-01，编排者裁定 2026-10-07）：Gate 的界面状态可保留本进程旧结论（向量 G14），
   * 但交给 Router 的状态按 unknown——外部入口只读、待办恢复受未知限制——直到下一次成功检查；已知 below_min 照旧强更。
   */
  private lastCheckFailed: boolean = false;

  constructor(gate: UpdateGate, checker: UpdateChecker, clock: () => number) {
    this.gate = gate;
    this.checker = checker;
    this.clock = clock;
  }

  /** 现在能不能发版本检查：环境 SETTLED 且已同意当前隐私政策。 */
  canCheck(): boolean {
    return this.environmentSettled() && this.privacy() === PrivacyState.CONSENTED;
  }

  /** 有检查请求在途。 */
  get isRunning(): boolean {
    return this.running;
  }

  /**
   * 隐私结论（或环境闸门）可能变化后调用：
   * - 基本模式：Gate 进基本模式投影（保留已知 below_min），记下「离开时要立即检查」；
   * - 已同意且能查、又欠着一次立即检查（冷启动 / 刚离开基本模式）：立即发检查，Gate 进入检查中。
   * 返回是否发起了检查。
   */
  syncPrivacy(notify: boolean = false): boolean {
    const privacy: PrivacyState = this.privacy();
    if (privacy === PrivacyState.BASIC_MODE) {
      const before: string = this.gate.state(this.clock()).statusRaw;
      this.gate.enterBasicMode();
      this.checkDue = true;
      if (before !== this.gate.state(this.clock()).statusRaw) {
        this.changed(notify);
      }
      return false;
    }
    if (!this.checkDue || !this.canCheck()) {
      return false;
    }
    this.checkDue = false;
    this.gate.onColdStart(this.clock());
    this.runCheck(false, notify);
    return true;
  }

  /** 回前台：欠着立即检查就补上；否则已同意且距上次成功检查超过间隔（或本进程没成功过、上次失败）才查。 */
  onForeground(): boolean {
    if (this.checkDue) {
      return this.syncPrivacy(true);
    }
    if (this.canCheck() && this.gate.onForeground(this.clock())) {
      this.runCheck(false, true);
      return true;
    }
    return false;
  }

  /** 立即重新检查（强更页【重试】、调试面板）；不能发检查时返回 false（调用方按已知结果处理）。 */
  recheck(thenPickStore: boolean): boolean {
    if (!this.canCheck()) {
      return false;
    }
    this.gate.onColdStart(this.clock());
    return this.runCheck(thenPickStore, true);
  }

  /** Router 的放行条件源（LaunchReadiness.update）。 */
  routerStatus(): UpdateCheckStatus {
    const state: UpdateState = this.gate.state(this.clock());
    if (state.statusRaw !== UpdateStatusRaw.BELOW_MIN && this.gate.checking) {
      return UpdateCheckStatus.checking(this.checkStartedAt);
    }
    if (state.statusRaw !== UpdateStatusRaw.BELOW_MIN && this.lastCheckFailed) {
      return UpdateCheckStatus.finished(GuardUpdate.UNKNOWN);
    }
    return UpdateRouting.status(state, this.checkStartedAt);
  }

  /** App 内用户自己的操作用的强更结论（不等待）：检查中保留本进程已知结论；没有结论为 unknown。 */
  inAppUpdate(): GuardUpdate {
    const status: UpdateCheckStatus = UpdateRouting.status(this.gate.state(this.clock()), 0);
    return status.result ?? GuardUpdate.UNKNOWN;
  }

  private runCheck(thenPickStore: boolean, notify: boolean): boolean {
    if (this.running) {
      // 已有检查在途（Gate 已标记检查中）：等它的结果，不重复发。
      return false;
    }
    this.running = true;
    this.checkStartedAt = this.clock();
    // 检查开始也通知启动协调：外部入口与待办恢复从这一刻起最多等 5 秒（R1-02）。
    this.changed(notify);
    this.checker.check()
      .catch((): UpdateCheckOutcome => UpdateCheckOutcome.failure())
      .then((outcome: UpdateCheckOutcome) => {
        this.finish(outcome, thenPickStore);
      });
    return true;
  }

  private finish(outcome: UpdateCheckOutcome, thenPickStore: boolean): void {
    this.running = false;
    const now: number = this.clock();
    if (outcome.result !== null) {
      this.gate.apply(outcome.result, now);
      this.lastCheckFailed = false;
    } else {
      this.gate.applyFailure(now);
      this.lastCheckFailed = true;
    }
    if (this.privacy() === PrivacyState.BASIC_MODE) {
      // 检查在途时进了基本模式（撤回同意）：结果只留下已知 below_min，其余仍按 unknown，离开时再查。
      this.gate.enterBasicMode();
      this.checkDue = true;
    }
    this.finished(outcome, thenPickStore);
    this.changed(true);
  }
}
