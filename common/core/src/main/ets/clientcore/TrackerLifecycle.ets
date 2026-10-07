import { LocalDataCleaner } from '../config/LocalDataCleaner';
import { PrivacyWithdrawalCleaners } from '../privacy/PrivacyWithdrawal';

/**
 * 埋点队列的清理项（R1-06、lessons 11）：同时在撤回同意清理名单（PrivacyWithdrawalCleaners.TRACKER_QUEUE，cleanOnly）与
 * 切换环境（cleanAll）里。clear 删不掉时抛出：撤回清理不算完成（撤回痕迹保留，下次冷启动重试；痕迹在时队列按未同意，
 * 不加载、不上报旧队列），切换环境保持失败可重试。
 */
export class TrackerQueueCleaner implements LocalDataCleaner {
  readonly name: string = PrivacyWithdrawalCleaners.TRACKER_QUEUE;
  private readonly clearQueue: () => void;

  constructor(clearQueue: () => void) {
    this.clearQueue = clearQueue;
  }

  clean(): Promise<void> {
    try {
      this.clearQueue();
      return Promise.resolve();
    } catch (e) {
      return Promise.reject(e);
    }
  }
}

/** 周期定时器（生产 setInterval / clearInterval；单测注入手动触发的实现）。 */
export interface RepeatingTimer {
  start(intervalMillis: number, action: () => void): number;

  stop(handle: number): void;
}

export class SystemRepeatingTimer implements RepeatingTimer {
  start(intervalMillis: number, action: () => void): number {
    return setInterval(action, intervalMillis);
  }

  stop(handle: number): void {
    clearInterval(handle);
  }
}

/**
 * 埋点每 10 秒批量上报的调度（03 §4.7；lessons 8）：可注入定时器，便于单测。每次到点只调宿主给的 flush——是否真的上报由
 * TrackerQueue.flush 里同一套状态检查决定（隐私已同意且撤回清理完成、强更检查有结果、环境闸门打开，见宿主的 canUpload），
 * 撤回同意、切换环境与定时触发走的是同一个判断，调度器自己不另做判断。start 幂等，stop 后可再 start。
 */
export class TrackerFlushScheduler {
  private readonly timer: RepeatingTimer;
  private readonly flush: () => void;
  private readonly intervalMillis: number;
  private handle: number = -1;

  constructor(timer: RepeatingTimer, flush: () => void, intervalMillis: number) {
    this.timer = timer;
    this.flush = flush;
    this.intervalMillis = intervalMillis;
  }

  get running(): boolean {
    return this.handle >= 0;
  }

  start(): void {
    if (this.handle >= 0) {
      return;
    }
    this.handle = this.timer.start(this.intervalMillis, (): void => this.tick());
  }

  stop(): void {
    if (this.handle < 0) {
      return;
    }
    this.timer.stop(this.handle);
    this.handle = -1;
  }

  /** 到点：交给宿主的 flush（出错不影响下一次）。 */
  tick(): void {
    try {
      this.flush();
    } catch (e) {
      // 上报出错不影响调度。
    }
  }
}
