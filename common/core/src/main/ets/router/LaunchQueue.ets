import { PrivacyState, UpdateState } from './GuardState';
import { RouteRequest } from './RouteRequest';

/** 冷启动 / 外部带来的一次性启动意图（只放内存，不落盘；03 §4.4「冷启动时的深链与推送」）。 */
export class LaunchIntent {
  /** 深链：记 {route, params}。 */
  readonly request: RouteRequest | null;
  /** 推送：只记消息编号，执行时再回查。 */
  readonly messageId: string | null;

  private constructor(request: RouteRequest | null, messageId: string | null) {
    this.request = request;
    this.messageId = messageId;
  }

  static route(request: RouteRequest): LaunchIntent {
    return new LaunchIntent(request, null);
  }

  static push(messageId: string): LaunchIntent {
    return new LaunchIntent(null, messageId);
  }
}

/** 强更检查的进度：checking（从 startedAt 毫秒开始等）或 finished（有结果）。 */
export class UpdateCheckStatus {
  readonly result: UpdateState | null;
  readonly startedAt: number;

  private constructor(result: UpdateState | null, startedAt: number) {
    this.result = result;
    this.startedAt = startedAt;
  }

  static checking(startedAt: number): UpdateCheckStatus {
    return new UpdateCheckStatus(null, startedAt);
  }

  static finished(result: UpdateState): UpdateCheckStatus {
    return new UpdateCheckStatus(result, 0);
  }
}

/** 放行条件的状态源（02b、02c 接入真正的隐私闸门与强更检查，本任务可注入）。 */
export class LaunchReadiness {
  readonly environmentSettled: boolean;
  readonly privacy: PrivacyState;
  readonly update: UpdateCheckStatus;

  constructor(environmentSettled: boolean, privacy: PrivacyState, update: UpdateCheckStatus) {
    this.environmentSettled = environmentSettled;
    this.privacy = privacy;
    this.update = update;
  }
}

/** 排队放行的结果：意图 + 守卫该用的强更结果。 */
export class LaunchRelease {
  readonly intent: LaunchIntent;
  readonly update: UpdateState;

  constructor(intent: LaunchIntent, update: UpdateState) {
    this.intent = intent;
    this.update = update;
  }
}

/**
 * 启动意图排队器：等 EnvironmentGate settled、隐私闸门有结论、强更检查有结果（或等满 5 秒按 unknown）
 * 再放行给 Router（03 §4.4 冷启动顺序：隐私闸门 → 强更检查 → Tab 就绪 → 推送回查 → 执行）。
 * 启动意图是一次性的：只保留最新一条，新的覆盖旧的；放行或丢弃后即清空。
 * TODO(APP-02b): 「Tab 就绪」一步与热启动时停在首启弹窗 / ForceUpdate 的丢弃，由 02b、02c 接入（rule-gaps G11）。
 */
export class LaunchQueue {
  /** 启动意图等强更检查的上限（03 §4.4，客户端常量）。 */
  static readonly UPDATE_WAIT_MILLIS: number = 5000;
  private queued: LaunchIntent | null = null;
  /** 环境与隐私闸门都通过的时刻（5 秒等待从这里与强更检查开始两者中较晚的一个起算）；闸门关上时清空。 */
  private gatesPassedAt: number | null = null;

  get pending(): LaunchIntent | null {
    return this.queued;
  }

  enqueue(intent: LaunchIntent): void {
    this.queued = intent;
  }

  discard(): void {
    this.queued = null;
  }

  /**
   * 本时刻守卫该用的强更结果；仍要等待时为 null。
   * waitStartedAt：等待起点（强更检查开始，且不早于环境与隐私闸门通过的时刻）。
   */
  static effectiveUpdate(status: UpdateCheckStatus, now: number, waitStartedAt?: number): UpdateState | null {
    if (status.result !== null) {
      return status.result;
    }
    const start: number = Math.max(status.startedAt, waitStartedAt ?? status.startedAt);
    return now - start >= LaunchQueue.UPDATE_WAIT_MILLIS ? UpdateState.UNKNOWN : null;
  }

  /** 环境就绪且隐私闸门有结论（同意或基本模式）。 */
  static gatesOpen(readiness: LaunchReadiness): boolean {
    return readiness.environmentSettled && readiness.privacy !== PrivacyState.NOT_DECIDED;
  }

  /**
   * 记下环境与隐私闸门通过的时刻（5 秒等待的起点之一）；闸门关上时清空。
   * 与外壳（Navigation / Tab）是否就绪无关：App 在每次状态变化时都调，计时不因外壳未就绪推迟。
   */
  observe(readiness: LaunchReadiness, now: number): void {
    if (!LaunchQueue.gatesOpen(readiness)) {
      this.gatesPassedAt = null;
      return;
    }
    if (this.gatesPassedAt === null) {
      this.gatesPassedAt = now;
    }
  }

  /**
   * 闸门通过后守卫该用的强更结果：有结果用结果；检查中等满 5 秒（从闸门通过与检查开始两者中较晚的一刻起算）
   * 按 unknown；基本模式不发版本检查，没有结果时直接按 unknown、不等待（03 §4.4，BR-ID-11）。
   * 闸门未通过或仍在等待时为 null。
   */
  updateFor(readiness: LaunchReadiness, now: number): UpdateState | null {
    this.observe(readiness, now);
    if (this.gatesPassedAt === null) {
      return null;
    }
    if (readiness.update.result === null && readiness.privacy === PrivacyState.BASIC_MODE) {
      return UpdateState.UNKNOWN;
    }
    return LaunchQueue.effectiveUpdate(readiness.update, now, this.gatesPassedAt);
  }

  /** 闸门已通过、强更仍在检查且未满 5 秒：外部请求、pending_action 恢复与推送回查都要等。 */
  awaitingUpdate(readiness: LaunchReadiness, now: number): boolean {
    this.observe(readiness, now);
    return this.gatesPassedAt !== null && this.updateFor(readiness, now) === null;
  }

  /**
   * 正在等强更检查时，等待到期（按 unknown 处理）的时刻；不在等待或已到期时为 null（不空转）。
   * 与是否有排队意图无关：pending_action 恢复与热启动推送也靠它到期。
   */
  waitDeadline(readiness: LaunchReadiness, now: number): number | null {
    if (!this.awaitingUpdate(readiness, now) || this.gatesPassedAt === null) {
      return null;
    }
    return Math.max(readiness.update.startedAt, this.gatesPassedAt) + LaunchQueue.UPDATE_WAIT_MILLIS;
  }

  /**
   * 状态变化时调用（环境就绪、隐私结论、强更结果、或 nextDeadline 给出的那一刻）；不轮询。
   * 条件都满足时取出排队的意图（以及守卫该用的强更结果）；否则返回 null、继续排队。
   */
  release(readiness: LaunchReadiness, now: number): LaunchRelease | null {
    const update: UpdateState | null = this.updateFor(readiness, now);
    const intent: LaunchIntent | null = this.queued;
    if (intent === null || update === null) {
      return null;
    }
    this.queued = null;
    return new LaunchRelease(intent, update);
  }

  /**
   * 还在等强更检查时，下一次需要再调 release 的时刻（等满 5 秒按 unknown）；不需要定时器时为 null。
   * 闸门未通过、没有排队意图或强更已有结果时都返回 null：排队器只由状态变化驱动，不空转。
   */
  nextDeadline(readiness: LaunchReadiness): number | null {
    if (this.queued === null || this.gatesPassedAt === null || readiness.update.result !== null
      || !LaunchQueue.gatesOpen(readiness) || readiness.privacy === PrivacyState.BASIC_MODE) {
      return null;
    }
    return Math.max(readiness.update.startedAt, this.gatesPassedAt) + LaunchQueue.UPDATE_WAIT_MILLIS;
  }
}
