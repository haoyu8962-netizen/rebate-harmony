// HM-L2-SKELETON-harmony 测试作者 v1（新鲜独立 Claude，先红）。依据：NATIVE/HM-L2-BATCH1/brief-SKELETON.md §2.4、§3「逻辑」1–8；
// README「编排裁定 D10-1177」⑧（SkeletonGate 纯逻辑 + SkeletonHost 包装件）；sprint-plan-harmony.md :78、:93（300ms 内不出现、出现后至少
// 300ms，时钟注入；减弱动态开启时不播微光、不位移）；D10-1163 ①（减弱动态只取消位移 / 缩放）。
// 被测接口（只从纯逻辑文件 logic/SkeletonGate.ets 取；该文件不得 import @kit / $r，Logic.ets 导出由宿主 check_l2_skeleton.py K3 钉）：
//   export interface SkeletonClock { now(): number; }
//   export enum SkeletonPhase { HIDDEN, SHOWING, CONTENT }
//   export function shimmerEnabled(reduced: boolean): boolean
//   export class SkeletonGate {
//     static readonly SHOW_DELAY_MS: number = 300; static readonly MIN_VISIBLE_MS: number = 300;
//     constructor(clock: SkeletonClock); loadingChanged(loading: boolean): void; tick(): SkeletonPhase; nextDueInMs(): number;
//   }
// 语义约定（测试作者定，交回 §2 写明）：
//   - 没进过加载：tick() 为 CONTENT，nextDueInMs() < 0（无待变阶段）。
//   - loadingChanged(true) 起算延时；到 SHOW_DELAY_MS（含）之前 HIDDEN，起 SHOWING。重复传 true 不重新起算。
//   - 「骨架出现时刻」= tick() 第一次给出 SHOWING 的时刻（本套件都在到点那一刻 tick，两种口径一致）。出现后加载结束：不满 MIN_VISIBLE_MS
//     仍 SHOWING，满了（含）CONTENT；骨架显示中加载又开始：继续 SHOWING，不闪内容。
//   - 延时内加载结束：直接 CONTENT，此后不再出现骨架；下一次 loadingChanged(true) 重新起算（只按最新一次加载走）。
//   - nextDueInMs()：有待变阶段时为剩余毫秒，到点而未 tick 时为 0（不为负）；骨架显示中且仍在加载、或 CONTENT 空闲时 < 0。
//   - 门控与减弱动态无关（类里不读 reduced / CouliMotion，宿主 K3 钉）；减弱动态只由 shimmerEnabled 关掉微光。
// 期望值是抄自任务书的字面量（300 / 300），不读实现。没有 hvigor 时由 tools/ci/l2skeleton/run-logic.cjs 用 node 执行同一份文件；
// logic/SkeletonGate.ets 不存在时 run-logic 用「契约缺失」桩替上，各条红在断言（CONTRACT_MISSING），不是导入错误。
import { describe, it, expect } from '@ohos/hypium';
import { shimmerEnabled, SkeletonClock, SkeletonGate, SkeletonPhase } from '../main/ets/logic/SkeletonGate';

class FakeClock implements SkeletonClock {
  t: number = 0;

  now(): number {
    return this.t;
  }
}

class Rig {
  clock: FakeClock = new FakeClock();
  gate: SkeletonGate;

  constructor(start: number) {
    this.clock.t = start;
    this.gate = new SkeletonGate(this.clock);
  }

  at(t: number): Rig {
    this.clock.t = t;
    return this;
  }

  load(loading: boolean): Rig {
    this.gate.loadingChanged(loading);
    return this;
  }

  tick(): SkeletonPhase {
    return this.gate.tick();
  }

  due(): number {
    return this.gate.nextDueInMs();
  }
}

/** 从 t0 起加载并在 t0 + 300 tick 出骨架；返回 rig（骨架已出现，仍在加载）。 */
function shownAt300(t0: number): Rig {
  const r: Rig = new Rig(t0).load(true);
  expect(r.at(t0 + 300).tick()).assertEqual(SkeletonPhase.SHOWING);
  return r;
}

export default function skeletonGateTest() {
  describe('SkeletonGate', () => {
    // 书 §2.4 签名与方案 :78「约 300ms」：两个门槛常量都是 300。
    it('skeleton_gate_show_delay_and_min_visible_are_300ms', 0, () => {
      expect(SkeletonGate.SHOW_DELAY_MS).assertEqual(300);
      expect(SkeletonGate.MIN_VISIBLE_MS).assertEqual(300);
    });

    it('skeleton_phase_has_three_distinct_values', 0, () => {
      const values: number[] = [SkeletonPhase.HIDDEN, SkeletonPhase.SHOWING, SkeletonPhase.CONTENT];
      expect(new Set<number>(values).size).assertEqual(3);
    });

    it('skeleton_gate_idle_is_content_and_nothing_due', 0, () => {
      const r: Rig = new Rig(5000);
      expect(r.tick()).assertEqual(SkeletonPhase.CONTENT);
      expect(r.due() < 0).assertTrue();
      expect(r.at(9000).tick()).assertEqual(SkeletonPhase.CONTENT);
    });

    // 书 §3 逻辑 1：loading=true 300ms 内 tick() == HIDDEN；300ms 起 SHOWING。
    it('skeleton_gate_hidden_within_300ms_then_showing_from_300ms', 0, () => {
      const r: Rig = new Rig(1000).load(true);
      expect(r.tick()).assertEqual(SkeletonPhase.HIDDEN);
      expect(r.at(1150).tick()).assertEqual(SkeletonPhase.HIDDEN);
      expect(r.at(1299).tick()).assertEqual(SkeletonPhase.HIDDEN);
      expect(r.at(1300).tick()).assertEqual(SkeletonPhase.SHOWING);
      expect(r.at(4000).tick()).assertEqual(SkeletonPhase.SHOWING);
    });

    // 书 §3 逻辑 2：骨架显示 299ms 时 loading=false → 仍 SHOWING，到 300ms 才 CONTENT。
    it('skeleton_gate_loading_ends_after_299ms_shown_stays_until_300ms', 0, () => {
      const r: Rig = shownAt300(0);
      r.at(599).load(false);
      expect(r.tick()).assertEqual(SkeletonPhase.SHOWING);
      expect(r.at(600).tick()).assertEqual(SkeletonPhase.CONTENT);
      expect(r.at(601).tick()).assertEqual(SkeletonPhase.CONTENT);
    });

    // 书 §3 逻辑 3：loading 在 300ms 内转 false → 从不进 SHOWING（CONTENT）。
    it('skeleton_gate_loading_ends_within_300ms_never_shows', 0, () => {
      const r: Rig = new Rig(0).load(true);
      for (let t: number = 0; t < 299; t += 50) {
        expect(r.at(t).tick()).assertEqual(SkeletonPhase.HIDDEN);
      }
      r.at(299).load(false);
      expect(r.tick()).assertEqual(SkeletonPhase.CONTENT);
      for (const t of [300, 450, 600, 5000]) {
        expect(r.at(t).tick()).assertEqual(SkeletonPhase.CONTENT);
      }
      expect(r.due() < 0).assertTrue();
    });

    // 书 §3 逻辑 4：显示满 300ms 后 loading=false → 立即 CONTENT。
    it('skeleton_gate_loading_ends_after_full_300ms_shown_goes_content_at_once', 0, () => {
      const exact: Rig = shownAt300(0);
      exact.at(600).load(false);
      expect(exact.tick()).assertEqual(SkeletonPhase.CONTENT);
      const later: Rig = shownAt300(0);
      expect(later.at(1200).tick()).assertEqual(SkeletonPhase.SHOWING);
      later.at(1500).load(false);
      expect(later.tick()).assertEqual(SkeletonPhase.CONTENT);
      expect(later.due() < 0).assertTrue();
    });

    // 书 §3 逻辑 5：反复切换只按最新一次加载起算（无抖动）。
    it('skeleton_gate_restart_counts_from_latest_loading_start', 0, () => {
      const r: Rig = new Rig(1000).load(true);
      r.at(1100).load(false);
      expect(r.tick()).assertEqual(SkeletonPhase.CONTENT);
      r.at(1150).load(true);
      expect(r.at(1300).tick()).assertEqual(SkeletonPhase.HIDDEN);
      expect(r.at(1449).tick()).assertEqual(SkeletonPhase.HIDDEN);
      expect(r.at(1450).tick()).assertEqual(SkeletonPhase.SHOWING);
    });

    it('skeleton_gate_repeated_true_does_not_restart_delay', 0, () => {
      const r: Rig = new Rig(0).load(true);
      r.at(200).load(true);
      expect(r.at(299).tick()).assertEqual(SkeletonPhase.HIDDEN);
      expect(r.at(300).tick()).assertEqual(SkeletonPhase.SHOWING);
    });

    it('skeleton_gate_reload_while_skeleton_shown_keeps_skeleton_without_content_flash', 0, () => {
      const r: Rig = shownAt300(0);
      r.at(350).load(false);
      expect(r.tick()).assertEqual(SkeletonPhase.SHOWING);
      r.at(400).load(true);
      expect(r.tick()).assertEqual(SkeletonPhase.SHOWING);
      expect(r.at(650).tick()).assertEqual(SkeletonPhase.SHOWING);
      expect(r.at(700).tick()).assertEqual(SkeletonPhase.SHOWING);
      r.load(false);
      expect(r.tick()).assertEqual(SkeletonPhase.CONTENT);
    });

    it('skeleton_gate_new_loading_after_content_waits_300ms_again', 0, () => {
      const r: Rig = shownAt300(500);
      r.at(1200).load(false);
      expect(r.tick()).assertEqual(SkeletonPhase.CONTENT);
      r.at(2000).load(true);
      expect(r.tick()).assertEqual(SkeletonPhase.HIDDEN);
      expect(r.at(2299).tick()).assertEqual(SkeletonPhase.HIDDEN);
      expect(r.at(2300).tick()).assertEqual(SkeletonPhase.SHOWING);
    });

    // 书 §3 逻辑 6：nextDueInMs 边界（到点为 0、不为负；无待变阶段 < 0）。延时段。
    it('skeleton_gate_next_due_counts_down_show_delay_and_never_negative', 0, () => {
      const r: Rig = new Rig(0).load(true);
      expect(r.due()).assertEqual(300);
      expect(r.at(120).due()).assertEqual(180);
      expect(r.at(299).due()).assertEqual(1);
      expect(r.at(300).due()).assertEqual(0);
      expect(r.at(350).due()).assertEqual(0);
      expect(r.tick()).assertEqual(SkeletonPhase.SHOWING);
      expect(r.due() < 0).assertTrue();
    });

    // 书 §3 逻辑 6：最短显示段。
    it('skeleton_gate_next_due_counts_down_min_visible_and_never_negative', 0, () => {
      const r: Rig = shownAt300(0);
      expect(r.due() < 0).assertTrue();
      r.at(450).load(false);
      expect(r.due()).assertEqual(150);
      expect(r.at(599).due()).assertEqual(1);
      expect(r.at(650).due()).assertEqual(0);
      expect(r.tick()).assertEqual(SkeletonPhase.CONTENT);
      expect(r.due() < 0).assertTrue();
    });

    // 书 §3 逻辑 8（方案 :93）：减弱动态时不播微光、不位移；否则播。
    it('skeleton_shimmer_disabled_when_reduced_motion_enabled_otherwise', 0, () => {
      expect(shimmerEnabled(true)).assertFalse();
      expect(shimmerEnabled(false)).assertTrue();
    });

    // 书 §3 逻辑 7：减弱动态只关微光，不关骨架、不改 300 / 300（门控不接 reduced 参数；类内不读 reduced 由宿主 K3 钉）。
    it('skeleton_gate_timing_is_same_when_shimmer_is_off_for_reduced_motion', 0, () => {
      expect(shimmerEnabled(true)).assertFalse();
      const r: Rig = new Rig(0).load(true);
      expect(r.at(299).tick()).assertEqual(SkeletonPhase.HIDDEN);
      expect(r.at(300).tick()).assertEqual(SkeletonPhase.SHOWING);
      r.at(450).load(false);
      expect(r.tick()).assertEqual(SkeletonPhase.SHOWING);
      expect(r.at(600).tick()).assertEqual(SkeletonPhase.CONTENT);
    });
  });
}
