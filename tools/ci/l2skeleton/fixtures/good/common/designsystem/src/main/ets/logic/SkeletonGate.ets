// REFERENCE_ONLY（HM-L2-SKELETON 测试作者参照件，只供 check_l2_skeleton.py --self-test / run-logic.cjs 自测，不是产品代码）。
// 骨架防闪门控（README ⑧ / D10-1177）：加载超过 SHOW_DELAY_MS 才出现骨架，出现后至少留 MIN_VISIBLE_MS。纯逻辑，时钟注入。
// 减弱动态只影响微光（shimmerEnabled），不影响门控时序。

export interface SkeletonClock {
  now(): number;
}

export enum SkeletonPhase {
  HIDDEN,
  SHOWING,
  CONTENT
}

/** 减弱动态时不播微光、不位移（静态底色）。 */
export function shimmerEnabled(reduced: boolean): boolean {
  return !reduced;
}

export class SkeletonGate {
  static readonly SHOW_DELAY_MS: number = 300;
  static readonly MIN_VISIBLE_MS: number = 300;
  private readonly clock: SkeletonClock;
  private loading: boolean = false;
  private loadingSince: number = 0;
  /** 骨架真正出现（tick 第一次给出 SHOWING）的时刻；-1 = 没在显示。 */
  private shownAt: number = -1;

  constructor(clock: SkeletonClock) {
    this.clock = clock;
  }

  loadingChanged(loading: boolean): void {
    if (loading === this.loading) {
      return;
    }
    this.loading = loading;
    if (loading && this.shownAt < 0) {
      this.loadingSince = this.clock.now();
    }
  }

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

  /** 下一次该 tick 的剩余毫秒（到点未 tick 时为 0，不为负）；没有待变的阶段时为 -1。 */
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
