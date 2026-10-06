// F-ALL-07（APP-02c-ios R2-02 三端核对，APP-03a 补测）：同一次版本检查在途时再回前台（或点【重试】），
// 不得重置检查起点与 5 秒等待，也不重复发检查。
import { describe, it, expect } from '@ohos/hypium';
import {
  LaunchQueue, MemoryUpdateStore, PrivacyState, UpdateCheckCoordinator, UpdateCheckOutcome, UpdateChecker,
  UpdateCheckResult, UpdateCheckStatus, UpdateGate, UpdateState, UpdateStoreListing
} from '../../Index';

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
  now: number = 50000000;
}

function okResult(): UpdateCheckResult {
  return new UpdateCheckResult('1.0.0', null, '1.0.0', 'huawei', [new UpdateStoreListing('huawei', '1.0.0')], 1800);
}

function coordinator(clock: Clock, checker: HeldChecker): UpdateCheckCoordinator {
  const gate: UpdateGate = new UpdateGate(new MemoryUpdateStore(), (): number => clock.now, '1.0.0', 'harmony', 'agc', null);
  const coord: UpdateCheckCoordinator = new UpdateCheckCoordinator(gate, checker, (): number => clock.now);
  coord.environmentSettled = (): boolean => true;
  coord.privacy = (): PrivacyState => PrivacyState.CONSENTED;
  return coord;
}

export default function updateForegroundInFlightTest() {
  describe('UpdateForegroundInFlight', () => {
    it('cold_start_check_in_flight_foreground_keeps_start_and_5s_wait', 0, async () => {
      const clock: Clock = new Clock();
      const checker: HeldChecker = new HeldChecker();
      const coord: UpdateCheckCoordinator = coordinator(clock, checker);
      expect(coord.syncPrivacy(false)).assertTrue();
      const startedAt: number = clock.now;
      clock.now += 3000;
      coord.onForeground();
      coord.onForeground();
      expect(checker.calls).assertEqual(1);
      const status: UpdateCheckStatus = coord.routerStatus();
      expect(status.result === null).assertTrue();
      expect(status.startedAt).assertEqual(startedAt);
      // 5 秒从第一次发起算：再过 2 秒即按未知，不因回前台顺延。
      expect(LaunchQueue.effectiveUpdate(coord.routerStatus(), clock.now) === null).assertTrue();
      clock.now += 2000;
      expect(LaunchQueue.effectiveUpdate(coord.routerStatus(), clock.now)).assertEqual(UpdateState.UNKNOWN);
      await checker.respond(UpdateCheckOutcome.success(okResult()));
      expect(coord.routerStatus().result).assertEqual(UpdateState.OK);
    });

    it('foreground_recheck_in_flight_then_foreground_again_does_not_restart', 0, async () => {
      const clock: Clock = new Clock();
      const checker: HeldChecker = new HeldChecker();
      const coord: UpdateCheckCoordinator = coordinator(clock, checker);
      coord.syncPrivacy(false);
      await checker.respond(UpdateCheckOutcome.success(okResult()));
      clock.now += 1800 * 1000 + 1;
      coord.onForeground();
      expect(checker.calls).assertEqual(2);
      const startedAt: number = coord.routerStatus().startedAt;
      expect(startedAt).assertEqual(clock.now);
      clock.now += 4000;
      coord.onForeground();
      expect(coord.recheck(false)).assertFalse();
      expect(checker.calls).assertEqual(2);
      expect(coord.routerStatus().startedAt).assertEqual(startedAt);
      clock.now += 1000;
      expect(LaunchQueue.effectiveUpdate(coord.routerStatus(), clock.now)).assertEqual(UpdateState.UNKNOWN);
    });
  });
}
