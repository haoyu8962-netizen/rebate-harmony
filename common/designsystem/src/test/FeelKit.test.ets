// FU-HM-FEEL-KIT-harmony 测试作者 v2（新鲜独立 Claude，D10-823；v2 按 D10-1163 ①：减弱动态时淡入保留短时长）。
// 依据：NATIVE/FU-HM-FEEL-KIT/brief-harmony.md §2.1（时刻 → effectId）、§2.2（动效时长）、§3.1（用例 1–9 与 MotionPolicy）；README §3.2、§3.3；裁定 D10-1153（SELECTION 先 clock.timer）。
// 用例 10（组件库 / 页面 0 处调用）是宿主断言，在 tools/ci/feelkit/check_feel_kit.py C3。
// 被测接口（只从这两个纯逻辑文件取，文件里不得 import @kit / $r）：
//   HapticMoments.ets：enum HapticMoment { SELECTION, SUCCESS, WARNING, FAILURE, THRESHOLD }；HAPTIC_EFFECT: Map<HapticMoment, string>；
//                      interface HapticPort { supported(id: string): boolean; vibrate(id: string): void; }；class HapticPlan { constructor(port); emit(moment); }
//   MotionPolicy.ets： enum MotionKind { MICRO, ENTER }；enum PressKind { BOUNCE, HIGHLIGHT }；class MotionSpec { durationMs: number; zeroTranslate: boolean; fadeMs: number; }；
//                      class MotionPolicy { static resolve(reduced: boolean, kind: MotionKind): MotionSpec; static press(reduced: boolean, kind: PressKind): PressKind; }
// 期望值是抄自任务书的字面量，不读实现的表。
import { describe, it, expect } from '@ohos/hypium';
import { HAPTIC_EFFECT, HapticMoment, HapticPlan, HapticPort } from '../main/ets/logic/HapticMoments';
import { MotionKind, MotionPolicy, MotionSpec, PressKind } from '../main/ets/logic/MotionPolicy';

class FakePort implements HapticPort {
  asked: string[] = [];
  vibrated: string[] = [];
  isSupported: boolean = true;
  supportedThrows: boolean = false;
  vibrateThrows: boolean = false;

  supported(id: string): boolean {
    this.asked.push(id);
    if (this.supportedThrows) {
      throw new Error('supported failed');
    }
    return this.isSupported;
  }

  vibrate(id: string): void {
    this.vibrated.push(id);
    if (this.vibrateThrows) {
      throw new Error('vibrate failed');
    }
  }
}

class MomentCase {
  label: string;
  moment: HapticMoment;
  effect: string;

  constructor(label: string, moment: HapticMoment, effect: string) {
    this.label = label;
    this.moment = moment;
    this.effect = effect;
  }
}

const MOMENTS: MomentCase[] = [
  new MomentCase('SELECTION', HapticMoment.SELECTION, 'haptic.clock.timer'),
  new MomentCase('SUCCESS', HapticMoment.SUCCESS, 'haptic.notice.success'),
  new MomentCase('WARNING', HapticMoment.WARNING, 'haptic.notice.warning'),
  new MomentCase('FAILURE', HapticMoment.FAILURE, 'haptic.notice.fail'),
  new MomentCase('THRESHOLD', HapticMoment.THRESHOLD, 'haptic.effect.sharp')
];

function expectSingleEffect(index: number): void {
  const row: MomentCase = MOMENTS[index];
  const port: FakePort = new FakePort();
  new HapticPlan(port).emit(row.moment);
  expect(port.vibrated.join('|')).assertEqual(row.effect);
  // 问支持与否用的必须是同一个 id，否则不支持的效果也会振。
  expect(port.asked.join('|')).assertEqual(row.effect);
}

function emitDoesNotThrow(port: FakePort, moment: HapticMoment): boolean {
  try {
    new HapticPlan(port).emit(moment);
    return true;
  } catch (e) {
    return false;
  }
}

export default function feelKitTest() {
  describe('FeelKitHaptics', () => {
    // 书 §3.1 #1–#5
    it('emit_selection_vibrates_clock_timer_once', 0, () => {
      expectSingleEffect(0);
    });
    it('emit_success_vibrates_notice_success_once', 0, () => {
      expectSingleEffect(1);
    });
    it('emit_warning_vibrates_notice_warning_once', 0, () => {
      expectSingleEffect(2);
    });
    it('emit_failure_vibrates_notice_fail_once', 0, () => {
      expectSingleEffect(3);
    });
    it('emit_threshold_vibrates_effect_sharp_once', 0, () => {
      expectSingleEffect(4);
    });
    // 书 §3.1 #6
    it('unsupported_effect_is_silent_and_does_not_throw', 0, () => {
      for (const row of MOMENTS) {
        const port: FakePort = new FakePort();
        port.isSupported = false;
        expect(emitDoesNotThrow(port, row.moment)).assertTrue();
        expect(port.vibrated.length).assertEqual(0);
        expect(port.asked.join('|')).assertEqual(row.effect);
      }
    });
    // 书 §3.1 #7（购买、提现路径不能被触感打断）
    it('vibrate_throw_does_not_escape_emit', 0, () => {
      for (const row of MOMENTS) {
        const port: FakePort = new FakePort();
        port.vibrateThrows = true;
        expect(emitDoesNotThrow(port, row.moment)).assertTrue();
        expect(port.vibrated.length).assertEqual(1);
      }
    });
    // 书 §2.1「端口抛错 → 吞掉不外抛」，supported 同样算端口。
    it('supported_throw_does_not_escape_emit_and_stays_silent', 0, () => {
      const port: FakePort = new FakePort();
      port.supportedThrows = true;
      expect(emitDoesNotThrow(port, HapticMoment.FAILURE)).assertTrue();
      expect(port.vibrated.length).assertEqual(0);
    });
    // 书 §3.1 #8（去重由调用方决定）
    it('same_moment_twice_vibrates_twice', 0, () => {
      const port: FakePort = new FakePort();
      const plan: HapticPlan = new HapticPlan(port);
      plan.emit(HapticMoment.SUCCESS);
      plan.emit(HapticMoment.SUCCESS);
      expect(port.vibrated.join('|')).assertEqual('haptic.notice.success|haptic.notice.success');
    });
    // 书 §3.1 #9
    it('effect_table_covers_five_moments_with_unique_ids', 0, () => {
      expect(HAPTIC_EFFECT.size).assertEqual(5);
      const seen: Set<string> = new Set<string>();
      for (const row of MOMENTS) {
        expect(HAPTIC_EFFECT.get(row.moment)).assertEqual(row.effect);
        seen.add(row.effect);
      }
      expect(seen.size).assertEqual(5);
    });
    // 书 §3.1 末：时刻 → effectId 表进测试日志（D10-832 ⑥）；取自真实 emit，不读 HAPTIC_EFFECT。
    it('moment_table_is_logged_from_real_emits', 0, () => {
      const lines: string[] = [];
      for (const row of MOMENTS) {
        const port: FakePort = new FakePort();
        new HapticPlan(port).emit(row.moment);
        expect(port.vibrated.length).assertEqual(1);
        lines.push(row.label + ' -> ' + port.vibrated[0]);
      }
      console.info('FEELKIT_MOMENT_TABLE ' + lines.join('; '));
      expect(lines.length).assertEqual(5);
    });
  });

  describe('FeelKitMotionPolicy', () => {
    it('not_reduced_micro_uses_150ms_and_keeps_translate', 0, () => {
      const spec: MotionSpec = MotionPolicy.resolve(false, MotionKind.MICRO);
      expect(spec.durationMs).assertEqual(150);
      expect(spec.zeroTranslate).assertFalse();
    });
    it('not_reduced_enter_uses_250ms_and_keeps_translate', 0, () => {
      const spec: MotionSpec = MotionPolicy.resolve(false, MotionKind.ENTER);
      expect(spec.durationMs).assertEqual(250);
      expect(spec.zeroTranslate).assertFalse();
    });
    it('reduced_micro_is_zero_duration_without_translate', 0, () => {
      const spec: MotionSpec = MotionPolicy.resolve(true, MotionKind.MICRO);
      expect(spec.durationMs).assertEqual(0);
      expect(spec.zeroTranslate).assertTrue();
    });
    it('reduced_enter_is_zero_duration_without_translate', 0, () => {
      const spec: MotionSpec = MotionPolicy.resolve(true, MotionKind.ENTER);
      expect(spec.durationMs).assertEqual(0);
      expect(spec.zeroTranslate).assertTrue();
    });
    // v2（D10-1163 ①，README §3.3）：减弱动态只取消位移 / 缩放，透明度淡入保留短时长（100–200，微交互档），不走 0 时长。
    it('reduced_keeps_a_short_fade_for_micro_and_enter', 0, () => {
      const micro: number = MotionPolicy.resolve(true, MotionKind.MICRO).fadeMs;
      const enter: number = MotionPolicy.resolve(true, MotionKind.ENTER).fadeMs;
      expect(micro >= 100 && micro <= 200).assertTrue();
      expect(enter >= 100 && enter <= 200).assertTrue();
    });
    it('not_reduced_fade_follows_the_duration', 0, () => {
      expect(MotionPolicy.resolve(false, MotionKind.MICRO).fadeMs).assertEqual(150);
      expect(MotionPolicy.resolve(false, MotionKind.ENTER).fadeMs).assertEqual(250);
    });
    it('reduced_bounce_degrades_to_highlight', 0, () => {
      expect(MotionPolicy.press(true, PressKind.BOUNCE)).assertEqual(PressKind.HIGHLIGHT);
    });
    it('reduced_highlight_stays_highlight', 0, () => {
      expect(MotionPolicy.press(true, PressKind.HIGHLIGHT)).assertEqual(PressKind.HIGHLIGHT);
    });
    it('not_reduced_press_kind_is_unchanged', 0, () => {
      expect(MotionPolicy.press(false, PressKind.BOUNCE)).assertEqual(PressKind.BOUNCE);
      expect(MotionPolicy.press(false, PressKind.HIGHLIGHT)).assertEqual(PressKind.HIGHLIGHT);
    });
  });
}
