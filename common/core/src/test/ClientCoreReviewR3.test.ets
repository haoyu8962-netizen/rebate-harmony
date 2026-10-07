// APP-03b 鸿蒙第 3 轮评审（harmony-review-r3.md R3-01）的回归测试：埋点上报的强更前提按交给 Router 的状态
// （UpdateCheckCoordinator.routerStatus → uploadReady），不按界面保留旧结论的 inAppUpdate。
// 真实 UpdateGate + UpdateCheckCoordinator + TrackerQueue，注入 sink；按 AppClientCore 的接线（canUpload = uploadReady）。
// 撤掉修复（uploadReady 改回 inAppUpdate() !== UNKNOWN）时，复查中、复查失败两个场景的断言会失败。
import { describe, it, expect } from '@ohos/hypium';
import {
  ClientEvents, MemoryUpdateStore, PrivacyState, PrivacyStateRaw, TrackerQueue, UpdateCheckCoordinator,
  UpdateCheckOutcome, UpdateChecker, UpdateCheckResult, UpdateGate, UpdateState, UpdateStoreListing
} from '../../Index';

const RECHECK_INTERVAL_SEC: number = 1800;

/** 手动应答的版本检查器。 */
class HeldChecker implements UpdateChecker {
  calls: number = 0;
  private resolvers: ((o: UpdateCheckOutcome) => void)[] = [];

  check(): Promise<UpdateCheckOutcome> {
    this.calls++;
    return new Promise<UpdateCheckOutcome>((resolve: (o: UpdateCheckOutcome) => void) => {
      this.resolvers.push(resolve);
    });
  }

  async respond(outcome: UpdateCheckOutcome): Promise<void> {
    const resolve: ((o: UpdateCheckOutcome) => void) | undefined = this.resolvers.shift();
    if (resolve !== undefined) {
      resolve(outcome);
    }
    for (let i: number = 0; i < 20; i++) {
      await Promise.resolve();
    }
  }
}

class Clock {
  now: number = 60000000;
}

/** 埋点队列文件（内存）。 */
class QueueFile {
  value: string | null = null;
}

/** 注入的 sink：记录每次提交的批次。 */
class RecordingSink {
  batches: string[][] = [];

  get submitted(): number {
    let count: number = 0;
    for (const batch of this.batches) {
      count += batch.length;
    }
    return count;
  }
}

function okResult(): UpdateCheckResult {
  return new UpdateCheckResult('1.0.0', null, '1.0.0', 'huawei', [new UpdateStoreListing('huawei', '1.0.0')],
    RECHECK_INTERVAL_SEC);
}

class Rig {
  readonly clock: Clock = new Clock();
  readonly checker: HeldChecker = new HeldChecker();
  readonly sink: RecordingSink = new RecordingSink();
  readonly file: QueueFile = new QueueFile();
  readonly coord: UpdateCheckCoordinator;
  readonly queue: TrackerQueue;

  constructor() {
    const gate: UpdateGate = new UpdateGate(new MemoryUpdateStore(), (): number => this.clock.now, '1.0.0', 'harmony',
      'agc', null);
    this.coord = new UpdateCheckCoordinator(gate, this.checker, (): number => this.clock.now);
    this.coord.environmentSettled = (): boolean => true;
    this.coord.privacy = (): PrivacyState => PrivacyState.CONSENTED;
    // 与 AppClientCore.uploadAllowed 相同的强更前提（环境、切换闸门在测试里恒为就绪）。
    this.queue = new TrackerQueue((): string | null => this.file.value,
      (value: string | null): void => {
        this.file.value = value;
      }, (events: string[]): boolean => {
        this.sink.batches.push(events);
        return true;
      }, PrivacyStateRaw.CONSENTED, (): string | null => null, 'dev-1', 'harmony', '1.0.0', 'session-1',
      (): number => this.clock.now, (): boolean => this.coord.uploadReady());
  }

  /** 冷启动检查成功：已有 ok 结论，入队的事件能提交。 */
  async settledOk(): Promise<void> {
    expect(this.coord.syncPrivacy(false)).assertTrue();
    await this.checker.respond(UpdateCheckOutcome.success(okResult()));
    expect(this.coord.routerStatus().result).assertEqual(UpdateState.OK);
    expect(this.queue.track(ClientEvents.appLaunch('Home'))).assertTrue();
    this.queue.flush();
    expect(this.sink.submitted).assertEqual(1);
    expect(this.queue.queueSize).assertEqual(0);
  }

  /** 超过复查间隔后回前台：发起复查（在途）。 */
  startForegroundRecheck(): void {
    this.clock.now += RECHECK_INTERVAL_SEC * 1000 + 1;
    expect(this.coord.onForeground()).assertTrue();
    expect(this.checker.calls).assertEqual(2);
  }

  trackTwo(): void {
    expect(this.queue.track(ClientEvents.appLaunch('Home'))).assertTrue();
    expect(this.queue.track(ClientEvents.appLaunch('Mine'))).assertTrue();
  }
}

export default function clientCoreReviewR3Test() {
  describe('ClientCoreReviewR3', () => {
    it('r3_01_recheck_in_flight_after_ok_enqueues_without_submit', 0, async () => {
      const rig: Rig = new Rig();
      await rig.settledOk();
      rig.startForegroundRecheck();
      // 界面结论仍是上次的 ok（复现评审场景的前提），但交给 Router 的是检查中。
      expect(rig.coord.inAppUpdate()).assertEqual(UpdateState.OK);
      expect(rig.coord.routerStatus().result === null).assertTrue();
      expect(rig.coord.uploadReady()).assertFalse();
      rig.trackTwo();
      rig.queue.flush();
      expect(rig.sink.submitted).assertEqual(1);
      expect(rig.queue.queueSize).assertEqual(2);
      expect(rig.file.value !== null).assertTrue();
      // 5 秒等待到期后 Router 按未知：仍不提交。
      rig.clock.now += 6000;
      rig.queue.flush();
      expect(rig.sink.submitted).assertEqual(1);
      expect(rig.queue.queueSize).assertEqual(2);
      // 复查成功：保留的队列整批提交。
      await rig.checker.respond(UpdateCheckOutcome.success(okResult()));
      expect(rig.coord.uploadReady()).assertTrue();
      rig.queue.flush();
      expect(rig.sink.submitted).assertEqual(3);
      expect(rig.queue.queueSize).assertEqual(0);
    });

    it('r3_01_recheck_failed_after_ok_is_unknown_and_keeps_queue', 0, async () => {
      const rig: Rig = new Rig();
      await rig.settledOk();
      rig.startForegroundRecheck();
      await rig.checker.respond(UpdateCheckOutcome.failure());
      // 复查失败：界面保留旧 ok，Router 为 unknown。
      expect(rig.coord.inAppUpdate()).assertEqual(UpdateState.OK);
      expect(rig.coord.routerStatus().result).assertEqual(UpdateState.UNKNOWN);
      expect(rig.coord.uploadReady()).assertFalse();
      rig.trackTwo();
      rig.queue.flush();
      expect(rig.sink.submitted).assertEqual(1);
      expect(rig.queue.queueSize).assertEqual(2);
      expect(rig.file.value !== null).assertTrue();
      // 下一次成功检查之前一直不提交；成功后提交保留的队列。
      expect(rig.coord.recheck(false)).assertTrue();
      rig.queue.flush();
      expect(rig.sink.submitted).assertEqual(1);
      await rig.checker.respond(UpdateCheckOutcome.success(okResult()));
      expect(rig.coord.uploadReady()).assertTrue();
      rig.queue.flush();
      expect(rig.sink.submitted).assertEqual(3);
      expect(rig.queue.queueSize).assertEqual(0);
    });

    it('r3_01_cold_start_checking_and_failure_enqueue_without_submit', 0, async () => {
      const rig: Rig = new Rig();
      expect(rig.coord.uploadReady()).assertFalse();
      expect(rig.coord.syncPrivacy(false)).assertTrue();
      rig.trackTwo();
      rig.queue.flush();
      expect(rig.sink.submitted).assertEqual(0);
      await rig.checker.respond(UpdateCheckOutcome.failure());
      expect(rig.coord.uploadReady()).assertFalse();
      rig.queue.flush();
      expect(rig.sink.submitted).assertEqual(0);
      expect(rig.queue.queueSize).assertEqual(2);
    });
  });
}
