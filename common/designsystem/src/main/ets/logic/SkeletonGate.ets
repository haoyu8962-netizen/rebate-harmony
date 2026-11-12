// HM-L2-SKELETON：骨架防闪门控（README ⑧ / D10-1177；sprint-plan-harmony.md :93）。
// 加载超过 SHOW_DELAY_MS 才出现骨架，骨架出现后至少留 MIN_VISIBLE_MS，避免快请求一闪而过。纯逻辑：时钟由调用方注入，
// 本文件不取时间、不起定时器（调用方按 nextDueInMs 自己定时再 tick）；不引 @kit / 资源 / 组件。
// 减弱动态只影响微光（shimmerEnabled），不影响门控时序（D10-1163 ①）。

/** 时钟端口：真机传系统时钟，单测传假时钟。单位毫秒。 */
export interface SkeletonClock {
  now(): number;
}

/** HIDDEN：在加载但还没到出现延时（什么都不画或保留旧内容）；SHOWING：显示骨架；CONTENT：显示内容。 */
export enum SkeletonPhase {
  HIDDEN,
  SHOWING,
  CONTENT
}

/** 微光策略：减弱动态时不播微光、不位移，只留静态 background.muted 底色。 */
export function shimmerEnabled(reduced: boolean): boolean {
  return !reduced;
}

export class SkeletonGate {
  static readonly SHOW_DELAY_MS: number = 300;
  static readonly MIN_VISIBLE_MS: number = 300;
  private readonly clock: SkeletonClock;
  private loading: boolean = false;
  /** 本轮加载（最新一次 false → true）开始的时刻。 */
  private loadingSince: number = 0;
  /** 最短显示的起算时刻：tick 第一次给出 SHOWING 时记下；骨架真正上屏（markOnScreen）时后移到上屏时刻；< 0 表示骨架没在显示。 */
  private shownAt: number = -1;

  constructor(clock: SkeletonClock) {
    this.clock = clock;
  }

  /** 加载态变化。重复传同一值不重新计时；骨架显示中再次开始加载时骨架继续留着，不重新计时。 */
  loadingChanged(loading: boolean): void {
    if (loading === this.loading) {
      return;
    }
    this.loading = loading;
    if (loading && this.shownAt < 0) {
      this.loadingSince = this.clock.now();
    }
  }

  /**
   * 骨架真正挂上屏时由包装件调用（HM-BATCH1-DEVFIX）：最短显示改从上屏时刻起算，判定 SHOWING 到上屏之间的延迟不计入。
   * 骨架没在显示（空闲、HIDDEN、已撤）时无作用；从没调用过时照旧从判定 SHOWING 的时刻起算。
   */
  markOnScreen(): void {
    if (this.shownAt >= 0) {
      this.shownAt = Math.max(this.shownAt, this.clock.now());
    }
  }

  /** 按当前时刻给出该显示的阶段（骨架第一次出现的时刻在这里记下）。 */
  tick(): SkeletonPhase {
    const now: number = this.clock.now();
    if (this.shownAt >= 0) {
      if (this.loading || now - this.shownAt < SkeletonGate.MIN_VISIBLE_MS) {
        return SkeletonPhase.SHOWING;
      }
      this.shownAt = -1;
      return SkeletonPhase.CONTENT;
    }
    if (!this.loading) {
      return SkeletonPhase.CONTENT;
    }
    if (now - this.loadingSince >= SkeletonGate.SHOW_DELAY_MS) {
      this.shownAt = now;
      return SkeletonPhase.SHOWING;
    }
    return SkeletonPhase.HIDDEN;
  }

  /** 距下一次阶段可能变化的毫秒数：到点未 tick 时为 0（不为负）；没有待变阶段（空闲、或骨架显示中仍在加载）时为 -1。 */
  nextDueInMs(): number {
    const now: number = this.clock.now();
    if (this.shownAt >= 0) {
      if (this.loading) {
        return -1;
      }
      return Math.max(0, this.shownAt + SkeletonGate.MIN_VISIBLE_MS - now);
    }
    if (!this.loading) {
      return -1;
    }
    return Math.max(0, this.loadingSince + SkeletonGate.SHOW_DELAY_MS - now);
  }
}
